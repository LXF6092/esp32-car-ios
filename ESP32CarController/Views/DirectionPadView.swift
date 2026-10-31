import SwiftUI

struct DirectionPadView: View {
    @ObservedObject var coordinator: ControlCoordinator

    var body: some View {
        VStack(spacing: 12) {
            HoldControlButton(
                title: "前进",
                systemImage: "arrow.up",
                disabled: !coordinator.canDriveForward,
                onPress: coordinator.driveForward,
                onRelease: coordinator.stop
            )
            HStack(spacing: 12) {
                HoldControlButton(
                    title: "左转",
                    systemImage: "arrow.turn.up.left",
                    disabled: !coordinator.canDrive,
                    onPress: coordinator.rotateLeft,
                    onRelease: coordinator.stop
                )
                HoldControlButton(
                    title: "停车",
                    systemImage: "stop.fill",
                    tint: CarTheme.warning,
                    disabled: !coordinator.isConnected,
                    onPress: coordinator.stop,
                    onRelease: {}
                )
                HoldControlButton(
                    title: "右转",
                    systemImage: "arrow.turn.up.right",
                    disabled: !coordinator.canDrive,
                    onPress: coordinator.rotateRight,
                    onRelease: coordinator.stop
                )
            }
            HoldControlButton(
                title: "后退",
                systemImage: "arrow.down",
                disabled: !coordinator.canDrive,
                onPress: coordinator.driveBackward,
                onRelease: coordinator.stop
            )
            HStack(spacing: 12) {
                HoldControlButton(
                    title: "左横移",
                    systemImage: "arrow.left.to.line",
                    disabled: !coordinator.canDrive,
                    onPress: coordinator.strafeLeft,
                    onRelease: coordinator.stop
                )
                HoldControlButton(
                    title: "右横移",
                    systemImage: "arrow.right.to.line",
                    disabled: !coordinator.canDrive,
                    onPress: coordinator.strafeRight,
                    onRelease: coordinator.stop
                )
            }
        }
        .carCard()
    }
}
