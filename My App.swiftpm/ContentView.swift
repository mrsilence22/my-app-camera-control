import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CameraController()
    @State private var sceneText = ""
    @State private var result: CameraSettings?
    @State private var errorMessage: String?
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.08, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    header
                    statusBar
                    inputCard
                    
                    if isLoading {
                        ProgressView().tint(.orange).padding(.top, 8)
                    }
                    
                    if let result {
                        resultCard(result)
                        actionButtons(result)
                    }
                    
                    if controller.isApplying {
                        ProgressView("Applying settings...").tint(.orange).foregroundColor(.white)
                    }
                    
                    if controller.showAppliedConfirmation {
                        appliedConfirmationBanner
                    }
                    
                    if let errorMessage {
                        Text(errorMessage).foregroundColor(.red).font(.footnote).padding()
                    }
                }
                .padding()
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var header: some View {
        HStack {
            Image(systemName: "camera.aperture")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
            Text("Lens AI")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.top, 8)
    }
    
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.connectedCamera != nil ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(controller.statusMessage)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var inputCard: some View {
        VStack(spacing: 12) {
            TextField("", text: $sceneText, prompt: Text("Describe the scene...").foregroundColor(.white.opacity(0.4)))
                .foregroundColor(.white)
                .padding()
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            
            Button {
                isLoading = true
                errorMessage = nil
                result = nil
                controller.settingResults = []
                Task {
                    do {
                        result = try await ClaudeSettingsService.getSettings(sceneDescription: sceneText)
                    } catch {
                        errorMessage = "\(error)"
                    }
                    isLoading = false
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Get AI Settings").fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .foregroundColor(.white)
            }
            .disabled(sceneText.isEmpty || isLoading)
            .opacity(sceneText.isEmpty || isLoading ? 0.5 : 1)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode {
        case "manual": return .purple
        case "aperture_priority": return .blue
        case "shutter_priority": return .orange
        case "program": return .green
        default: return .gray
        }
    }
    
    private func focusModeLabel(_ mode: String) -> String {
        switch mode.lowercased() {
        case "af": return "AF"
        case "af_s", "afs": return "AF-S"
        case "af_c", "afc": return "AF-C"
        case "dmf": return "DMF"
        case "mf": return "MF"
        default: return mode.uppercased()
        }
    }
    
    private func driveModeLabel(_ mode: String) -> String {
        switch mode.lowercased() {
        case "photo": return "Photo"
        case "continuous": return "Continuous"
        case "bracket_single", "bracketsingle": return "Bracket (Single)"
        case "bracket_continuous", "bracketcontinuous": return "Bracket (Cont.)"
        default: return mode.capitalized
        }
    }
    
    private func resultCard(_ result: CameraSettings) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(result.recommendedMode.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.caption).fontWeight(.heavy)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(modeColor(result.recommendedMode).opacity(0.25), in: Capsule())
                    .foregroundColor(modeColor(result.recommendedMode))
                Spacer()
            }
            Text(result.modeReason)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.6))
            
            Divider().background(Color.white.opacity(0.15))
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                if let iso = result.iso { settingChip(icon: "dial.max", label: "ISO", value: "\(iso)") }
                if let ap = result.aperture { settingChip(icon: "camera.aperture", label: "Aperture", value: String(format: "f/%.1f", ap)) }
                if let ss = result.shutterSpeed { settingChip(icon: "timer", label: "Shutter", value: ss) }
                if let wb = result.whiteBalance { settingChip(icon: "thermometer.sun", label: "White Bal.", value: wb) }
                if let focus = result.focusMode { settingChip(icon: "viewfinder", label: "Focus", value: focusModeLabel(focus)) }
                if let drive = result.driveMode { settingChip(icon: "square.stack", label: "Drive", value: driveModeLabel(drive)) }
            }
            
            Divider().background(Color.white.opacity(0.15))
            Label(result.reasoning, systemImage: "lightbulb.fill")
                .font(.caption)
                .foregroundColor(.yellow.opacity(0.8))
            if !result.tips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.teal)
                                .font(.caption)
                            Text(tip)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(.top, 4)
            }

        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    
    private func settingChip(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundColor(.white.opacity(0.5))
                Text(value).font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    
    private func actionButtons(_ result: CameraSettings) -> some View {
        HStack(spacing: 12) {
            Button {
                controller.checkForCamera()
            } label: {
                Label("Check Camera", systemImage: "wifi")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundColor(.white)
            }
            
            Button {
                controller.autoApply(result)
            } label: {
                Label("Auto Apply", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundColor(.white)
            }
            .disabled(controller.connectedCamera == nil || controller.isApplying)
            .opacity(controller.connectedCamera == nil || controller.isApplying ? 0.4 : 1)
        }
    }
    
    private var appliedConfirmationBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Settings Applied")
                .foregroundColor(.white)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.4), lineWidth: 1))
        .transition(.opacity.combined(with: .scale))
        .animation(.easeInOut, value: controller.showAppliedConfirmation)
    }
    
}
