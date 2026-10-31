import Combine
import XCTest
@testable import ESP32CarController

private final class MockBLETransport: BLETransport {
    let phaseSubject = CurrentValueSubject<ConnectionPhase, Never>(.disconnected)
    let telemetrySubject = CurrentValueSubject<CarTelemetry, Never>(.empty)
    let rssiSubject = CurrentValueSubject<Int?, Never>(nil)

    var phasePublisher: AnyPublisher<ConnectionPhase, Never> { phaseSubject.eraseToAnyPublisher() }
    var telemetryPublisher: AnyPublisher<CarTelemetry, Never> { telemetrySubject.eraseToAnyPublisher() }
    var rssiPublisher: AnyPublisher<Int?, Never> { rssiSubject.eraseToAnyPublisher() }
    var onDisconnect: (() -> Void)?
    var sent: [(BLEProtocolV1.Command, Bool)] = []
    var foregroundValues: [Bool] = []

    func setForeground(_ isForeground: Bool) { foregroundValues.append(isForeground) }
    func startScanning() {}
    func disconnect() { onDisconnect?() }

    func send(_ command: BLEProtocolV1.Command, withResponse: Bool) -> Bool {
        sent.append((command, withResponse))
        return true
    }
}

@MainActor
final class ControlCoordinatorTests: XCTestCase {
    func testDriveAndReleaseSendExpectedCommands() async {
        let transport = MockBLETransport()
        let coordinator = ControlCoordinator(transport: transport)
        transport.phaseSubject.send(.connected("test"))
        var telemetry = CarTelemetry.empty
        telemetry.state = .armed
        telemetry.flags = [.hardwareReady, .bleConnected]
        transport.telemetrySubject.send(telemetry)

        coordinator.updateDrive(DriveVector(vx: 20, vy: 60, omega: 0))
        XCTAssertEqual(transport.sent.last?.0.opcode, .drive)
        XCTAssertFalse(transport.sent.last?.1 ?? true)

        coordinator.stop()
        XCTAssertEqual(transport.sent.last?.0.opcode, .stop)
        XCTAssertTrue(transport.sent.last?.1 ?? false)
        XCTAssertEqual(coordinator.activeVector, .zero)
    }

    func testBackgroundStopsAndDisablesReconnect() async {
        let transport = MockBLETransport()
        let coordinator = ControlCoordinator(transport: transport)
        transport.phaseSubject.send(.connected("test"))
        var telemetry = CarTelemetry.empty
        telemetry.state = .armed
        telemetry.flags = [.hardwareReady]
        transport.telemetrySubject.send(telemetry)

        coordinator.updateDrive(DriveVector(vx: 0, vy: 80, omega: 0))
        coordinator.setForeground(false)

        XCTAssertEqual(transport.sent.last?.0.opcode, .stop)
        XCTAssertEqual(transport.foregroundValues.last, false)
        XCTAssertEqual(coordinator.activeVector, .zero)
    }

    func testStaleTelemetryStopsDriveLoop() async {
        let transport = MockBLETransport()
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = ControlCoordinator(transport: transport, now: { now })
        transport.phaseSubject.send(.connected("test"))
        var telemetry = CarTelemetry.empty
        telemetry.state = .armed
        telemetry.flags = [.hardwareReady]
        transport.telemetrySubject.send(telemetry)

        coordinator.updateDrive(DriveVector(vx: 0, vy: 70, omega: 0))
        XCTAssertFalse(coordinator.activeVector.isZero)
        now = now.addingTimeInterval(1)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(coordinator.telemetryIsFresh)
        XCTAssertEqual(coordinator.activeVector, .zero)
        XCTAssertEqual(transport.sent.last?.0.opcode, .stop)
    }

    func testObstacleBlocksForwardButAllowsRetreat() {
        let transport = MockBLETransport()
        let coordinator = ControlCoordinator(transport: transport)
        transport.phaseSubject.send(.connected("test"))
        var telemetry = CarTelemetry.empty
        telemetry.state = .armed
        telemetry.flags = [.hardwareReady, .obstacle]
        transport.telemetrySubject.send(telemetry)

        XCTAssertTrue(coordinator.canDrive)
        XCTAssertFalse(coordinator.canDriveForward)
        coordinator.updateDrive(DriveVector(vx: 0, vy: -70, omega: 0))
        XCTAssertEqual(transport.sent.last?.0.opcode, .drive)
        coordinator.stop()
        coordinator.updateDrive(DriveVector(vx: 0, vy: 70, omega: 0))
        XCTAssertEqual(transport.sent.last?.0.opcode, .stop)
    }

    func testExplicitStopAlwaysSendsSafetyCommand() {
        let transport = MockBLETransport()
        let coordinator = ControlCoordinator(transport: transport)
        transport.phaseSubject.send(.connected("test"))
        coordinator.stop()
        XCTAssertEqual(transport.sent.last?.0.opcode, .stop)
        XCTAssertTrue(transport.sent.last?.1 ?? false)
    }

    func testDisconnectClearsLocalDrive() async {
        let transport = MockBLETransport()
        let coordinator = ControlCoordinator(transport: transport)
        transport.phaseSubject.send(.connected("test"))
        var telemetry = CarTelemetry.empty
        telemetry.state = .armed
        telemetry.flags = [.hardwareReady]
        transport.telemetrySubject.send(telemetry)

        coordinator.updateDrive(DriveVector(vx: 10, vy: 20, omega: 0))
        let cleared = expectation(description: "disconnect clears local drive")
        let cancellable = coordinator.$activeVector
            .dropFirst()
            .sink { vector in
                if vector == .zero { cleared.fulfill() }
            }
        transport.onDisconnect?()
        await fulfillment(of: [cleared], timeout: 1)
        cancellable.cancel()
        XCTAssertEqual(coordinator.activeVector, .zero)
        withExtendedLifetime(cancellable) {}
    }
}
