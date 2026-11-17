import CoreBluetooth
import Foundation

enum BLEProtocolV1 {
    static let version: UInt8 = 1
    static let commandFrameSize = 12
    static let telemetryFrameSize = 20
    static let encoderTelemetryFrameSize = 20

    static let serviceUUID = CBUUID(string: "8E7A0001-9C6B-4A6B-8F31-4C4152434152")
    static let commandUUID = CBUUID(string: "8E7A0002-9C6B-4A6B-8F31-4C4152434152")
    static let telemetryUUID = CBUUID(string: "8E7A0003-9C6B-4A6B-8F31-4C4152434152")
    static let encoderTelemetryUUID = CBUUID(string: "8E7A0004-9C6B-4A6B-8F31-4C4152434152")
    static let advertisedName = "ESP32-CAR-BLE"

    enum Opcode: UInt8 {
        case arm = 1
        case drive = 2
        case stop = 3
        case estop = 4
        case reset = 5
    }

    struct Command: Equatable {
        var opcode: Opcode
        var sequence: UInt32
        var vx: Int8 = 0
        var vy: Int8 = 0
        var omega: Int8 = 0
        var speed: UInt8 = 0
        var flags: UInt8 = 0

        func encode() -> Data {
            precondition((-100...100).contains(Int(vx)))
            precondition((-100...100).contains(Int(vy)))
            precondition((-100...100).contains(Int(omega)))
            precondition(speed <= 60)
            precondition(sequence <= UInt32(Int32.max))

            var bytes = Data(capacity: commandFrameSize)
            bytes.append(version)
            bytes.append(opcode.rawValue)
            bytes.appendLittleEndian(sequence)
            bytes.append(UInt8(bitPattern: vx))
            bytes.append(UInt8(bitPattern: vy))
            bytes.append(UInt8(bitPattern: omega))
            bytes.append(speed)
            bytes.append(flags)
            bytes.append(crc8(bytes))
            return bytes
        }
    }

    static func decodeCommand(_ data: Data) throws -> Command {
        guard data.count == commandFrameSize else { throw ProtocolError.badLength }
        let bytes = [UInt8](data)
        guard bytes[0] == version else { throw ProtocolError.badVersion }
        guard crc8(bytes.prefix(commandFrameSize - 1)) == bytes[commandFrameSize - 1] else {
            throw ProtocolError.badCRC
        }
        guard let opcode = Opcode(rawValue: bytes[1]) else { throw ProtocolError.badOpcode }
        let command = Command(
            opcode: opcode,
            sequence: bytes.uint32LittleEndian(at: 2),
            vx: Int8(bitPattern: bytes[6]),
            vy: Int8(bitPattern: bytes[7]),
            omega: Int8(bitPattern: bytes[8]),
            speed: bytes[9],
            flags: bytes[10]
        )
        guard command.sequence <= UInt32(Int32.max),
              (-100...100).contains(Int(command.vx)),
              (-100...100).contains(Int(command.vy)),
              (-100...100).contains(Int(command.omega)),
              command.speed <= 60 else {
            throw ProtocolError.outOfRange
        }
        return command
    }

    static func decodeTelemetry(_ data: Data) throws -> CarTelemetry {
        guard data.count == telemetryFrameSize else { throw ProtocolError.badLength }
        let bytes = [UInt8](data)
        guard bytes[0] == version else { throw ProtocolError.badVersion }
        let rawDistance = bytes.uint16LittleEndian(at: 9)
        return CarTelemetry(
            state: SafetyState(rawValue: bytes[1]) ?? .unknown,
            command: CarCommandCode(rawValue: bytes[2]) ?? .unknown,
            reason: ReasonCode(rawValue: bytes[3]) ?? .unknown,
            speed: bytes[4],
            frontLeft: Int8(bitPattern: bytes[5]),
            frontRight: Int8(bitPattern: bytes[6]),
            rearLeft: Int8(bitPattern: bytes[7]),
            rearRight: Int8(bitPattern: bytes[8]),
            distanceMillimetres: rawDistance == .max ? nil : rawDistance,
            flags: TelemetryFlags(rawValue: bytes[11]),
            lastSequence: bytes.uint32LittleEndian(at: 12),
            uptimeMilliseconds: bytes.uint32LittleEndian(at: 16)
        )
    }

    static func decodeEncoderTelemetry(_ data: Data) throws -> EncoderTelemetry {
        guard data.count == encoderTelemetryFrameSize else { throw ProtocolError.badLength }
        let bytes = [UInt8](data)
        guard bytes[0] == version else { throw ProtocolError.badVersion }
        guard crc8(bytes.prefix(encoderTelemetryFrameSize - 1)) == bytes[encoderTelemetryFrameSize - 1] else {
            throw ProtocolError.badCRC
        }
        let flags = bytes[1]
        return EncoderTelemetry(
            ready: flags & 0x01 != 0,
            stalled: flags & 0x02 != 0,
            frontLeftRPM: Double(bytes.int16LittleEndian(at: 2)) / 10,
            frontRightRPM: Double(bytes.int16LittleEndian(at: 4)) / 10,
            rearLeftRPM: Double(bytes.int16LittleEndian(at: 6)) / 10,
            rearRightRPM: Double(bytes.int16LittleEndian(at: 8)) / 10,
            frontLeftTicks: bytes.uint16LittleEndian(at: 10),
            frontRightTicks: bytes.uint16LittleEndian(at: 12),
            rearLeftTicks: bytes.uint16LittleEndian(at: 14),
            rearRightTicks: bytes.uint16LittleEndian(at: 16),
            samplePeriodMilliseconds: Int(bytes[18]) * 10
        )
    }

    static func crc8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var value: UInt8 = 0
        for byte in bytes {
            value ^= byte
            for _ in 0..<8 {
                value = value & 0x80 == 0 ? value &<< 1 : (value &<< 1) ^ 0x07
            }
        }
        return value
    }

    enum ProtocolError: Error, Equatable {
        case badLength
        case badVersion
        case badCRC
        case badOpcode
        case outOfRange
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private extension Array where Element == UInt8 {
    func uint16LittleEndian(at index: Int) -> UInt16 {
        UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    func int16LittleEndian(at index: Int) -> Int16 {
        Int16(bitPattern: uint16LittleEndian(at: index))
    }

    func uint32LittleEndian(at index: Int) -> UInt32 {
        UInt32(self[index]) |
            UInt32(self[index + 1]) << 8 |
            UInt32(self[index + 2]) << 16 |
            UInt32(self[index + 3]) << 24
    }
}
