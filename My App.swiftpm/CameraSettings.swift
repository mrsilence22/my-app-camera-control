
import Foundation

struct CameraSettings: Codable {
    let recommendedMode: String
    let modeReason: String
    let iso: Int?
    let aperture: Double?
    let shutterSpeed: String?
    let whiteBalance: String?
    let exposureCompensation: Double?
    let reasoning: String
    let tips: [String]
    
    enum CodingKeys: String, CodingKey {
        case recommendedMode = "recommended_mode"
        case modeReason = "mode_reason"
        case iso, aperture
        case shutterSpeed = "shutter_speed"
        case whiteBalance = "white_balance"
        case exposureCompensation = "exposure_compensation"
        case reasoning, tips
    }
}
