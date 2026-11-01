import Combine
import Foundation

@MainActor
final class ControlCoordinator: ObservableObject {
    @Published private(set) var connectionPhase: ConnectionPhase = .disconnected
    @Published private(set) var telemetry: CarTelemetry = .empty
    @Published private(set) var rssi: Int?
    @Published private(set) var statusMessage = "正在准备蓝牙"
    @Published var mode: ControlMode = .joystick
    @Published var maxSpeed: UInt8 = 35
    @Published private(set) var activeVector: DriveVector = .zero

    private let transport: BLETransport
    private let now: () -> Date

    private var sequence: UInt32 = 0
    private var driveTask: Task<Void, Never>?
    private var lastTelemetryAt: Date?
    private var cancellables = Set<AnyCancellable>()

    init(transport: BLETransport = BLEManager(), now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.now = now
        transport.phasePublisher
            .sink { [weak self] phase in
                self?.connectionPhase = phase
                self?.statusMessage = Self.connectionMessage(phase)
            }
            .store(in: &cancellables)
        transport.telemetryPublisher
            .sink { [weak self] telemetry in
                self?.telemetry = telemetry
                self?.lastTelemetryAt = self?.now()
            }
            .store(in: &cancellables)
        transport.rssiPublisher
            .assign(to: &$rssi)
        transport.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.lastTelemetryAt = nil
                self?.clearLocalDrive()
                self?.statusMessage = "连接已断开，驱动已撤销"
            }
        }
    }

    var isConnected: Bool {
        if case .connected = connectionPhase { return true }
        return false
    }

    var canArm: Bool {
        isConnected
            && telemetryIsFresh
            && telemetry.state == .disarmed
            && telemetry.flags.contains(.hardwareReady)
    }

    var canResetEmergencyStop: Bool {
        isConnected && telemetryIsFresh && telemetry.state == .estop
    }

    var safetyStatusText: String {
        guard isConnected else { return "未连接：请先搜索并连接小车" }
        if telemetry.isEmergencyStopped { return "急停锁定：请解除急停" }
        if telemetry.state == .fault { return "硬件故障：禁止驾驶" }
        guard telemetryIsFresh else { return "等待车辆遥测" }
        guard telemetry.flags.contains(.hardwareReady) else { return "硬件未就绪" }
        guard telemetry.isArmed else { return "未使能：点击使能驱动" }
        if telemetry.flags.contains(.obstacle) { return "前方有障碍：仅允许后退或横移" }
        return "可驾驶"
    }

    var telemetryIsFresh: Bool {
        guard let lastTelemetryAt else { return false }
        return now().timeIntervalSince(lastTelemetryAt) < 0.75
    }

    var canDrive: Bool {
        isConnected && telemetryIsFresh && telemetry.state == .armed
    }

    var canDriveForward: Bool {
        canDrive && !telemetry.flags.contains(.obstacle)
    }

    func start() {
        transport.setForeground(true)
    }

    func setForeground(_ foreground: Bool) {
        if foreground {
            transport.setForeground(true)
        } else {
            stopDriving(sendCommand: true, force: true)
            transport.setForeground(false)
        }
    }

    func arm() {
        guard canArm else { return }
        clearLocalDrive()
        send(.arm, withResponse: true)
    }

    func resetEmergencyStop() {
        guard canResetEmergencyStop else { return }
        clearLocalDrive()
        send(.reset, withResponse: true)
    }

    func emergencyStop() {
        clearLocalDrive()
        send(.estop, withResponse: true)
    }

    func stop() {
        stopDriving(sendCommand: true, force: true)
    }

    func updateDrive(_ vector: DriveVector) {
        let nextVector = Self.clamped(vector)
        guard !nextVector.isZero else {
            stopDriving(sendCommand: true)
            return
        }
        guard canDrive else {
            stopDriving(sendCommand: true, force: isConnected)
            return
        }
        if telemetry.flags.contains(.obstacle) && nextVector.vy > 0 {
            statusMessage = "前方有障碍，仅允许后退或横移"
            stopDriving(sendCommand: true, force: true)
            return
        }
        activeVector = nextVector
        let startsLoop = driveTask == nil
        if startsLoop {
            sendDriveTick()
            ensureDriveLoop()
        }
    }

    func driveForward() { updateDrive(DriveVector(vx: 0, vy: 100, omega: 0)) }
    func driveBackward() { updateDrive(DriveVector(vx: 0, vy: -100, omega: 0)) }
    func rotateLeft() { updateDrive(DriveVector(vx: 0, vy: 0, omega: -100)) }
    func rotateRight() { updateDrive(DriveVector(vx: 0, vy: 0, omega: 100)) }
    func strafeLeft() { updateDrive(DriveVector(vx: -100, vy: 0, omega: 0)) }
    func strafeRight() { updateDrive(DriveVector(vx: 100, vy: 0, omega: 0)) }

    private func ensureDriveLoop() {
        guard driveTask == nil else { return }
        driveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.activeVector.isZero {
                    self.clearLocalDrive()
                    return
                }
                if !self.canDrive || (self.telemetry.flags.contains(.obstacle) && self.activeVector.vy > 0) {
                    self.stopDriving(sendCommand: true, force: self.isConnected)
                    return
                }
                self.sendDriveTick()
            }
        }
    }

    private func sendDriveTick() {
        let vector = activeVector
        send(
            .drive,
            vx: vector.vx,
            vy: vector.vy,
            omega: vector.omega,
            speed: maxSpeed,
            withResponse: false
        )
    }

    private func stopDriving(sendCommand: Bool, force: Bool = false) {
        let wasActive = !activeVector.isZero || driveTask != nil
        clearLocalDrive()
        if sendCommand && isConnected && (force || wasActive) {
            send(.stop, withResponse: true)
        }
    }

    private func clearLocalDrive() {
        driveTask?.cancel()
        driveTask = nil
        activeVector = .zero
    }

    private func send(
        _ opcode: BLEProtocolV1.Opcode,
        vx: Int = 0,
        vy: Int = 0,
        omega: Int = 0,
        speed: UInt8 = 0,
        withResponse: Bool
    ) {
        sequence = sequence == UInt32(Int32.max) ? 1 : sequence + 1
        let command = BLEProtocolV1.Command(
            opcode: opcode,
            sequence: sequence,
            vx: Int8(clamping: vx),
            vy: Int8(clamping: vy),
            omega: Int8(clamping: omega),
            speed: min(speed, 60)
        )
        if !transport.send(command, withResponse: withResponse) && withResponse {
            statusMessage = "指令未发送：蓝牙未就绪"
        }
    }

    private static func clamped(_ vector: DriveVector) -> DriveVector {
        DriveVector(
            vx: min(100, max(-100, vector.vx)),
            vy: min(100, max(-100, vector.vy)),
            omega: min(100, max(-100, vector.omega))
        )
    }

    private static func connectionMessage(_ phase: ConnectionPhase) -> String {
        switch phase {
        case .bluetoothUnavailable: return "蓝牙不可用或权限未开启"
        case .disconnected: return "未连接"
        case .scanning: return "正在搜索 ESP32-CAR-BLE"
        case .connecting(let name): return "正在连接 \(name)"
        case .connected(let name): return "已连接 \(name)"
        case .failed(let message): return message
        }
    }
}
