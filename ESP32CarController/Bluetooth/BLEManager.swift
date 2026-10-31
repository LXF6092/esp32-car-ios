import Combine
import CoreBluetooth
import Foundation

protocol BLETransport: AnyObject {
    var phasePublisher: AnyPublisher<ConnectionPhase, Never> { get }
    var telemetryPublisher: AnyPublisher<CarTelemetry, Never> { get }
    var rssiPublisher: AnyPublisher<Int?, Never> { get }
    var onDisconnect: (() -> Void)? { get set }

    func setForeground(_ isForeground: Bool)
    func startScanning()
    func disconnect()
    @discardableResult func send(_ command: BLEProtocolV1.Command, withResponse: Bool) -> Bool
}

final class BLEManager: NSObject, ObservableObject, BLETransport {
    @Published private(set) var phase: ConnectionPhase = .disconnected
    @Published private(set) var telemetry: CarTelemetry = .empty
    @Published private(set) var rssi: Int?
    @Published private(set) var lastError: String?

    var onDisconnect: (() -> Void)?

    var phasePublisher: AnyPublisher<ConnectionPhase, Never> { $phase.eraseToAnyPublisher() }
    var telemetryPublisher: AnyPublisher<CarTelemetry, Never> { $telemetry.eraseToAnyPublisher() }
    var rssiPublisher: AnyPublisher<Int?, Never> { $rssi.eraseToAnyPublisher() }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var telemetryCharacteristic: CBCharacteristic?
    private var latestDriveWrite: Data?
    private var pendingCriticalWrite: BLEProtocolV1.Command?
    private var notificationEnabled = false
    private var shouldReconnect = true
    private var foreground = true

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isReady: Bool {
        peripheral?.state == .connected && commandCharacteristic != nil && telemetryCharacteristic != nil
    }

    func setForeground(_ isForeground: Bool) {
        foreground = isForeground
        shouldReconnect = isForeground
        if isForeground {
            startScanning()
        } else {
            disconnect()
        }
    }

    func startScanning() {
        guard foreground else { return }
        guard central.state == .poweredOn else {
            phase = central.state == .unsupported || central.state == .unauthorized
                ? .bluetoothUnavailable
                : .disconnected
            return
        }
        guard peripheral?.state != .connected && !central.isScanning else { return }
        phase = .scanning
        central.scanForPeripherals(
            withServices: [BLEProtocolV1.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func disconnect() {
        central.stopScan()
        latestDriveWrite = nil
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        } else {
            clearConnection()
        }
    }

    @discardableResult
    func send(_ command: BLEProtocolV1.Command, withResponse: Bool) -> Bool {
        guard let peripheral, let characteristic = commandCharacteristic, peripheral.state == .connected else {
            return false
        }
        let data = command.encode()
        if command.opcode != .drive || withResponse {
            latestDriveWrite = nil
        }
        if withResponse {
            pendingCriticalWrite = command
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            return true
        }
        if pendingCriticalWrite != nil {
            latestDriveWrite = data
            return false
        }
        if peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            return true
        }
        latestDriveWrite = data
        return false
    }

    private func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        phase = .connecting(peripheral.name ?? BLEProtocolV1.advertisedName)
        central.connect(peripheral)
    }

    private func clearConnection() {
        peripheral = nil
        commandCharacteristic = nil
        telemetryCharacteristic = nil
        latestDriveWrite = nil
        pendingCriticalWrite = nil
        notificationEnabled = false
        telemetry = .empty
        rssi = nil
        phase = .disconnected
    }

    private func scheduleReconnect() {
        guard shouldReconnect && foreground else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.startScanning()
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .unsupported, .unauthorized:
            let hadConnection = peripheral != nil
            central.stopScan()
            clearConnection()
            if hadConnection { onDisconnect?() }
            phase = .bluetoothUnavailable
        default:
            let hadConnection = peripheral != nil
            central.stopScan()
            clearConnection()
            if hadConnection { onDisconnect?() }
            phase = .disconnected
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard advertisedName == nil || advertisedName == BLEProtocolV1.advertisedName else { return }
        rssi = RSSI.intValue
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lastError = nil
        peripheral.discoverServices([BLEProtocolV1.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription ?? "连接失败"
        let message = lastError ?? "连接失败"
        clearConnection()
        phase = .failed(message)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription
        clearConnection()
        onDisconnect?()
        scheduleReconnect()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEProtocolV1.serviceUUID }) else {
            lastError = "未找到控制服务"
            disconnect()
            return
        }
        peripheral.discoverCharacteristics(
            [BLEProtocolV1.commandUUID, BLEProtocolV1.telemetryUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BLEProtocolV1.commandUUID {
                commandCharacteristic = characteristic
            } else if characteristic.uuid == BLEProtocolV1.telemetryUUID {
                telemetryCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        guard commandCharacteristic != nil, telemetryCharacteristic != nil else {
            lastError = "控制特征不完整"
            disconnect()
            return
        }
        peripheral.readRSSI()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == BLEProtocolV1.telemetryUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            lastError = error?.localizedDescription ?? "无法订阅遥测通知"
            disconnect()
            return
        }
        notificationEnabled = true
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        guard characteristic.uuid == BLEProtocolV1.telemetryUUID, let value = characteristic.value else { return }
        do {
            telemetry = try BLEProtocolV1.decodeTelemetry(value)
            if notificationEnabled {
                phase = .connected(peripheral.name ?? BLEProtocolV1.advertisedName)
            }
            lastError = nil
        } catch {
            lastError = "遥测数据无效"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEProtocolV1.commandUUID else { return }
        pendingCriticalWrite = nil
        if let error {
            lastError = error.localizedDescription
            latestDriveWrite = nil
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if let data = latestDriveWrite, peripheral.canSendWriteWithoutResponse {
            latestDriveWrite = nil
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard pendingCriticalWrite == nil,
              let data = latestDriveWrite,
              let characteristic = commandCharacteristic else { return }
        latestDriveWrite = nil
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            rssi = RSSI.intValue
        }
    }
}
