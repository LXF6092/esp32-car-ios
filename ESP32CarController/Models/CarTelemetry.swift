import Foundation

struct DriveVector: Equatable {
    var vx: Int = 0
    var vy: Int = 0
    var omega: Int = 0

    static let zero = DriveVector()

    var isZero: Bool {
        vx == 0 && vy == 0 && omega == 0
    }
}
enum ConnectionPhase: Equatable {
    case bluetoothUnavailable
    case disconnected
    case scanning
    case connecting(String)
    case connected(String)
    case failed(String)
}

enum SafetyState: UInt8, Equatable {
    case disarmed = 0
    case armed = 1
    case estop = 2
    case fault = 3
    case unknown = 255
}

enum CarCommandCode: UInt8, Equatable {
    case stop = 0
    case drive = 1
    case forward = 2
    case backward = 3
    case left = 4
    case right = 5
    case strafeLeft = 6
    case strafeRight = 7
    case unknown = 255
}

enum ReasonCode: UInt8, Equatable {
    case disarmed = 0
    case armed = 1
    case hold = 2
    case stop = 3
    case timeout = 4
    case estop = 5
    case aeb = 6
    case fault = 7
    case oledError = 8
    case bleDisconnect = 9
    case unknown = 255
}

struct TelemetryFlags: OptionSet, Equatable {
    let rawValue: UInt8

    static let sonarValid = TelemetryFlags(rawValue: 1 << 0)
    static let obstacle = TelemetryFlags(rawValue: 1 << 1)
    static let hardwareReady = TelemetryFlags(rawValue: 1 << 2)
    static let bleConnected = TelemetryFlags(rawValue: 1 << 3)
    static let remoteActive = TelemetryFlags(rawValue: 1 << 4)
}

struct CarTelemetry: Equatable {
    var state: SafetyState
    var command: CarCommandCode
    var reason: ReasonCode
    var speed: UInt8
    var frontLeft: Int8
    var frontRight: Int8
    var rearLeft: Int8
    var rearRight: Int8
    var distanceMillimetres: UInt16?
    var flags: TelemetryFlags
    var lastSequence: UInt32
    var uptimeMilliseconds: UInt32

    static let empty = CarTelemetry(
        state: .disarmed,
        command: .stop,
        reason: .disarmed,
        speed: 0,
        frontLeft: 0,
        frontRight: 0,
        rearLeft: 0,
        rearRight: 0,
        distanceMillimetres: nil,
        flags: [],
        lastSequence: 0,
        uptimeMilliseconds: 0
    )

    var distanceCentimetres: Double? {
        distanceMillimetres.map { Double($0) / 10.0 }
    }

    var isArmed: Bool { state == .armed }
    var isEmergencyStopped: Bool { state == .estop }
}

enum ControlMode: String, CaseIterable, Identifiable {
    case joystick = "摇杆"
    case directional = "按键"
    case motion = "体感"
    case voice = "语音"
    case inspection = "巡检"

    var id: String { rawValue }
}
