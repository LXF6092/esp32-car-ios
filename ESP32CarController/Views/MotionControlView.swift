import SwiftUI

struct MotionControlView: View {
    @ObservedObject var coordinator: ControlCoordinator
    @StateObject private var motion = MotionController()
    @State private var enabled = false
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(CarTheme.raised)
                    .overlay { Circle().stroke(CarTheme.border, lineWidth: 1) }
                Circle()
                    .stroke(CarTheme.primary.opacity(0.24), lineWidth: 1)
                    .padding(28)
                Circle()
                    .fill(enabled ? CarTheme.primary : CarTheme.secondaryText)
                    .frame(width: 34, height: 34)
                    .offset(
                        x: CGFloat(max(-1, min(1, motion.rollDegrees / 30))) * 70,
                        y: CGFloat(max(-1, min(1, motion.pitchDegrees / 30))) * 70
                    )
                    .animation(.linear(duration: 0.05), value: motion.pitchDegrees)
            }
            .frame(width: 210, height: 210)

            Text(String(format: "前后 %.1f° · 左右 %.1f°", motion.pitchDegrees, motion.rollDegrees))
                .font(.headline.monospacedDigit())

            if let error = motion.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(CarTheme.warning)
            } else {
                Text(motion.isFresh ? "体感数据正常" : "等待有效体感数据")
                    .font(.caption)
                    .foregroundStyle(motion.isFresh ? CarTheme.success : CarTheme.secondaryText)
            }

            HStack(spacing: 12) {
                Button("标定当前水平") {
                    motion.calibrate()
                }
                .buttonStyle(.bordered)
                .disabled(!motion.hasSample)

                Button(enabled ? "停止体感" : "开启体感") {
                    if enabled {
                        enabled = false
                        coordinator.stop()
                    } else if coordinator.canDrive && motion.isFresh {
                        motion.calibrate()
                        enabled = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(enabled ? CarTheme.warning : CarTheme.primary)
                .disabled(!enabled && (!coordinator.canDrive || !motion.isFresh))
            }
        }
        .frame(maxWidth: .infinity)
        .carCard()
        .onAppear { motion.start() }
        .onDisappear {
            enabled = false
            coordinator.stop()
            motion.stop()
        }
        .onReceive(timer) { _ in
            guard enabled else { return }
            guard coordinator.canDrive, motion.isFresh else {
                enabled = false
                coordinator.stop()
                return
            }
            coordinator.updateDrive(motion.driveVector())
        }
    }
}
