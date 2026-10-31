import SwiftUI

struct TelemetryPanel: View {
    let telemetry: CarTelemetry
    let rssi: Int?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("车辆遥测")
                        .font(.headline)
                    Text(distanceText)
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(telemetry.flags.contains(.obstacle) ? CarTheme.danger : Color.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    StatusBadge(text: stateText, color: stateColor)
                    Text(rssi.map { "RSSI \($0) dBm" } ?? "RSSI --")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CarTheme.secondaryText)
                }
            }

            HStack(spacing: 10) {
                WheelTile(name: "左前", value: telemetry.frontLeft)
                WheelTile(name: "右前", value: telemetry.frontRight)
                WheelTile(name: "左后", value: telemetry.rearLeft)
                WheelTile(name: "右后", value: telemetry.rearRight)
            }

            HStack {
                Label(reasonText, systemImage: telemetry.flags.contains(.obstacle) ? "exclamationmark.triangle.fill" : "shield.checkered")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(telemetry.flags.contains(.obstacle) ? CarTheme.warning : CarTheme.secondaryText)
                Spacer()
                Text("序号 \(telemetry.lastSequence)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CarTheme.secondaryText)
            }
        }
        .carCard()
    }

    private var distanceText: String {
        if let distance = telemetry.distanceCentimetres {
            return String(format: "%.1f cm", distance)
        }
        return "测距未连接"
    }

    private var stateText: String {
        switch telemetry.state {
        case .disarmed: return "未使能"
        case .armed: return "已使能"
        case .estop: return "急停锁定"
        case .fault: return "硬件故障"
        case .unknown: return "状态未知"
        }
    }

    private var stateColor: Color {
        switch telemetry.state {
        case .armed: return CarTheme.success
        case .estop, .fault: return CarTheme.danger
        case .disarmed, .unknown: return CarTheme.warning
        }
    }

    private var reasonText: String {
        switch telemetry.reason {
        case .disarmed: return "驱动未使能"
        case .armed: return "等待控制"
        case .hold: return "持续控制中"
        case .stop: return "已停车"
        case .timeout: return "失联超时，已停车"
        case .estop: return "急停已锁定"
        case .aeb: return "前方障碍，已刹停"
        case .fault: return "硬件故障"
        case .oledError: return "OLED 显示异常"
        case .bleDisconnect: return "蓝牙断开，已停车"
        case .unknown: return "状态待确认"
        }
    }
}

private struct WheelTile: View {
    let name: String
    let value: Int8

    var body: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.caption2)
                .foregroundStyle(CarTheme.secondaryText)
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(value == 0 ? Color.white : (value > 0 ? CarTheme.primary : CarTheme.warning))
            GeometryReader { proxy in
                ZStack(alignment: value >= 0 ? .bottom : .top) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(value >= 0 ? CarTheme.primary : CarTheme.warning)
                        .frame(height: max(2, proxy.size.height * CGFloat(abs(Int(value))) / 60))
                }
            }
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(CarTheme.raised, in: RoundedRectangle(cornerRadius: 12))
    }
}
