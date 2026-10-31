import XCTest
@testable import ESP32CarController

final class BLEProtocolTests: XCTestCase {
    func testReferenceCommandVectors() throws {
        XCTAssertEqual(
            BLEProtocolV1.Command(opcode: .arm, sequence: 1).encode().hex,
            "01010100000000000000000e"
        )
        XCTAssertEqual(
            BLEProtocolV1.Command(
                opcode: .drive,
                sequence: 2,
                vx: 12,
                vy: -34,
                omega: 5,
                speed: 35
            ).encode().hex,
            "0102020000000cde052300f3"
        )
        XCTAssertEqual(
            BLEProtocolV1.Command(opcode: .estop, sequence: 3).encode().hex,
            "010403000000000000000033"
        )
    }

    func testDecodeTelemetryReferenceVector() throws {
        let data = try XCTUnwrap(Data(hex: "010101022323111123a7011d0200000040e20100"))
        let telemetry = try BLEProtocolV1.decodeTelemetry(data)
        XCTAssertEqual(telemetry.state, .armed)
        XCTAssertEqual(telemetry.command, .drive)
        XCTAssertEqual(telemetry.reason, .hold)
        XCTAssertEqual(telemetry.frontLeft, 35)
        XCTAssertEqual(telemetry.frontRight, 17)
        XCTAssertEqual(telemetry.rearLeft, 17)
        XCTAssertEqual(telemetry.rearRight, 35)
        XCTAssertEqual(telemetry.distanceMillimetres, 423)
        XCTAssertEqual(telemetry.lastSequence, 2)
        XCTAssertEqual(telemetry.uptimeMilliseconds, 123456)
        XCTAssertTrue(telemetry.flags.contains(.bleConnected))
    }

    func testCorruptCommandIsRejected() throws {
        var data = BLEProtocolV1.Command(opcode: .stop, sequence: 4).encode()
        data[6] ^= 1
        XCTAssertThrowsError(try BLEProtocolV1.decodeCommand(data)) { error in
            XCTAssertEqual(error as? BLEProtocolV1.ProtocolError, .badCRC)
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
