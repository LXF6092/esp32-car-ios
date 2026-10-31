import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var coordinator: ControlCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    connectionHeader
                    TelemetryPanel(telemetry: coordinator.telemetry, rssi: coordinator.rssi)
                    speedControl
                    modePicker
                    controlPanel
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 110)
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
        HStack(spacing: 12) {
            Circle()
                .fill(connectionColor)
                .frame(width: 12, height: 12)
                .shadow(color: connectionColor.opacity(0.5), radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.statusMessage)
                    .font(.subheadline.weight(.semibold))
                Text("BLE 主控制 · 重连后需重新使能")
                    .font(.caption)
                    .foregroundStyle(CarTheme.secondaryText)
            }
            Spacer()
            if !coordinator.isConnected {
                Button("重新搜索") { coordinator.start() }
                    .buttonStyle(.bordered)
            }
        }
        .carCard()
    }

    private var speedControl: some View {
        VStack(spacing: 10) {
            HStack {
                Text("速度上限")
                    .font(.headline)
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

    private var modePicker: some View {
        Picker("控制模式", selection: $coordinator.mode) {
            ForEach(ControlMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
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
        }
    }

    private var connectionColor: Color {
        switch coordinator.connectionPhase {
        case .connected: return CarTheme.success
        case .scanning, .connecting: return CarTheme.warning
        case .failed, .bluetoothUnavailable: return CarTheme.danger
        case .disconnected: return CarTheme.secondaryText
        }
    }
}
