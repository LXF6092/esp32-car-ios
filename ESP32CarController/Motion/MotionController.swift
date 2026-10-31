import Combine
import CoreMotion
import Foundation

final class MotionController: ObservableObject {
    @Published private(set) var pitchDegrees: Double = 0
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var hasSample = false
    @Published private(set) var lastError: String?

    private let manager = CMMotionManager()
    private var zeroPitch: Double = 0
    private var zeroRoll: Double = 0
    private var lastSampleDate: Date?

    var isFresh: Bool {
        guard let lastSampleDate else { return false }
        return Date().timeIntervalSince(lastSampleDate) < 0.5
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            lastError = "当前设备不支持体感姿态"
            return
        }
        guard !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.05
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.lastError = error.localizedDescription
                return
            }
            guard let attitude = motion?.attitude else { return }
            self.pitchDegrees = attitude.pitch * 180 / .pi
            self.rollDegrees = attitude.roll * 180 / .pi
            self.lastSampleDate = Date()
            self.hasSample = true
            self.lastError = nil
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        hasSample = false
        lastSampleDate = nil
    }

    func calibrate() {
        guard hasSample else { return }
        zeroPitch = pitchDegrees
        zeroRoll = rollDegrees
    }

    func driveVector(deadzone: Double = 4, fullScale: Double = 22) -> DriveVector {
        guard isFresh else { return .zero }
        let pitch = pitchDegrees - zeroPitch
        let roll = Self.normalizedAngle(rollDegrees - zeroRoll)
        let forward = abs(pitch) < deadzone ? 0 : -pitch / fullScale
        let lateral = abs(roll) < deadzone ? 0 : roll / fullScale
        return DriveVector(
            vx: Int(max(-1, min(1, lateral)) * 100),
            vy: Int(max(-1, min(1, forward)) * 100),
            omega: 0
        )
    }

    private static func normalizedAngle(_ degrees: Double) -> Double {
        var value = degrees
        while value > 180 { value -= 360 }
        while value < -180 { value += 360 }
        return value
    }
}
