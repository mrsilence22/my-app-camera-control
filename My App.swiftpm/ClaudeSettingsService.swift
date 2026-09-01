
import Foundation

enum ClaudeServiceError: Error, CustomStringConvertible {
    case invalidResponse(String)
    case apiError(String)
    
    var description: String {
        switch self {
        case .invalidResponse(let raw): return "Invalid response: \(raw.prefix(200))"
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}

class ClaudeSettingsService {
    static let apiKey = Secrets.claudeAPIKey
    
    static func getSettings(sceneDescription: String) async throws -> CameraSettings {
        let systemPrompt = """
        You are a camera settings assistant for a Sony Alpha camera. Given a photographer's \
        description of the scene and intent, recommend the best exposure mode AND settings.
        
        Modes and what's settable in each:
        - manual: iso, aperture, shutter_speed, white_balance (NOT exposure_compensation)
        - aperture_priority: iso, aperture, white_balance, exposure_compensation (NOT shutter_speed)
        - shutter_priority: iso, shutter_speed, white_balance, exposure_compensation (NOT aperture)
        - program: iso, white_balance, exposure_compensation (NOT aperture, NOT shutter_speed)
        
        Rules:
        - Freeze fast motion (sports, wildlife) → shutter_priority
        - Control depth of field (portrait, bokeh, landscape) → aperture_priority
        - Full manual control needed → manual
        - Only include keys valid for the chosen mode. Omit others (use null).
        - Even if the scene description is very brief, vague, or a single word (e.g. "forest"), \
        you MUST still pick reasonable default settings for a typical version of that scene. \
        NEVER ask a clarifying question. NEVER add any text outside the JSON object.
        - tips: 2-3 SPECIFIC, actionable tips for this exact scene — not generic advice. \
        Think like a real photographer: framing angle, timing, gear positioning, or a common mistake \
        to avoid for THIS scene. Avoid vague tips like "use good lighting" or "compose well".
        
        Respond ONLY with valid JSON, no other text, no markdown code fences:
        {
          "recommended_mode": "<manual|aperture_priority|shutter_priority|program>",
          "mode_reason": "<one sentence>",
          "iso": <integer or null>,
          "aperture": <float or null>,
          "shutter_speed": "<string like 1/250, or null>",
          "white_balance": "<one of: auto, daylight, cloudy, shade, incandescent, or null>",
          "exposure_compensation": <float or null>,
          "reasoning": "<one sentence, max 20 words>",
          "tips": ["<tip 1>", "<tip 2>"]
        }
        """
        
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 500,
            "system": systemPrompt,
            "messages": [["role": "user", "content": sceneDescription]]
        ]
        
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let fullRawResponse = String(data: data, encoding: .utf8) ?? "<non-utf8 data>"
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeServiceError.invalidResponse(fullRawResponse)
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw ClaudeServiceError.apiError(message)
        }
        
        // Find the "text" type block specifically — content may also include a "thinking" block first.
        guard let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let rawText = textBlock["text"] as? String else {
            throw ClaudeServiceError.invalidResponse(fullRawResponse)
        }
        
        var cleanedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedText.hasPrefix("```") {
            cleanedText = cleanedText.replacingOccurrences(of: "```json", with: "")
            cleanedText = cleanedText.replacingOccurrences(of: "```", with: "")
            cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        guard let jsonData = cleanedText.data(using: .utf8) else {
            throw ClaudeServiceError.invalidResponse(rawText)
        }
        
        do {
            return try JSONDecoder().decode(CameraSettings.self, from: jsonData)
        } catch {
            throw ClaudeServiceError.invalidResponse("Decode failed: \(error). Raw text: \(rawText)")
        }
    }
}
