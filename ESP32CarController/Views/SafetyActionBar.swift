import SwiftUI

struct SafetyActionBar: View {
    @ObservedObject var coordinator: ControlCoordinator

    var body: some View {
        HStack(spacing: 10) {
            if coordinator.telemetry.isEmergencyStopped {
                Button {
                    coordinator.resetEmergencyStop()
                } label: {
                    Label("解除急停", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(CarTheme.warning)
            } else if !coordinator.telemetry.isArmed {
                Button {
                    coordinator.arm()
                } label: {
                    Label("使能驱动", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(CarTheme.success)
                .disabled(!coordinator.isConnected || !coordinator.telemetry.flags.contains(.hardwareReady))
            } else {
                Button {
                    coordinator.stop()
                } label: {
                    Label("停车", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(CarTheme.warning)
            }

            Button {
                coordinator.emergencyStop()
            } label: {
                Label("急停", systemImage: "exclamationmark.octagon.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(CarTheme.danger)
            .disabled(!coordinator.isConnected)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}
