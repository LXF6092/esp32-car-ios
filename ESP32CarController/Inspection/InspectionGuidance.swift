import Foundation

enum InspectionMarkerAction: Equatable {
    case stop
    case checkpoint(String)
    case ignored
}

enum LinePatrolPhase: String, Equatable {
    case acquiring = "寻找线路"
    case tracking = "稳定跟线"
    case cornering = "弯道减速"
    case predicting = "短暂丢线预测"
    case recovering = "旋转搜索线路"
    case obstacle = "障碍停车"
    case failed = "巡检暂停：未找到线路"
}

struct LinePatrolOutput: Equatable {
    var vector: DriveVector
    var phase: LinePatrolPhase
}

struct LinePatrolController {
    private(set) var phase: LinePatrolPhase = .acquiring
    private var stableFrames = 0
    private var lineLostAt: Date?
    private var lastSeenOffset = 0.0
    private var lastVector = DriveVector.zero

    mutating func reset() {
        phase = .acquiring
        stableFrames = 0
        lineLostAt = nil
        lastSeenOffset = 0
        lastVector = .zero
    }

    mutating func update(
        lineOffset: Double?,
        headingError: Double,
        curvature: Double,
        confidence: Double,
        frameIsFresh: Bool,
        obstacleDistanceCentimetres: Double?,
        obstacleFlag: Bool,
        yawRateDegreesPerSecond: Double = 0,
        now: Date = Date()
    ) -> LinePatrolOutput {
        if obstacleFlag || (obstacleDistanceCentimetres.map { $0 <= 18 } ?? false) {
            phase = .obstacle
            lastVector = .zero
            return LinePatrolOutput(vector: .zero, phase: phase)
        }

        let hasLine = frameIsFresh && lineOffset != nil && confidence >= 0.16
        if hasLine, let lineOffset {
            lineLostAt = nil
            lastSeenOffset = lineOffset
            stableFrames = min(10, stableFrames + 1)
            guard stableFrames >= 3 else {
                phase = .acquiring
                lastVector = .zero
                return LinePatrolOutput(vector: .zero, phase: phase)
            }

            let raw = InspectionGuidance.driveVector(
                lineOffset: lineOffset,
                headingError: headingError,
                curvature: curvature,
                confidence: confidence,
                frameIsFresh: true,
                obstacleDistanceCentimetres: obstacleDistanceCentimetres,
                yawRateDegreesPerSecond: yawRateDegreesPerSecond
            )
            let bend = max(abs(headingError), abs(curvature) * 1.25)
            phase = bend >= 0.30 ? .cornering : .tracking
            let smoothed = limitedChange(from: lastVector, to: raw)
            lastVector = smoothed
            return LinePatrolOutput(vector: smoothed, phase: phase)
        }

        stableFrames = 0
        if lineLostAt == nil { lineLostAt = now }
        let missingFor = now.timeIntervalSince(lineLostAt ?? now)
        let direction = lastSeenOffset >= 0 ? 1 : -1

        if frameIsFresh && missingFor < 0.30 && !lastVector.isZero {
            phase = .predicting
            let prediction = DriveVector(
                vx: 0,
                vy: min(12, max(7, lastVector.vy / 3)),
                omega: direction * min(30, max(16, abs(lastVector.omega)))
            )
            lastVector = prediction
            return LinePatrolOutput(vector: prediction, phase: phase)
        }

        if frameIsFresh && missingFor < 3.0 {
            phase = .recovering
            let strength = missingFor < 1.2 ? 24 : min(48, 30 + Int((missingFor - 1.2) * 10))
            let sweep = missingFor < 1.8 ? direction : (Int(missingFor * 2) % 2 == 0 ? direction : -direction)
            let search = DriveVector(vx: 0, vy: 0, omega: sweep * strength)
            lastVector = search
            return LinePatrolOutput(vector: search, phase: phase)
        }

        phase = frameIsFresh ? .failed : .acquiring
        lastVector = .zero
        return LinePatrolOutput(vector: .zero, phase: phase)
    }

    private func limitedChange(from previous: DriveVector, to target: DriveVector) -> DriveVector {
        guard !previous.isZero else {
            return DriveVector(
                vx: target.vx,
                vy: min(target.vy, 14),
                omega: max(-22, min(22, target.omega))
            )
        }
        return DriveVector(
            vx: limit(previous.vx, toward: target.vx, by: 10),
            vy: limit(previous.vy, toward: target.vy, by: 8),
            omega: limit(previous.omega, toward: target.omega, by: 16)
        )
    }

    private func limit(_ value: Int, toward target: Int, by step: Int) -> Int {
        max(value - step, min(value + step, target))
    }
}

enum InspectionGuidance {
    static func parseMarker(_ source: String) -> InspectionMarkerAction {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = text.uppercased()
        if upper == "ESP32CAR:STOP" || upper == "ESP32CAR:PAUSE" {
            return .stop
        }
        let prefix = "ESP32CAR:CHECKPOINT:"
        guard upper.hasPrefix(prefix) else { return .ignored }
        let name = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { return .ignored }
        return .checkpoint(name)
    }

    static func driveVector(
        lineOffset: Double?,
        headingError: Double = 0,
        curvature: Double = 0,
        confidence: Double,
        frameIsFresh: Bool,
        obstacleDistanceCentimetres: Double? = nil,
        yawRateDegreesPerSecond: Double = 0
    ) -> DriveVector {
        guard frameIsFresh, let lineOffset, confidence >= 0.16 else { return .zero }
        let offset = clamp(lineOffset)
        let heading = clamp(headingError)
        let bend = clamp(curvature)
        let quality = max(0, min(1, confidence))
        let steering = offset * 49 + heading * 34 + bend * 22
        let rotation = Int(max(-100, min(100, steering)))
        let curveDemand = min(1, abs(heading) * 0.75 + abs(bend) * 0.95 + abs(offset) * 0.30)
        let gyroDemand = min(1, abs(yawRateDegreesPerSecond) / 95)
        var forward = (22 + quality * 40) * (1 - curveDemand * 0.68) * (1 - gyroDemand * 0.28)

        if let distance = obstacleDistanceCentimetres {
            if distance < 30 {
                forward = min(forward, 16)
            } else if distance < 50 {
                forward = min(forward, 28)
            } else if distance < 80 {
                forward = min(forward, 40)
            }
        }

        return DriveVector(vx: 0, vy: Int(max(10, min(65, forward))), omega: rotation)
    }

    private static func clamp(_ value: Double) -> Double {
        max(-1, min(1, value))
    }
}
