import SwiftUI

struct JoystickView: View {
    @ObservedObject var coordinator: ControlCoordinator
    @State private var knobOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("摇杆驾驶", systemImage: "gamecontroller.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(coordinator.canDrive ? "可驾驶" : "已锁定")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(coordinator.canDrive ? CarTheme.success : CarTheme.warning)
            }

            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                let radius = size * 0.38
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

                ZStack {
                    Circle()
                        .fill(CarTheme.raised)
                        .overlay { Circle().stroke(CarTheme.border, lineWidth: 2) }
                    Circle()
                        .stroke(CarTheme.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 6]))
                        .padding(size * 0.22)
                    Path { path in
                        path.move(to: CGPoint(x: center.x, y: 12))
                        path.addLine(to: CGPoint(x: center.x, y: proxy.size.height - 12))
                        path.move(to: CGPoint(x: 12, y: center.y))
                        path.addLine(to: CGPoint(x: proxy.size.width - 12, y: center.y))
                    }
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    Circle()
                        .fill(coordinator.canDrive ? CarTheme.primary : CarTheme.disabledText)
                        .frame(width: size * 0.25, height: size * 0.25)
                        .shadow(color: CarTheme.primary.opacity(coordinator.canDrive ? 0.35 : 0), radius: 14)
                        .offset(knobOffset)
                }
                .frame(width: size, height: size)
                .position(center)
                .contentShape(Circle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("驾驶摇杆")
                .accessibilityValue(coordinator.safetyStatusText)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard coordinator.canDrive else { return }
                            let dx = value.location.x - center.x
                            let dy = value.location.y - center.y
                            let distance = max(1, hypot(dx, dy))
                            let scale = min(1, radius / distance)
                            let limitedX = dx * scale
                            let limitedY = dy * scale
                            knobOffset = CGSize(width: limitedX, height: limitedY)
                            coordinator.updateDrive(DriveVector(
                                vx: Int(limitedX / radius * 100),
                                vy: Int(-limitedY / radius * 100),
                                omega: 0
                            ))
                        }
                        .onEnded { _ in
                            knobOffset = .zero
                            coordinator.stop()
                        }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: 310)

            if !coordinator.canDrive {
                Label(coordinator.safetyStatusText, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(CarTheme.warning)
                    .multilineTextAlignment(.center)
            } else {
                Text("拖动控制方向，松手立即停车")
                    .font(.caption)
                    .foregroundStyle(CarTheme.secondaryText)
            }

            HStack(spacing: 12) {
                HoldControlButton(
                    title: "左自旋",
                    systemImage: "arrow.counterclockwise",
                    disabled: !coordinator.canDrive,
                    onPress: coordinator.rotateLeft,
                    onRelease: coordinator.stop
                )
                HoldControlButton(
                    title: "右自旋",
                    systemImage: "arrow.clockwise",
                    disabled: !coordinator.canDrive,
                    onPress: coordinator.rotateRight,
                    onRelease: coordinator.stop
                )
            }
        }
        .carCard()
    }
}
