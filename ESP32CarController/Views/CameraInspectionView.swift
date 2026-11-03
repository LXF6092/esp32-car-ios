import Foundation
import SwiftUI

private enum InspectionOperationMode: String, CaseIterable, Identifiable {
    case line = "线路巡检"
    case object = "物件跟随"
    case person = "人物跟随"

    var id: String { rawValue }
}

struct CameraInspectionView: View {
    @ObservedObject var coordinator: ControlCoordinator
    @StateObject private var camera = CameraInspectionController()
    @State private var operationMode: InspectionOperationMode = .line
    @State private var automationEnabled = false
    @State private var previousSpeed: UInt8?
    @State private var handledMarker: String?
    @State private var checkpointMessage = "尚未识别检查点"
    @State private var previousTargetError: Double = 0
    @State private var lastControlAt = Date()
    @State private var selectionRectangle: CGRect?
    @State private var smoothedTargetSize: Double?
    @State private var previousTargetSize: Double?
    @State private var smoothedSonarDistance: Double?
    @State private var distanceHold = false
    @AppStorage("objectFollowTargetSize") private var objectTargetSize = 0.34
    @AppStorage("personFollowShoulderWidth") private var personTargetSize = 0.16

    private let controlTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Picker("巡检方式", selection: $operationMode) {
                ForEach(InspectionOperationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            cameraPanel

            HStack {
                Label(statusText, systemImage: statusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
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

            if operationMode == .person {
                Button("重新检测单个人物") {
                    stopAutomation()
                    camera.startPersonDetection()
                }
                .buttonStyle(.bordered)
            }

            if operationMode != .line {
                Button("把当前位置设为保持距离") {
                    calibrateFollowDistance()
                }
                .buttonStyle(.bordered)
                .disabled(camera.targetBoundingBox == nil)
            }

            HStack(spacing: 12) {
                Button(automationEnabled ? "停止" : primaryButtonTitle) {
                    automationEnabled ? stopAutomation() : startAutomation()
                }
                .buttonStyle(.borderedProminent)
                .tint(automationEnabled ? CarTheme.warning : CarTheme.primary)
                .frame(maxWidth: .infinity, minHeight: 54)
                .disabled(!automationEnabled && !canStartAutomation)

                Button("立即停车") {
                    stopAutomation()
                    coordinator.stop()
                }
                .buttonStyle(.borderedProminent)
                .tint(CarTheme.danger)
                .frame(maxWidth: .infinity, minHeight: 54)
                .disabled(!coordinator.isConnected)
            }

            Text(helpText)
                .font(.caption2)
                .foregroundStyle(CarTheme.secondaryText)
                .multilineTextAlignment(.leading)
        }
        .carCard()
        .onAppear { camera.start() }
        .onDisappear {
            stopAutomation()
            camera.clearTarget()
            camera.stop()
            coordinator.stop()
        }
        .onReceive(controlTimer) { _ in updateAutomation() }
        .onChange(of: camera.lastMarkerText) { marker in handleMarker(marker) }
        .onChange(of: operationMode) { mode in configure(mode) }
    }

    private var cameraPanel: some View {
        GeometryReader { outer in
            let previewWidth = min(outer.size.width, outer.size.height * 0.75)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .topTrailing) {
                    CameraPreview(session: camera.session)
                        .background(Color.black)

                    if let box = camera.targetBoundingBox, operationMode != .line {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(CarTheme.success, lineWidth: 3)
                            .frame(
                                width: max(4, box.width * previewWidth),
                                height: max(4, box.height * outer.size.height)
                            )
                            .position(
                                x: box.midX * previewWidth,
                                y: (1 - box.midY) * outer.size.height
                            )
                    }

                    if let selectionRectangle, operationMode == .object {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(CarTheme.cyan, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                            .frame(width: selectionRectangle.width, height: selectionRectangle.height)
                            .position(x: selectionRectangle.midX, y: selectionRectangle.midY)
                    }

                    if operationMode == .object {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        selectionRectangle = standardizedRectangle(
                                            from: value.startLocation,
                                            to: value.location,
                                            width: previewWidth,
                                            height: outer.size.height
                                        )
                                    }
                                    .onEnded { value in
                                        stopAutomation()
                                        let selection = standardizedRectangle(
                                            from: value.startLocation,
                                            to: value.location,
                                            width: previewWidth,
                                            height: outer.size.height
                                        )
                                        if selection.width >= 18, selection.height >= 18 {
                                            camera.lockObject(in: CGRect(
                                                x: selection.minX / previewWidth,
                                                y: 1 - selection.maxY / outer.size.height,
                                                width: selection.width / previewWidth,
                                                height: selection.height / outer.size.height
                                            ))
                                            checkpointMessage = "物件框选完成，可开始跟随"
                                        } else {
                                            let point = CGPoint(
                                                x: max(0, min(1, value.location.x / previewWidth)),
                                                y: max(0, min(1, 1 - value.location.y / outer.size.height))
                                            )
                                            camera.lockObject(at: point)
                                            checkpointMessage = "已按点击位置选择物件"
                                        }
                                        selectionRectangle = nil
                                    }
                            )
                    }

                    StatusBadge(
                        text: automationEnabled ? operationMode.rawValue : "相机预览",
                        color: automationEnabled ? CarTheme.success : CarTheme.cyan
                    )
                    .padding(10)
                }
                .frame(width: previewWidth, height: outer.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(automationEnabled ? CarTheme.success : CarTheme.border, lineWidth: 2)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 340)
    }

    private var statusText: String {
        switch operationMode {
        case .line:
            guard camera.frameIsFresh else { return "相机画面失效" }
            guard let offset = camera.lineOffset else { return "未识别到引导线" }
            return String(format: "线路偏移 %+.0f%% · 置信度 %.0f%%", offset * 100, camera.lineConfidence * 100)
        case .object, .person:
            guard let box = camera.targetBoundingBox else { return camera.targetStatus }
            var text = String(
                format: "%@ · 置信度 %.0f%% · 大小 %.0f%%",
                camera.targetStatus,
                camera.targetConfidence * 100,
                (camera.targetDistanceMetric ?? Double(max(box.width, box.height))) * 100
            )
            if operationMode == .object, let distance = camera.targetIdentityDistance {
                text += String(format: " · 特征差 %.1f", distance)
            }
            if let sonar = coordinator.telemetry.distanceCentimetres {
                text += String(format: " · %.0fcm", sonar)
            }
            return text
        }
    }

    private var statusIcon: String {
        switch operationMode {
        case .line: return camera.lineOffset == nil ? "viewfinder.circle" : "point.topleft.down.to.point.bottomright.curvepath"
        case .object: return camera.targetBoundingBox == nil ? "scope" : "shippingbox.fill"
        case .person: return camera.targetBoundingBox == nil ? "person.crop.rectangle.dashed" : "figure.walk"
        }
    }

    private var statusColor: Color {
        switch operationMode {
        case .line: return camera.lineOffset == nil ? CarTheme.warning : CarTheme.success
        case .object, .person: return camera.targetBoundingBox == nil ? CarTheme.warning : CarTheme.success
        }
    }

    private var primaryButtonTitle: String {
        operationMode == .line ? "开始巡检" : "开始跟随"
    }

    private var canStartAutomation: Bool {
        guard coordinator.canDrive, camera.isRunning, camera.frameIsFresh else { return false }
        if operationMode == .line { return camera.lineOffset != nil }
        return camera.targetBoundingBox != nil && camera.targetIsFresh
    }

    private var helpText: String {
        switch operationMode {
        case .line:
            return "识别浅色地面上的深色引导线；二维码仅接受停车和检查点命令。"
        case .object:
            return "用手指拖框准确选择小玩具；轻点仍可快速选择，丢失时停车并持续搜索。"
        case .person:
            return "不做人脸识别；按最后位置持续重新锁定，重新识别后自动恢复跟随。"
        }
    }

    private func configure(_ mode: InspectionOperationMode) {
        stopAutomation()
        checkpointMessage = "等待选择"
        switch mode {
        case .line:
            camera.clearTarget()
        case .object:
            camera.clearTarget()
            checkpointMessage = "请点击画面中的小玩具"
        case .person:
            camera.startPersonDetection()
            checkpointMessage = "正在寻找单个人物"
        }
    }

    private func startAutomation() {
        guard canStartAutomation else { return }
        previousSpeed = coordinator.maxSpeed
        coordinator.maxSpeed = min(coordinator.maxSpeed, operationMode == .line ? 20 : 15)
        resetFollowController()
        automationEnabled = true
    }

    private func stopAutomation() {
        automationEnabled = false
        coordinator.stop()
        if let previousSpeed {
            coordinator.maxSpeed = previousSpeed
            self.previousSpeed = nil
        }
        resetFollowController()
    }

    private func updateAutomation() {
        guard automationEnabled else { return }
        guard coordinator.canDrive, camera.isRunning, camera.frameIsFresh else {
            safetyStop("安全停车：连接或相机失效")
            return
        }

        let vector: DriveVector
        switch operationMode {
        case .line:
            vector = InspectionGuidance.driveVector(
                lineOffset: camera.lineOffset,
                confidence: camera.lineConfidence,
                frameIsFresh: camera.frameIsFresh
            )
        case .object, .person:
            guard camera.targetBoundingBox != nil, camera.targetIsFresh else {
                coordinator.stop()
                checkpointMessage = "目标暂时丢失：停车等待重新锁定"
                return
            }
            let now = Date()
            let box = camera.targetBoundingBox
            let currentError = box.map { max(-1, min(1, ($0.midX - 0.5) * 2)) } ?? 0
            let rawSize = camera.targetDistanceMetric ?? box.map { Double(max($0.width, $0.height)) } ?? 0
            let filteredSize = smoothedTargetSize.map { $0 * 0.70 + rawSize * 0.30 } ?? rawSize
            let dt = max(0.04, min(0.25, now.timeIntervalSince(lastControlAt)))
            let sizeVelocity = previousTargetSize.map { (filteredSize - $0) / dt } ?? 0
            smoothedTargetSize = filteredSize
            previousTargetSize = filteredSize

            if let sonar = coordinator.telemetry.distanceCentimetres {
                smoothedSonarDistance = smoothedSonarDistance.map { $0 * 0.65 + sonar * 0.35 } ?? sonar
            }
            let desiredSize = operationMode == .object ? objectTargetSize : personTargetSize
            if distanceHold {
                if filteredSize < desiredSize - max(0.025, desiredSize * 0.16) { distanceHold = false }
            } else if filteredSize >= desiredSize - max(0.012, desiredSize * 0.07) {
                distanceHold = true
            }
            vector = TargetFollowGuidance.driveVector(
                boundingBox: camera.targetBoundingBox,
                confidence: camera.targetConfidence,
                targetIsFresh: camera.targetIsFresh,
                desiredTargetSize: desiredSize,
                observedTargetSize: filteredSize,
                targetSizeVelocity: sizeVelocity,
                allowApproach: !distanceHold,
                obstacleDistanceCentimetres: smoothedSonarDistance,
                previousHorizontalError: previousTargetError,
                deltaTime: dt
            )
            previousTargetError = currentError
            lastControlAt = now
        }

        vector.isZero ? coordinator.stop() : coordinator.updateDrive(vector)
    }

    private func safetyStop(_ message: String) {
        stopAutomation()
        checkpointMessage = message
    }

    private func calibrateFollowDistance() {
        guard let box = camera.targetBoundingBox else { return }
        let size = camera.targetDistanceMetric ?? Double(max(box.width, box.height))
        let minimum = operationMode == .person ? 0.04 : 0.10
        guard size >= minimum, size <= 0.70 else {
            checkpointMessage = "目标大小不适合标定，请调整距离"
            return
        }
        if operationMode == .object {
            objectTargetSize = size
        } else if operationMode == .person {
            personTargetSize = size
        }
        checkpointMessage = String(format: "保持距离已标定：目标大小 %.0f%%", size * 100)
    }

    private func resetFollowController() {
        previousTargetError = 0
        lastControlAt = Date()
        smoothedTargetSize = nil
        previousTargetSize = nil
        smoothedSonarDistance = nil
        distanceHold = false
    }

    private func standardizedRectangle(
        from start: CGPoint,
        to end: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let startX = max(0, min(width, start.x))
        let startY = max(0, min(height, start.y))
        let endX = max(0, min(width, end.x))
        let endY = max(0, min(height, end.y))
        return CGRect(
            x: min(startX, endX),
            y: min(startY, endY),
            width: abs(endX - startX),
            height: abs(endY - startY)
        )
    }

    private func handleMarker(_ marker: String?) {
        guard let marker, marker != handledMarker else { return }
        handledMarker = marker
        switch InspectionGuidance.parseMarker(marker) {
        case .stop:
            stopAutomation()
            checkpointMessage = "二维码停车"
        case .checkpoint(let name):
            checkpointMessage = "检查点：\(name)"
        case .ignored:
            break
        }
    }
}
