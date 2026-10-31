import XCTest
@testable import ESP32CarController

final class VoiceCommandParserTests: XCTestCase {
    func testEmergencyStopHasHighestPriority() {
        XCTAssertEqual(VoiceCommandParser.parse("请立即急停"), .emergencyStop)
    }

    func testNegationNeverMoves() {
        XCTAssertEqual(VoiceCommandParser.parse("不要前进"), .stop)
        XCTAssertEqual(VoiceCommandParser.parse("别向右转"), .stop)
    }

    func testWhitelistedCommands() {
        XCTAssertEqual(
            VoiceCommandParser.parse("前进"),
            .drive(DriveVector(vx: 0, vy: 100, omega: 0))
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("右平移"),
            .drive(DriveVector(vx: 100, vy: 0, omega: 0))
        )
        XCTAssertEqual(VoiceCommandParser.parse("随便走走"), .none)
    }
}
