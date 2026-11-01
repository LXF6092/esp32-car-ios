import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var coordinator: ControlCoordinator
    @State private var showsTelemetry = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    connectionHeader
                    modePicker
                    controlPanel
                    speedControl
                    telemetrySummary
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 116)
            }
            .background(CarTheme.background.ignoresSafeArea())
            .navigationTitle("ESP32 麦轮小车")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                SafetyActionBar(coordinator: coordinator)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { coordinator.start() }
        .onChange(of: coordinator.mode) { _ in coordinator.stop() }
    }

    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: connectionColor.opacity(0.5), radius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.statusMessage)
                        .font(.headline.weight(.semibold))
                    Text(coordinator.isConnected ? "BLE 主控制已建立" : "BLE 主控制未建立")
                        .font(.caption)
                        .foregroundStyle(CarTheme.secondaryText)
                }

                Spacer()

                if coordinator.isConnected, let rssi = coordinator.rssi {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(CarTheme.success)
                        Text("\(rssi) dBm")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(CarTheme.secondaryText)
                    }
                } else if !coordinator.isConnected {
                    Button("重新搜索") { coordinator.start() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: safetyIcon)
                    .foregroundStyle(safetyColor)
                Text(coordinator.safetyStatusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(safetyColor)
                Spacer()
                StatusBadge(text: coordinator.telemetry.isArmed ? "已使能" : "未使能", color: coordinator.telemetry.isArmed ? CarTheme.success : CarTheme.warning)
            }
        }
        .carCard()
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("驾驶模式", systemImage: "steeringwheel")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("松手即停")
                    .font(.caption)
                    .foregroundStyle(CarTheme.secondaryText)
            }

            Picker("控制模式", selection: $coordinator.mode) {
                ForEach(ControlMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .carCard()
    }

    @ViewBuilder
    private var controlPanel: some View {
        switch coordinator.mode {
        case .joystick:
            JoystickView(coordinator: coordinator)
        case .directional:
            DirectionPadView(coordinator: coordinator)
        case .motion:
            MotionControlView(coordinator: coordinator)
        case .voice:
            VoiceControlView(coordinator: coordinator)
        case .inspection:
            CameraInspectionView(coordinator: coordinator)
        }
    }

    private var speedControl: some View {
        VStack(spacing: 9) {
            HStack {
                Label("速度上限", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(coordinator.maxSpeed)%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(CarTheme.primary)
            }

            Slider(
                value: Binding(
                    get: { Double(coordinator.maxSpeed) },
                    set: { coordinator.maxSpeed = UInt8($0) }
                ),
                in: 10...60,
                step: 5
            )
            .tint(CarTheme.primary)
        }
        .carCard()
    }

    private var telemetrySummary: some View {
        DisclosureGroup(isExpanded: $showsTelemetry) {
            TelemetryPanel(telemetry: coordinator.telemetry, rssi: coordinator.rssi)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(CarTheme.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("遥测详情")
                        .font(.subheadline.weight(.semibold))
                    Text(telemetrySummaryText)
                        .font(.caption)
                        .foregroundStyle(CarTheme.secondaryText)
                }
                Spacer()
                StatusBadge(text: coordinator.telemetry.isEmergencyStopped ? "急停" : (coordinator.telemetry.flags.contains(.obstacle) ? "有障碍" : "正常"), color: telemetrySummaryColor)
            }
        }
        .tint(Color.white)
        .carCard()
    }

    private var telemetrySummaryText: String {
        if let distance = coordinator.telemetry.distanceCentimetres {
            return String(format: "前方 %.1f cm · 序号 %u", distance, coordinator.telemetry.lastSequence)
        }
        return "等待车辆遥测数据"
    }

    private var telemetrySummaryColor: Color {
        if coordinator.telemetry.isEmergencyStopped || coordinator.telemetry.state == .fault {
            return CarTheme.danger
        }
        if coordinator.telemetry.flags.contains(.obstacle) {
            return CarTheme.warning
        }
        return CarTheme.success
    }

    private var connectionColor: Color {
        switch coordinator.connectionPhase {
        case .connected: return CarTheme.success
        case .scanning, .connecting: return CarTheme.warning
        case .failed, .bluetoothUnavailable: return CarTheme.danger
        case .disconnected: return CarTheme.secondaryText
        }
    }

    private var safetyColor: Color {
        if coordinator.telemetry.isEmergencyStopped || coordinator.telemetry.state == .fault {
            return CarTheme.danger
        }
        if coordinator.canDrive {
            return CarTheme.success
        }
        if coordinator.isConnected {
            return CarTheme.warning
        }
        return CarTheme.secondaryText
    }

    private var safetyIcon: String {
        if coordinator.telemetry.isEmergencyStopped { return "exclamationmark.octagon.fill" }
        if coordinator.canDrive { return "checkmark.shield.fill" }
        if coordinator.isConnected { return "lock.fill" }
        return "bolt.horizontal.circle"
    }
}
