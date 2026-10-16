import Foundation
import Network

enum CellularNetworkError: Error, CustomStringConvertible {
    case timeout
    case connectionFailed(String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .timeout, .connectionFailed:
            return "Cellular data chahiye, ya server ne time par jawab nahi diya"
        case .invalidResponse(let raw):
            return "Invalid response from server: \(raw.prefix(200))"
        }
    }
}

/// Forces a single HTTPS POST over the cellular interface, bypassing whatever Wi-Fi
/// network is currently active (e.g. a camera's internet-less hotspot).
/// URLSessionConfiguration has no interface-pinning knob, so this builds the TLS/TCP
/// connection and the HTTP/1.1 request by hand via the Network framework.
enum CellularNetworkClient {
    private static let queue = DispatchQueue(label: "com.myapp.cellularnetworkclient")

    /// Guards against resuming a checked continuation more than once, since the
    /// timeout, a connection failure, and a receive completion can all race to
    /// finish the same request. All mutations happen on `queue`, which serializes
    /// every NWConnection callback plus the timeout's own asyncAfter block.
    private final class OnceGuard {
        private var done = false
        func finish() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    static func post(url: URL, headers: [String: String], jsonBody: Data, timeout: TimeInterval = 15) async throws -> Data {
        guard let host = url.host else {
            throw CellularNetworkError.connectionFailed("URL has no host: \(url.absoluteString)")
        }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) ?? .https
        let path = url.path.isEmpty ? "/" : url.path
        let requestData = buildRequest(host: host, path: path, headers: headers, body: jsonBody)

        return try await withCheckedThrowingContinuation { continuation in
            let tlsOptions = NWProtocolTLS.Options()
            let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            params.requiredInterfaceType = .cellular
            params.prohibitExpensivePaths = false

            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
            let once = OnceGuard()

            let timeoutWorkItem = DispatchWorkItem {
                guard once.finish() else { return }
                AppLogger.log("CellularNetworkClient: TIMEOUT after \(Int(timeout))s — cancelling connection")
                connection.cancel()
                continuation.resume(throwing: CellularNetworkError.timeout)
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { newState in
                AppLogger.log("CellularNetworkClient: state -> \(newState)")

                switch newState {
                case .ready:
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error {
                            guard once.finish() else { return }
                            timeoutWorkItem.cancel()
                            AppLogger.log("CellularNetworkClient: send FAILED — \(error)")
                            connection.cancel()
                            continuation.resume(throwing: CellularNetworkError.connectionFailed("send failed: \(error)"))
                            return
                        }
                        AppLogger.log("CellularNetworkClient: request sent (\(requestData.count) bytes), awaiting response")
                        receiveResponse(on: connection, buffer: Data()) { result in
                            guard once.finish() else { return }
                            timeoutWorkItem.cancel()
                            connection.cancel()
                            switch result {
                            case .success(let body):
                                AppLogger.log("CellularNetworkClient: SUCCESS — \(body.count) response bytes")
                                continuation.resume(returning: body)
                            case .failure(let error):
                                AppLogger.log("CellularNetworkClient: response FAILED — \(error)")
                                continuation.resume(throwing: error)
                            }
                        }
                    })

                case .failed(let error):
                    guard once.finish() else { return }
                    timeoutWorkItem.cancel()
                    AppLogger.log("CellularNetworkClient: connection FAILED — \(error)")
                    connection.cancel()
                    continuation.resume(throwing: CellularNetworkError.connectionFailed("\(error)"))

                case .waiting(let error):
                    // No cellular path available yet (cellular off / no signal / airplane
                    // mode). Don't fail here — NWConnection will keep retrying on its own
                    // as paths change, so just let the request timeout be the backstop.
                    AppLogger.log("CellularNetworkClient: waiting for a cellular path — \(error)")

                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    // MARK: - Request building

    private static func buildRequest(host: String, path: String, headers: [String: String], body: Data) -> Data {
        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "Connection: close\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "\r\n"

        var requestData = Data(head.utf8)
        requestData.append(body)
        return requestData
    }

    // MARK: - Response receiving / parsing

    private enum BodyMode {
        case contentLength(Int)
        case chunked
        case untilClose
    }

    private static func receiveResponse(
        on connection: NWConnection,
        buffer: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let error {
                completion(.failure(CellularNetworkError.connectionFailed("receive error: \(error)")))
                return
            }

            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    completion(.failure(CellularNetworkError.invalidResponse(String(data: buffer, encoding: .utf8) ?? "<binary, no header terminator>")))
                } else {
                    receiveResponse(on: connection, buffer: buffer, completion: completion)
                }
                return
            }

            let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) ?? ""
            let bodySoFar = Data(buffer[headerRange.upperBound...])
            let headerFields = parseHeaderFields(headerText)

            let bodyMode: BodyMode
            if let lengthString = headerFields["content-length"], let length = Int(lengthString) {
                bodyMode = .contentLength(length)
            } else if let transferEncoding = headerFields["transfer-encoding"], transferEncoding.lowercased().contains("chunked") {
                bodyMode = .chunked
            } else {
                bodyMode = .untilClose
            }

            switch bodyMode {
            case .contentLength(let length):
                if bodySoFar.count >= length {
                    completion(.success(bodySoFar.prefix(length)))
                } else if isComplete {
                    completion(.failure(CellularNetworkError.invalidResponse("connection closed after \(bodySoFar.count) of \(length) expected bytes")))
                } else {
                    receiveResponse(on: connection, buffer: buffer, completion: completion)
                }

            case .chunked:
                if let decoded = decodeChunked(bodySoFar) {
                    completion(.success(decoded))
                } else if isComplete {
                    completion(.failure(CellularNetworkError.invalidResponse("connection closed mid-chunk")))
                } else {
                    receiveResponse(on: connection, buffer: buffer, completion: completion)
                }

            case .untilClose:
                if isComplete {
                    completion(.success(bodySoFar))
                } else {
                    receiveResponse(on: connection, buffer: buffer, completion: completion)
                }
            }
        }
    }

    private static func parseHeaderFields(_ headerText: String) -> [String: String] {
        var fields: [String: String] = [:]
        // First line is the status line ("HTTP/1.1 200 OK"), skip it.
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    /// Decodes a (possibly still-incomplete) chunked-transfer body. Returns nil if more
    /// data is needed before a full decode is possible.
    private static func decodeChunked(_ data: Data) -> Data? {
        var result = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)

        while true {
            guard let sizeLineEnd = data.range(of: crlf, in: index..<data.endIndex) else {
                return nil
            }
            let sizeLine = String(data: data[index..<sizeLineEnd.lowerBound], encoding: .ascii) ?? ""
            let sizeHex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let chunkSize = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }

            let chunkStart = sizeLineEnd.upperBound
            if chunkSize == 0 {
                return result
            }

            guard let chunkEnd = data.index(chunkStart, offsetBy: chunkSize, limitedBy: data.endIndex),
                  data.distance(from: chunkEnd, to: data.endIndex) >= 2 else {
                return nil
            }
            result.append(data[chunkStart..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
