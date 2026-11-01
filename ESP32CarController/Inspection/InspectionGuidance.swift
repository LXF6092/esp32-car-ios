import Foundation

enum InspectionMarkerAction: Equatable {
    case stop
    case checkpoint(String)
    case ignored
}
enum InspectionGuidance {
    static func parseMarker(_ source: String) -> InspectionMarkerAction {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = text.uppercased()
        if upper == "ESP32CAR:STOP" || upper == "ESP32CAR:PAUSE" {
            return .stop
        }
        let prefix = "ESP32CAR:CHECKPOINT:"
        guard upper.hasPrefix(prefix) else { return .ignored }
        let name = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { return .ignored }
        return .checkpoint(name)
    }

    static func driveVector(lineOffset: Double?, confidence: Double, frameIsFresh: Bool) -> DriveVector {
        guard frameIsFresh, let lineOffset, confidence >= 0.16 else { return .zero }
        let offset = max(-1, min(1, lineOffset))
        let quality = max(0, min(1, confidence))
        let forward = Int(35 + quality * 25)
        let lateral = Int(offset * 18)
        let rotation = Int(offset * 58)
        return DriveVector(vx: lateral, vy: forward, omega: rotation)
    }
}
