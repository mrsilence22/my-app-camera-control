
import Foundation
import UIKit
import Rocc

class CameraController: NSObject, ObservableObject, CameraDiscovererDelegate {
    @Published var statusMessage = "Searching for camera on WiFi..."
    @Published var connectedCamera: Camera?
    @Published var settingResults: [SettingResult] = []
    @Published var isApplying = false
    @Published var showAppliedConfirmation = false
    
    private var discoverer: CameraDiscoverer!
    
    struct SettingResult: Identifiable {
        let id = UUID()
        let name: String
        let applied: Bool
        let reason: String?
    }
    
    override init() {
        super.init()
        AppLogger.log("CameraController init — starting discovery")
        discoverer = CameraDiscoverer()
        discoverer.delegate = self
        discoverer.start()
    }
    
    func checkForCamera() {
        AppLogger.log("checkForCamera() called — restarting discovery")
        statusMessage = "Checking for camera..."
        connectedCamera = nil
        discoverer.stop(with: { [weak self] in
            self?.discoverer.start()
        })
    }

    
    func cameraDiscoverer(_ discoverer: CameraDiscoverer, didError error: Error) {
        AppLogger.log("Discovery ERROR: \(error.localizedDescription)")
        DispatchQueue.main.async { self.statusMessage = "Discovery error: \(error.localizedDescription)" }
    }
    
    func cameraDiscoverer(_ discoverer: CameraDiscoverer, discovered device: Camera, isCached: Bool) {
        AppLogger.log("Discovered camera (isCached: \(isCached)) — connecting...")
        DispatchQueue.main.async { self.statusMessage = "Found camera, connecting..." }
        device.connect { [weak self] (error, isInTransferMode) in
            AppLogger.log("connect() callback — error: \(error?.localizedDescription ?? "nil"), isInTransferMode: \(isInTransferMode)")
            DispatchQueue.main.async {
                if let error = error {
                    self?.statusMessage = "Connect failed: \(error.localizedDescription)"
                } else {
                    self?.statusMessage = "Connected! Ready."
                    self?.connectedCamera = device
                }
            }
        }
    }
    
    func takeShot() {
        guard let camera = connectedCamera else { return }
        AppLogger.log("takeShot() — sending StillCapture.take")
        camera.performFunction(StillCapture.take, payload: nil) { [weak self] (error, url) in
            AppLogger.log("takeShot() callback — error: \(error?.localizedDescription ?? "nil"), url: \(url?.absoluteString ?? "nil")")
            DispatchQueue.main.async {
                self?.statusMessage = error == nil ? "Picture taken!" : "Shutter error: \(error!.localizedDescription)"
            }
        }
    }
    
    // MARK: - Mode mapping
    
    private func modeValue(for recommendedMode: String) -> Exposure.Mode.Value? {
        switch recommendedMode {
        case "manual": return .manual
        case "aperture_priority": return .aperturePriority
        case "shutter_priority": return .shutterPriority
        case "program": return .programmedAuto
        default: return nil
        }
    }
    
    // MARK: - Auto Apply (entry point from ContentView)
    
    func autoApply(_ settings: CameraSettings) {
        guard let camera = connectedCamera else { return }
        guard let modeVal = modeValue(for: settings.recommendedMode) else {
            statusMessage = "Unknown mode from LLM: \(settings.recommendedMode)"
            return
        }
        isApplying = true
        statusMessage = "Switching dial control to app..."
        AppLogger.log("=== autoApply START — mode: \(settings.recommendedMode) ===")
        
        // Fixed-delay sequencing: we don't gate on (or react to) these commands'
        // acknowledgment callbacks. The PTP/IP session can drop right after a command
        // lands, or an ack can simply arrive late — either way, reacting to it after the
        // fact produced confusing UI (e.g. a "turn the dial" warning popping up after
        // settings had already applied successfully). We just fire each command and give
        // the camera fixed, real time to actually process/settle it before moving on.
        
        // Step 1: hand exposure-mode dial control over to the app. Confirmed on the 7C —
        // the camera exposes an APP/Camera toggle for this, and Exposure.Mode.set only
        // takes effect once control is switched to APP.
        AppLogger.log("Step 1: sending DialControl.set(.app)")
        camera.performFunction(Exposure.Mode.DialControl.set, payload: .app) { (error, _) in
            AppLogger.log("Step 1 CALLBACK received — error: \(error?.localizedDescription ?? "nil")")
        }
        
        // Step 2: 500ms later, set the actual exposure mode value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let camera = self.connectedCamera else { return }
            self.statusMessage = "Setting exposure mode to \(settings.recommendedMode)..."
            
            AppLogger.log("Step 2 (+500ms): sending Exposure.Mode.set(\(settings.recommendedMode))")
            camera.performFunction(Exposure.Mode.set, payload: modeVal) { (error, _) in
                AppLogger.log("Step 2 CALLBACK received — error: \(error?.localizedDescription ?? "nil")")
            }
            
            // Step 3: another 600ms later — exposure mode just changed, so the camera needs
            // time to re-meter/re-init AF etc. before ISO/aperture/shutter/focus/drive land cleanly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                AppLogger.log("Step 3 (+600ms): starting applyRemainingSettings")
                self.applyRemainingSettings(settings)
            }
        }
    }
    
    // MARK: - Applying individual settings
    
    private func applyRemainingSettings(_ settings: CameraSettings) {
        guard let camera = connectedCamera else { return }
        showAppliedConfirmation = false
        var results: [SettingResult] = []
        let group = DispatchGroup()
        var didFinish = false
        AppLogger.log("applyRemainingSettings START")
        
        // Camera (PTP/IP) often drops the remote session right after accepting the
        // last command, so that command's own completion callback never comes back
        // and group.notify would spin forever — even though the setting DID land on
        // the camera. finish() is called from whichever fires first: the real
        // group.notify, or this 2s safety timeout.
        func finish(source: String) {
            guard !didFinish else { return }
            didFinish = true
            let summary = results.map { r -> String in
                let status = r.applied ? "OK" : "FAIL(\(r.reason ?? "?"))"
                return "\(r.name): \(status)"
            }.joined(separator: ", ")
            AppLogger.log("applyRemainingSettings FINISH — triggered by: \(source). Results: [\(summary)]")
            self.settingResults = results
            self.isApplying = false
            self.statusMessage = "Done applying settings."
            self.showAppliedConfirmation = true
        }
        
        // ISO
        if let iso = settings.iso {
            group.enter()
            AppLogger.log("Sending ISO.set(\(iso))")
            camera.performFunction(ISO.set, payload: .native(iso)) { (error, _) in
                AppLogger.log("ISO.set CALLBACK — error: \(error?.localizedDescription ?? "nil")")
                results.append(SettingResult(name: "ISO \(iso)", applied: error == nil, reason: error?.localizedDescription))
                group.leave()
            }
        }
        
        // Aperture
        if let aperture = settings.aperture {
            group.enter()
            AppLogger.log("Sending Aperture.set(f/\(aperture))")
            camera.performFunction(Aperture.set, payload: Aperture.Value(value: aperture)) { (error, _) in
                AppLogger.log("Aperture.set CALLBACK — error: \(error?.localizedDescription ?? "nil")")
                results.append(SettingResult(name: "Aperture f/\(aperture)", applied: error == nil, reason: error?.localizedDescription))
                group.leave()
            }
        }
        
        // Shutter speed (parse "1/250" or "2" style strings)
        if let shutterString = settings.shutterSpeed, let shutterValue = Self.parseShutterSpeed(shutterString) {
            group.enter()
            AppLogger.log("Sending Shutter.Speed.set(\(shutterString))")
            camera.performFunction(Shutter.Speed.set, payload: shutterValue) { (error, _) in
                AppLogger.log("Shutter.Speed.set CALLBACK — error: \(error?.localizedDescription ?? "nil")")
                results.append(SettingResult(name: "Shutter \(shutterString)", applied: error == nil, reason: error?.localizedDescription))
                group.leave()
            }
        }
        
        // Focus Mode
        if let focusString = settings.focusMode, let focusValue = Self.parseFocusMode(focusString) {
            group.enter()
            AppLogger.log("Sending Focus.Mode.set(\(focusString))")
            camera.performFunction(Focus.Mode.set, payload: focusValue) { (error, _) in
                AppLogger.log("Focus.Mode.set CALLBACK — error: \(error?.localizedDescription ?? "nil")")
                results.append(SettingResult(name: "Focus Mode \(focusString.uppercased())", applied: error == nil, reason: error?.localizedDescription))
                group.leave()
            }
        }
        
        // Drive Mode
        if let driveString = settings.driveMode, let driveValue = Self.parseDriveMode(driveString) {
            group.enter()
            AppLogger.log("Sending ShootMode.set(\(driveString))")
            camera.performFunction(ShootMode.set, payload: driveValue) { (error, _) in
                AppLogger.log("ShootMode.set CALLBACK — error: \(error?.localizedDescription ?? "nil")")
                results.append(SettingResult(name: "Drive Mode \(driveString)", applied: error == nil, reason: error?.localizedDescription))
                group.leave()
            }
        }
        
        // White Balance — needs to fetch available values first, then match
        if let wbString = settings.whiteBalance, let wbMode = Self.parseWhiteBalanceMode(wbString) {
            group.enter()
            AppLogger.log("Checking WhiteBalance.set availability for \(wbString)")
            camera.isFunctionAvailable(WhiteBalance.set) { (available, error, values) in
                AppLogger.log("WhiteBalance.set isFunctionAvailable CALLBACK — available: \(String(describing: available)), error: \(error?.localizedDescription ?? "nil"), valueCount: \(values?.count ?? 0)")
                guard let match = values?.first(where: { $0.mode == wbMode }) else {
                    results.append(SettingResult(name: "White Balance \(wbString)", applied: false, reason: "Not supported by camera"))
                    group.leave()
                    return
                }
                AppLogger.log("Sending WhiteBalance.set(\(wbString))")
                camera.performFunction(WhiteBalance.set, payload: match) { (error, _) in
                    AppLogger.log("WhiteBalance.set CALLBACK — error: \(error?.localizedDescription ?? "nil")")
                    results.append(SettingResult(name: "White Balance \(wbString)", applied: error == nil, reason: error?.localizedDescription))
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            finish(source: "group.notify (all callbacks returned)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            finish(source: "2s timeout fallback (not all callbacks returned)")
        }
    }
    
    // MARK: - Parsing helpers
    
    private static func parseShutterSpeed(_ text: String) -> ShutterSpeed? {
        if text.contains("/") {
            let parts = text.split(separator: "/")
            guard parts.count == 2, let num = Double(parts[0]), let denom = Double(parts[1]) else { return nil }
            return ShutterSpeed(numerator: num, denominator: denom)
        } else if let whole = Double(text) {
            return ShutterSpeed(numerator: whole, denominator: 1)
        }
        return nil
    }
    
    private static func parseWhiteBalanceMode(_ text: String) -> WhiteBalance.Mode? {
        switch text.lowercased() {
        case "auto": return .auto
        case "daylight": return .daylight
        case "cloudy": return .cloudy
        case "shade": return .shade
        case "incandescent", "tungsten": return .incandescent
        default: return nil
        }
    }
    
    /// Maps our simple LLM-facing strings to Rocc's Focus.Mode.Value cases.
    private static func parseFocusMode(_ text: String) -> Focus.Mode.Value? {
        switch text.lowercased() {
        case "af": return .auto              // Automatic AF (AF-A)
        case "af_s", "afs": return .autoSingle       // Single-shot AF
        case "af_c", "afc": return .autoContinuous   // Continuous AF
        case "dmf": return .directManual             // Direct Manual Focus
        case "mf": return .manual                    // Manual Focus
        default: return nil
        }
    }
    
    /// Maps our simple LLM-facing strings to Rocc's ShootingMode cases (used by ShootMode.set).
    private static func parseDriveMode(_ text: String) -> ShootingMode? {
        switch text.lowercased() {
        case "photo": return .photo
        case "continuous": return .continuous
        case "bracket_single", "bracketsingle": return .singleBracket
        case "bracket_continuous", "bracketcontinuous": return .continuousBracket
        default: return nil
        }
    }
}
