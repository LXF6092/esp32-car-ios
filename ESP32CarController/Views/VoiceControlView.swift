import SwiftUI

struct VoiceControlView: View {
    @ObservedObject var coordinator: ControlCoordinator
    @StateObject private var speech = SpeechController()
    @State private var speechStartTask: Task<Void, Never>?
    @State private var pulseTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Button {
                if speech.isListening {
                    speechStartTask?.cancel()
                    speech.stop()
                } else {
                    speechStartTask?.cancel()
                    speechStartTask = Task {
                        await speech.start { text in
                            handle(VoiceCommandParser.parse(text))
                        }
                    }
                }
            } label: {
                Image(systemName: speech.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(speech.isListening ? CarTheme.danger : CarTheme.primary)
                    .scaleEffect(speech.isListening ? 1.08 : 1)
                    .animation(
                        speech.isListening
                            ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                            : .default,
                        value: speech.isListening
                    )
            }
            .disabled(!coordinator.isConnected)

            Text(speech.status)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(speech.transcript.isEmpty ? "仅执行白名单驾驶口令" : speech.transcript)
                .font(.subheadline)
                .foregroundStyle(CarTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(minHeight: 38)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                QuickCommand(title: "前进", icon: "arrow.up", disabled: !coordinator.canDriveForward) {
                    handle(.drive(DriveVector(vx: 0, vy: 100, omega: 0)))
                }
                QuickCommand(title: "后退", icon: "arrow.down", disabled: !coordinator.canDrive) {
                    handle(.drive(DriveVector(vx: 0, vy: -100, omega: 0)))
                }
                QuickCommand(title: "左转", icon: "arrow.turn.up.left", disabled: !coordinator.canDrive) {
                    handle(.drive(DriveVector(vx: 0, vy: 0, omega: -100)))
                }
                QuickCommand(title: "右转", icon: "arrow.turn.up.right", disabled: !coordinator.canDrive) {
                    handle(.drive(DriveVector(vx: 0, vy: 0, omega: 100)))
                }
                QuickCommand(title: "停车", icon: "stop.fill", tint: CarTheme.warning, disabled: !coordinator.isConnected) {
                    handle(.stop)
                }
                QuickCommand(title: "急停", icon: "exclamationmark.octagon.fill", tint: CarTheme.danger, disabled: !coordinator.isConnected) {
                    handle(.emergencyStop)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .carCard()
        .onDisappear {
            speechStartTask?.cancel()
            speechStartTask = nil
            pulseTask?.cancel()
            speech.stop()
            coordinator.stop()
        }
    }

    private func handle(_ action: VoiceAction) {
        switch action {
        case .drive(let vector):
            pulseTask?.cancel()
            coordinator.updateDrive(vector)
            pulseTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { coordinator.stop() }
            }
        case .stop:
            pulseTask?.cancel()
            coordinator.stop()
        case .emergencyStop:
            pulseTask?.cancel()
            coordinator.emergencyStop()
        case .faster:
            coordinator.maxSpeed = min(60, coordinator.maxSpeed + 5)
        case .slower:
            coordinator.maxSpeed = max(10, coordinator.maxSpeed - 5)
        case .none:
            break
        }
    }
}

private struct QuickCommand: View {
    let title: String
    let icon: String
    var tint: Color = CarTheme.primary
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(disabled ? "不可用" : "可用")
    }
}
