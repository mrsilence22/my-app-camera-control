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
                    
                    if let modeNeeded = controller.needsManualModeSwitch {
                        modeWarningCard(modeNeeded)
                    }
                    
                    if !controller.settingResults.isEmpty {
                        resultsListCard
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
                if let ev = result.exposureCompensation { settingChip(icon: "plusminus", label: "Exp. Comp", value: String(format: "%.1f EV", ev)) }
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
    
    private func modeWarningCard(_ mode: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.yellow)
            Text("Turn your mode dial to")
                .foregroundColor(.white.opacity(0.7))
                .font(.footnote)
            Text(mode.replacingOccurrences(of: "_", with: " ").uppercased())
                .font(.headline).fontWeight(.heavy)
                .foregroundColor(.yellow)
            Button("Done, Continue") {
                controller.confirmManualModeSwitchDone()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color.yellow, in: Capsule())
            .foregroundColor(.black)
            .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yellow.opacity(0.4), lineWidth: 1))
        .transition(.scale.combined(with: .opacity))
    }
    
    private var resultsListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPLY RESULTS").font(.caption).fontWeight(.heavy).foregroundColor(.white.opacity(0.5))
            ForEach(controller.settingResults) { r in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: r.applied ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(r.applied ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).foregroundColor(.white).font(.subheadline)
                        if let reason = r.reason {
                            Text(reason).font(.caption2).foregroundColor(.white.opacity(0.4))
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
