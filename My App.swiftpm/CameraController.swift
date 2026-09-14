
import Foundation
import UIKit
import Rocc

class CameraController: NSObject, ObservableObject, CameraDiscovererDelegate {
    @Published var statusMessage = "Searching for camera on WiFi..."
    @Published var connectedCamera: Camera?
    @Published var cameraInfo: String = ""
    @Published var cameraCapabilities: CameraCapabilities?
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
        cameraInfo = ""
        discoverer.stop(with: { [weak self] in
            self?.discoverer.start()
        })
    }

    func fetchCapabilities() {
        guard let camera = connectedCamera else { return }
        AppLogger.log("fetchCapabilities() START")
        var capabilities = CameraCapabilities()
        let group = DispatchGroup()

        group.enter()
        camera.isFunctionAvailable(ISO.set) { (available, error, values) in
            AppLogger.log("ISO capability CALLBACK — available: \(String(describing: available)), error: \(error?.localizedDescription ?? "nil"), count: \(values?.count ?? 0)")
            capabilities.isoValues = (values ?? []).compactMap { value in
                if case .native(let intVal) = value { return intVal }
                return nil
            }.sorted()
            group.leave()
        }

        group.enter()
        camera.isFunctionAvailable(Aperture.set) { (available, error, values) in
            AppLogger.log("Aperture capability CALLBACK — available: \(String(describing: available)), error: \(error?.localizedDescription ?? "nil"), count: \(values?.count ?? 0)")
            capabilities.apertureValues = (values ?? []).map { $0.value }.sorted()
            group.leave()
        }

        group.enter()
        camera.isFunctionAvailable(Shutter.Speed.set) { (available, error, values) in
            AppLogger.log("Shutter capability CALLBACK — available: \(String(describing: available)), error: \(error?.localizedDescription ?? "nil"), count: \(values?.count ?? 0)")
            let formatter = ShutterSpeedFormatter()
            capabilities.shutterSpeedValues = (values ?? []).map { formatter.string(from: $0) }
            group.leave()
        }

        group.notify(queue: .main) {
            AppLogger.log("fetchCapabilities() DONE — ISO: \(capabilities.isoValues.count), Aperture: \(capabilities.apertureValues.count), Shutter: \(capabilities.shutterSpeedValues.count)")
            self.cameraCapabilities = capabilities
        }
    }

    // MARK: - DEBUG-only testing helpers

    #if DEBUG
    func connectSimulatedCamera() {
        AppLogger.log("connectSimulatedCamera() — using Rocc's DummyCamera for offline testing")
        let dummy = DummyCamera()
        dummy.connect { [weak self] (error, isInTransferMode) in
            DispatchQueue.main.async {
                self?.connectedCamera = dummy
                self?.cameraInfo = "\(dummy.name ?? "Simulated Camera") · \(dummy.lensModelName ?? "Lens unknown")"
                self?.statusMessage = "Connected to simulated camera (DEBUG)"
                self?.fetchCapabilities()
            }
        }
    }

    func testCapabilityFormattingLogic() {
        let fakeISOValues: [ISO.Value] = [.native(100), .native(200), .native(400), .auto, .extended(50)]
        let extractedISO = fakeISOValues.compactMap { value -> Int? in
            if case .native(let intVal) = value { return intVal }
            return nil
        }.sorted()
        AppLogger.log("testCapabilityFormattingLogic — ISO extraction result: \(extractedISO) (expected: [100, 200, 400], .auto and .extended should be filtered out)")

        let fakeApertureValues: [Aperture.Value] = [
            Aperture.Value(value: 2.8), Aperture.Value(value: 4.0), Aperture.Value(value: 22.0)
        ]
        let extractedAperture = fakeApertureValues.map { $0.value }.sorted()
        let formattedAperture = extractedAperture.map { String(format: "f/%.1f", $0) }
        AppLogger.log("testCapabilityFormattingLogic — Aperture formatted result: \(formattedAperture) (expected: [\"f/2.8\", \"f/4.0\", \"f/22.0\"])")
    }

    func testFullPipelineWithSimulatedCamera() async {
        AppLogger.log("=== testFullPipelineWithSimulatedCamera START ===")
        connectSimulatedCamera()

        // fetchCapabilities is async, wait a bit for it to complete
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        guard let caps = cameraCapabilities else {
            AppLogger.log("TEST FAILED — cameraCapabilities is nil, fetchCapabilities() did not complete")
            return
        }

        AppLogger.log("Simulated camera capabilities — ISO: \(caps.isoValues.count) values, Aperture: \(caps.apertureValues.count) values, Shutter: \(caps.shutterSpeedValues.count) values")
        AppLogger.log("Expected: ISO=0, Aperture=0 (DummyCamera's own cast bug), Shutter=~30 (real values)")

        do {
            let result = try await ClaudeSettingsService.getSettings(
                sceneDescription: "A test scene: bright outdoor daylight, fast-moving subject",
                cameraName: connectedCamera?.name,
                capabilities: caps
            )
            AppLogger.log("Claude returned — mode: \(result.recommendedMode), iso: \(String(describing: result.iso)), aperture: \(String(describing: result.aperture)), shutter: \(String(describing: result.shutterSpeed))")

            // Verify: if we sent a shutter list, Claude's returned shutter value should be in it
            if !caps.shutterSpeedValues.isEmpty, let returnedShutter = result.shutterSpeed {
                let matchFound = caps.shutterSpeedValues.contains(returnedShutter)
                AppLogger.log(matchFound
                    ? "✅ VERIFIED — Claude's shutter speed (\(returnedShutter)) is present in our supported list"
                    : "⚠️ MISMATCH — Claude returned '\(returnedShutter)' which is not in our list: \(caps.shutterSpeedValues)")
            }
        } catch {
            AppLogger.log("TEST FAILED — API call error: \(error.localizedDescription)")
        }
        AppLogger.log("=== testFullPipelineWithSimulatedCamera END ===")
    }

    func testAperturePromptReliability() async {
        AppLogger.log("=== testAperturePromptReliability START ===")
        let sceneText = "Close-up portrait of a person, background completely blurred with soft creamy bokeh"

        let primeLensCaps = CameraCapabilities(
            isoValues: [],
            apertureValues: [1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10.0, 11.0, 13.0, 14.0, 16.0, 18.0, 20.0, 22.0],
            shutterSpeedValues: []
        )
        let zoomLensCaps = CameraCapabilities(
            isoValues: [],
            apertureValues: [3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10.0, 11.0, 13.0, 14.0, 16.0, 18.0, 20.0, 22.0],
            shutterSpeedValues: []
        )

        do {
            let primeResult = try await ClaudeSettingsService.getSettings(sceneDescription: sceneText, cameraName: "Sony a7C (test - fast prime lens)", capabilities: primeLensCaps)
            let zoomResult = try await ClaudeSettingsService.getSettings(sceneDescription: sceneText, cameraName: "Sony a7C (test - slow zoom lens)", capabilities: zoomLensCaps)

            AppLogger.log("Prime lens — Claude picked: \(String(describing: primeResult.aperture)), list widest available: \(primeLensCaps.apertureValues.min() ?? -1)")
            AppLogger.log("Zoom lens — Claude picked: \(String(describing: zoomResult.aperture)), list widest available: \(zoomLensCaps.apertureValues.min() ?? -1)")

            if let primeAp = primeResult.aperture, let zoomAp = zoomResult.aperture {
                AppLogger.log(primeAp < zoomAp
                    ? "✅ Prime lens aperture (\(primeAp)) wider than zoom lens (\(zoomAp)) — demo should show visible difference"
                    : "⚠️ No meaningful difference — prime: \(primeAp), zoom: \(zoomAp). Prompt rule needs strengthening.")

                let primeIsWidest = abs(primeAp - (primeLensCaps.apertureValues.min() ?? -1)) < 0.01
                let zoomIsWidest = abs(zoomAp - (zoomLensCaps.apertureValues.min() ?? -1)) < 0.01
                AppLogger.log("Prime picked exact widest available: \(primeIsWidest), Zoom picked exact widest available: \(zoomIsWidest)")
            }
        } catch {
            AppLogger.log("testAperturePromptReliability FAILED — \(error.localizedDescription)")
        }
        AppLogger.log("=== testAperturePromptReliability END ===")
    }

    func dumpAllCameraCapabilities() {
        guard let camera = connectedCamera else {
            AppLogger.log("dumpAllCameraCapabilities — no camera connected, connect to the real a7C first (not simulated)")
            return
        }
        AppLogger.log("=== dumpAllCameraCapabilities START — camera: \(cameraInfo) ===")
        let group = DispatchGroup()

        func check<T: CameraFunction>(_ label: String, _ function: T) {
            group.enter()
            camera.isFunctionAvailable(function) { (available, error, values) in
                let valuesDesc: String
                if let values = values {
                    valuesDesc = "\(values.count) values: \(values.map { String(describing: $0) })"
                } else {
                    valuesDesc = "nil"
                }
                AppLogger.log("[\(label)] available: \(String(describing: available)), error: \(error?.localizedDescription ?? "nil"), values: \(valuesDesc)")
                group.leave()
            }
        }

        check("ISO", ISO.set)
        check("Aperture", Aperture.set)
        check("Shutter Speed", Shutter.Speed.set)
        check("White Balance", WhiteBalance.set)
        check("Focus Mode", Focus.Mode.set)
        check("Shoot Mode (Drive)", ShootMode.set)
        check("Exposure Mode", Exposure.Mode.set)
        check("Exposure Compensation", Exposure.Compensation.set)
        check("Exposure Settings Lock", Exposure.SettingsLock.set)
        check("Steady Mode (Stabilization)", SteadyMode.set)
        check("Flash Mode", Flash.Mode.set)
        check("Still Quality (RAW/JPEG)", StillCapture.Quality.set)
        check("Still Format", StillCapture.Format.set)
        check("Still Size", StillCapture.Size.set)
        check("Continuous Shooting Mode", ContinuousCapture.Mode.set)
        check("Continuous Shooting Speed", ContinuousCapture.Speed.set)
        check("Self Timer Duration", SelfTimerDuration.set)
        check("Color Setting", ColorSetting.set)
        check("Beep Mode", BeepMode.set)
        check("Auto Power Off", AutoPowerOff.set)
        check("Wind Noise Reduction", WindNoiseReduction.set)

        group.notify(queue: .main) {
            AppLogger.log("=== dumpAllCameraCapabilities DONE (21 settings checked) ===")
        }
    }
    #endif

    func cameraDiscoverer(_ discoverer: CameraDiscoverer, didError error: Error) {
        guard connectedCamera == nil else {
            AppLogger.log("Discovery ERROR (ignored — already connected): \(error.localizedDescription)")
            return
        }
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
                    let cameraName = device.name ?? device.model ?? "Camera"
                    if let lens = device.lensModelName, !lens.isEmpty {
                        self?.cameraInfo = "\(cameraName) · \(lens)"
                    } else {
                        self?.cameraInfo = cameraName
                    }
                    self?.discoverer.stop(with: {})
                    self?.fetchCapabilities()
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
