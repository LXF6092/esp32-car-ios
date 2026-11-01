import SwiftUI

struct SafetyActionBar: View {
    @ObservedObject var coordinator: ControlCoordinator

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(coordinator.safetyStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Spacer()
                if coordinator.isConnected {
                    Text(coordinator.telemetry.isArmed ? "控制已授权" : "控制未授权")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(CarTheme.secondaryText)
                }
            }

            HStack(spacing: 10) {
                primaryAction
                Button {
                    coordinator.emergencyStop()
                } label: {
                    Label("急停", systemImage: "exclamationmark.octagon.fill")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 62)
                }
                .buttonStyle(.borderedProminent)
                .tint(CarTheme.danger)
                .disabled(!coordinator.isConnected)
                .accessibilityLabel("急停")
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if coordinator.telemetry.isEmergencyStopped {
            Button {
                coordinator.resetEmergencyStop()
            } label: {
                Label("解除急停", systemImage: "lock.open.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 62)
            }
            .buttonStyle(.borderedProminent)
            .tint(CarTheme.warning)
            .disabled(!coordinator.canResetEmergencyStop)
        } else if !coordinator.telemetry.isArmed {
            Button {
                coordinator.arm()
            } label: {
                Label("使能驱动", systemImage: "power")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 62)
            }
            .buttonStyle(.borderedProminent)
            .tint(CarTheme.success)
            .disabled(!coordinator.canArm)
        } else {
            Button {
                coordinator.stop()
            } label: {
                Label("停车", systemImage: "stop.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 62)
            }
            .buttonStyle(.borderedProminent)
            .tint(CarTheme.warning)
        }
    }

    private var statusIcon: String {
        if coordinator.telemetry.isEmergencyStopped { return "exclamationmark.octagon.fill" }
        if coordinator.canDrive { return "checkmark.shield.fill" }
        if coordinator.isConnected { return "lock.fill" }
        return "bolt.horizontal.circle"
    }

    private var statusColor: Color {
        if coordinator.telemetry.isEmergencyStopped || coordinator.telemetry.state == .fault {
            return CarTheme.danger
        }
        if coordinator.canDrive { return CarTheme.success }
        if coordinator.isConnected { return CarTheme.warning }
        return CarTheme.secondaryText
    }
}
