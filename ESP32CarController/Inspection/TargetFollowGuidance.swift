import CoreGraphics
import Foundation

enum TargetFollowGuidance {
    static func driveVector(
        boundingBox: CGRect?,
        confidence: Float,
        targetIsFresh: Bool,
        desiredTargetSize: Double = 0.34,
        observedTargetSize: Double? = nil,
        targetSizeVelocity: Double = 0,
        allowApproach: Bool = true,
        obstacleDistanceCentimetres: Double? = nil,
        previousHorizontalError: Double = 0,
        deltaTime: Double = 0.1
    ) -> DriveVector {
        guard targetIsFresh,
              confidence >= 0.32,
              let box = boundingBox,
              box.width >= 0.04,
              box.height >= 0.04 else {
            return .zero
        }

        if let distance = obstacleDistanceCentimetres, distance <= 18 {
            return .zero
        }

        let horizontalError = max(-1, min(1, (box.midX - 0.5) * 2))
        let dt = max(0.04, min(0.25, deltaTime))
        let derivative = max(-2, min(2, (horizontalError - previousHorizontalError) / dt))
        let rotation = Int(max(-100, min(100, horizontalError * 78 + derivative * 12)))

        let targetSize = observedTargetSize ?? Double(max(box.width, box.height))
        let setpoint = max(0.04, min(0.70, desiredTargetSize))
        let sizeError = setpoint - targetSize
        let isAligned = abs(horizontalError) < 0.42
        let isFarEnough = sizeError > 0.025
        var forward: Double = 0
        if allowApproach && isAligned && isFarEnough {
            let distanceDemand = max(0, min(1, sizeError / max(0.12, setpoint * 0.75)))
            let alignment = max(0.20, 1 - abs(horizontalError) * 1.9)
            let confidenceFactor = max(0.45, min(1, Double(confidence)))
            let closingFactor = max(0.12, min(1, 1 - max(0, targetSizeVelocity) * 4.5))
            forward = (16 + distanceDemand * 44) * alignment * confidenceFactor * closingFactor
        }

        if let distance = obstacleDistanceCentimetres, distance < 48 {
            let sonarFactor = max(0, min(1, (distance - 18) / 30))
            forward *= sonarFactor
        }

        return DriveVector(vx: 0, vy: Int(forward), omega: rotation)
    }
}
