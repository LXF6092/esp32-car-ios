import SwiftUI

enum CarTheme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.07)
    static let surface = Color(red: 0.07, green: 0.10, blue: 0.12)
    static let raised = Color(red: 0.10, green: 0.14, blue: 0.16)
    static let border = Color.white.opacity(0.12)
    static let primary = Color(red: 0.18, green: 0.82, blue: 0.76)
    static let cyan = Color(red: 0.27, green: 0.72, blue: 0.95)
    static let warning = Color(red: 0.96, green: 0.67, blue: 0.20)
    static let danger = Color(red: 0.93, green: 0.25, blue: 0.30)
    static let success = Color(red: 0.28, green: 0.80, blue: 0.45)
    static let secondaryText = Color.white.opacity(0.64)
    static let disabledText = Color.white.opacity(0.34)
}

struct CarCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(CarTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(CarTheme.border, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 16, y: 8)
    }
}

extension View {
    func carCard() -> some View {
        modifier(CarCardModifier())
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.35), lineWidth: 1) }
    }
}
