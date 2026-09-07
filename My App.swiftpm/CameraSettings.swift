
import Foundation

struct CameraSettings: Codable {
    let recommendedMode: String
    let modeReason: String
    let iso: Int?
    let aperture: Double?
    let shutterSpeed: String?
    let whiteBalance: String?
    let focusMode: String?
    let driveMode: String?
    let reasoning: String
    let tips: [String]
    
    enum CodingKeys: String, CodingKey {
        case recommendedMode = "recommended_mode"
        case modeReason = "mode_reason"
        case iso, aperture
        case shutterSpeed = "shutter_speed"
        case whiteBalance = "white_balance"
        case focusMode = "focus_mode"
        case driveMode = "drive_mode"
        case reasoning, tips
    }
}
