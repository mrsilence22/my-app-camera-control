import Foundation

/// A tiny file-based logger for capturing the full camera-control flow during testing —
/// especially whether/when a callback actually came back from the camera after a request.
/// Writes to a plain text file in the app's Documents directory so it can be exported
/// (via ShareLink) after a test session and analyzed afterwards.
enum AppLogger {
    private static let queue = DispatchQueue(label: "com.myapp.applogger")
    
    static var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("camera_session_log.txt")
    }
    
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    
    /// Appends one timestamped line to the log file. Safe to call from any thread/queue.
    static func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        
        #if DEBUG
        print(line, terminator: "")
        #endif
        
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }
    
    /// Deletes the log file — call at the start of a fresh test session if you want a clean file.
    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: logFileURL)
        }
    }
    
    /// Reads the whole log file back as a string, for previewing before export.
    static func readAll() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }
}
