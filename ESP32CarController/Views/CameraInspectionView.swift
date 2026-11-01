import Foundation
import SwiftUI

struct CameraInspectionView: View {
    @ObservedObject var coordinator: ControlCoordinator
    @StateObject private var camera = CameraInspectionController()
    @State private var patrolEnabled = false
    @State private var previousSpeed: UInt8?
    @State private var handledMarker: String?
    @State private var checkpointMessage = "尚未识别检查点"

    private let controlTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                CameraPreview(session: camera.session)
                    .frame(height: 310)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(patrolEnabled ? CarTheme.success : CarTheme.border, lineWidth: 2)
                    }
                StatusBadge(
                    text: patrolEnabled ? "自动巡检" : "相机预览",
                    color: patrolEnabled ? CarTheme.success : CarTheme.cyan
                )
                .padding(12)
            }

            HStack {
                Label(lineStatus, systemImage: camera.lineOffset == nil ? "viewfinder.circle" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(camera.lineOffset == nil ? CarTheme.warning : CarTheme.success)
                Spacer()
                Text(checkpointMessage)
                    .font(.caption)
                    .foregroundStyle(CarTheme.secondaryText)
                    .lineLimit(1)
            }

            if let error = camera.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(CarTheme.danger)
            }

            HStack(spacing: 12) {
                Button(patrolEnabled ? "停止巡检" : "开始巡检") {
                    patrolEnabled ? stopPatrol() : startPatrol()
                }
                .buttonStyle(.borderedProminent)
                .tint(patrolEnabled ? CarTheme.warning : CarTheme.primary)
                .frame(maxWidth: .infinity, minHeight: 54)
                .disabled(!patrolEnabled && (!coordinator.canDrive || !camera.isRunning))

                Button("立即停车") {
                    stopPatrol()
                    coordinator.stop()
                }
                .buttonStyle(.borderedProminent)
                .tint(CarTheme.danger)
                .frame(maxWidth: .infinity, minHeight: 54)
                .disabled(!coordinator.isConnected)
            }

            Text("识别浅色地面上的深色引导线；二维码仅接受 ESP32CAR:STOP 和 ESP32CAR:CHECKPOINT:名称。")
                .font(.caption2)
                .foregroundStyle(CarTheme.secondaryText)
                .multilineTextAlignment(.leading)
        }
        .carCard()
        .onAppear { camera.start() }
        .onDisappear {
            stopPatrol()
            camera.stop()
            coordinator.stop()
        }
        .onReceive(controlTimer) { _ in updatePatrol() }
        .onChange(of: camera.lastMarkerText) { marker in handleMarker(marker) }
    }

    private var lineStatus: String {
        guard camera.frameIsFresh else { return "相机画面失效" }
        guard let offset = camera.lineOffset else { return "未识别到引导线" }
        return String(format: "线路偏移 %+.0f%% · 置信度 %.0f%%", offset * 100, camera.lineConfidence * 100)
    }

    private func startPatrol() {
        guard coordinator.canDrive, camera.isRunning, camera.frameIsFresh else { return }
        previousSpeed = coordinator.maxSpeed
        coordinator.maxSpeed = min(coordinator.maxSpeed, 20)
        patrolEnabled = true
    }

    private func stopPatrol() {
        patrolEnabled = false
        coordinator.stop()
        if let previousSpeed {
            coordinator.maxSpeed = previousSpeed
            self.previousSpeed = nil
        }
    }

    private func updatePatrol() {
        guard patrolEnabled else { return }
        guard coordinator.canDrive, camera.isRunning, camera.frameIsFresh else {
            stopPatrol()
            checkpointMessage = "安全停车：连接或视觉失效"
            return
        }
        let vector = InspectionGuidance.driveVector(
            lineOffset: camera.lineOffset,
            confidence: camera.lineConfidence,
            frameIsFresh: camera.frameIsFresh
        )
        if vector.isZero {
            coordinator.stop()
        } else {
            coordinator.updateDrive(vector)
        }
    }

    private func handleMarker(_ marker: String?) {
        guard let marker, marker != handledMarker else { return }
        handledMarker = marker
        switch InspectionGuidance.parseMarker(marker) {
        case .stop:
            stopPatrol()
            checkpointMessage = "二维码停车"
        case .checkpoint(let name):
            checkpointMessage = "检查点：\(name)"
        case .ignored:
            break
        }
    }
}
