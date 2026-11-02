import CoreGraphics
import Foundation

enum TargetFollowGuidance {
    static func driveVector(
        boundingBox: CGRect?,
        confidence: Float,
        targetIsFresh: Bool
    ) -> DriveVector {
        guard targetIsFresh,
              confidence >= 0.32,
              let box = boundingBox,
              box.width >= 0.04,
              box.height >= 0.04 else {
            return .zero
        }

        let horizontalError = max(-1, min(1, (box.midX - 0.5) * 2))
        let targetSize = max(box.width, box.height)
        let rotation = Int(horizontalError * 92)

        // Turn toward the target before approaching it. Never reverse automatically.
        let isAligned = abs(horizontalError) < 0.42
        let isFarEnough = targetSize < 0.34
        let forward: Int
        if isAligned && isFarEnough {
            let distanceDemand = max(0, min(1, (0.34 - targetSize) / 0.26))
            let alignment = max(0.25, 1 - abs(horizontalError) * 1.8)
            forward = Int((18 + distanceDemand * 42) * alignment)
        } else {
            forward = 0
        }

        return DriveVector(vx: 0, vy: forward, omega: rotation)
    }
}
