
import Foundation

enum ShotSenseServiceError: Error, CustomStringConvertible {
    case invalidResponse(String)
    case apiError(String)
    
    var description: String {
        switch self {
        case .invalidResponse(let raw): return "Invalid response: \(raw.prefix(200))"
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}

class ShotSenseService {
    static let apiKey = Secrets.claudeAPIKey
    
    static func getSettings(sceneDescription: String, cameraName: String?, capabilities: CameraCapabilities?) async throws -> CameraSettings {
        let basePrompt = """
        You are a camera settings assistant for a Sony Alpha camera. Given a photographer's \
        description of the scene and intent, recommend the best exposure mode AND settings.

        Modes and what's settable in each:
        - manual: iso, aperture, shutter_speed, white_balance
        - aperture_priority: iso, aperture, white_balance (NOT shutter_speed)
        - shutter_priority: iso, shutter_speed, white_balance (NOT aperture)
        - program: iso, white_balance (NOT aperture, NOT shutter_speed)

        Rules:
        - Freeze fast motion (sports, wildlife) → shutter_priority
        - Control depth of field (portrait, bokeh, landscape) → aperture_priority
        - Full manual control needed → manual
        - Only include keys valid for the chosen mode. Omit others (use null).
        - When the scene explicitly requests shallow depth of field, maximum background blur, or bokeh, \
        and aperture is settable in the chosen mode, choose the WIDEST available aperture value from the \
        supported list (the smallest f-number) — do not default to a moderate value.

        focus_mode and drive_mode are independent of exposure mode — always include both:
        - focus_mode options: "af" (Automatic AF — subject may start still or move), \
        "af_s" (Single-shot AF — static subjects: landscape, posed portrait, product), \
        "af_c" (Continuous AF — moving subjects: sports, wildlife, kids/pets in motion), \
        "dmf" (Direct Manual Focus — macro/close-up needing fine manual tweaks after autofocus), \
        "mf" (Manual Focus — low light/low contrast where autofocus struggles, or fully deliberate framing)
        - drive_mode options: "photo" (single frame — default for most scenes), \
        "continuous" (burst — fast action where timing/peak moment matters), \
        "bracket_single" (one bracketed set — high-contrast/HDR scenes, e.g. sunset with dark foreground), \
        "bracket_continuous" (repeated bracketed sets — changing high-contrast light, e.g. fireworks, fast-changing sky)

        - Even if the scene description is very brief, vague, or a single word (e.g. "forest"), \
        you MUST still pick reasonable default settings for a typical version of that scene. \
        NEVER ask a clarifying question. NEVER add any text outside the JSON object.
        - tips: 2-3 SPECIFIC, actionable tips for this exact scene — not generic advice. \
        Think like a real photographer: framing angle, timing, gear positioning, or a common mistake \
        to avoid for THIS scene. Avoid vague tips like "use good lighting" or "compose well".
        """

        var cameraConstraints = ""
        if let name = cameraName {
            cameraConstraints += "\nCamera: \(name)\n"
        }
        if let caps = capabilities {
            if !caps.isoValues.isEmpty {
                cameraConstraints += "Supported ISO values (choose ONLY from this list): \(caps.isoValues.map(String.init).joined(separator: ", "))\n"
            }
            if !caps.apertureValues.isEmpty {
                let apStrings = caps.apertureValues.map { String(format: "f/%.1f", $0) }
                cameraConstraints += "Supported aperture values (choose ONLY from this list): \(apStrings.joined(separator: ", "))\n"
            }
            if !caps.shutterSpeedValues.isEmpty {
                cameraConstraints += "Supported shutter speed values (choose ONLY from this list): \(caps.shutterSpeedValues.joined(separator: ", "))\n"
            }
            if !cameraConstraints.isEmpty {
                cameraConstraints += "If your ideal value isn't in a supported list, pick the closest available value instead.\n"
            }
        }
        AppLogger.log("=== CAMERA CONSTRAINTS SENT TO LLM ===\n\(cameraConstraints)\n=== END CONSTRAINTS ===")

        let jsonSchema = """

        Respond ONLY with valid JSON, no other text, no markdown code fences:
        {
          "recommended_mode": "<manual|aperture_priority|shutter_priority|program>",
          "mode_reason": "<one sentence>",
          "iso": <integer or null>,
          "aperture": <float or null>,
          "shutter_speed": "<string like 1/250, or null>",
          "white_balance": "<one of: auto, daylight, cloudy, shade, incandescent, or null>",
          "focus_mode": "<one of: af, af_s, af_c, dmf, mf>",
          "drive_mode": "<one of: photo, continuous, bracket_single, bracket_continuous>",
          "reasoning": "<one sentence, max 20 words>",
          "tips": ["<tip 1>", "<tip 2>"]
        }
        """

        let systemPrompt = basePrompt + "\n" + cameraConstraints + jsonSchema
        AppLogger.log("=== FULL SYSTEM PROMPT (first 2000 chars) ===\n\(String(systemPrompt.prefix(2000)))\n=== END PROMPT ===")

        let requestBody: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 500,
            "system": systemPrompt,
            "messages": [["role": "user", "content": sceneDescription]]
        ]

        let jsonBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Forced over cellular: the phone stays connected to the camera's Wi-Fi (which
        // has no internet) while this request needs to actually reach the internet.
        let data = try await CellularNetworkClient.post(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json"
            ],
            jsonBody: jsonBody
        )
        let fullRawResponse = String(data: data, encoding: .utf8) ?? "<non-utf8 data>"
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShotSenseServiceError.invalidResponse(fullRawResponse)
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw ShotSenseServiceError.apiError(message)
        }
        
        // Find the "text" type block specifically — content may also include a "thinking" block first.
        guard let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let rawText = textBlock["text"] as? String else {
            throw ShotSenseServiceError.invalidResponse(fullRawResponse)
        }
        
        var cleanedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedText.hasPrefix("```") {
            cleanedText = cleanedText.replacingOccurrences(of: "```json", with: "")
            cleanedText = cleanedText.replacingOccurrences(of: "```", with: "")
            cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw ShotSenseServiceError.invalidResponse(rawText)
        }
        
        do {
            return try JSONDecoder().decode(CameraSettings.self, from: jsonData)
        } catch {
            throw ShotSenseServiceError.invalidResponse("Decode failed: \(error). Raw text: \(rawText)")
        }
    }
}
