import SwiftUI

struct HoldControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = CarTheme.primary
    var disabled = false
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var pressed = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 72)
            .foregroundStyle(disabled ? CarTheme.secondaryText : Color.white)
            .background(
                disabled ? CarTheme.background : (pressed ? tint.opacity(0.85) : CarTheme.raised),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(pressed ? tint : CarTheme.border, lineWidth: pressed ? 2 : 1)
            }
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityValue(disabled ? "不可用" : (pressed ? "按住中" : "可用"))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !disabled, !pressed else { return }
                        pressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard pressed else { return }
                        pressed = false
                        onRelease()
                    }
            )
            .onChange(of: disabled) { value in
                if value && pressed {
                    pressed = false
                    onRelease()
                }
            }
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}
