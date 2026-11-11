import SwiftUI

struct HoverButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .editorHover()
    }
}

struct HoverColorButtonStyle: ButtonStyle {
    let color: Color
    let hoverColor: Color
    var bordered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, bordered ? 9 : 2)
            .frame(minWidth: bordered ? 38 : nil, minHeight: 22)
            .background {
                if bordered {
                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.055))
                }
            }
            .contentShape(Rectangle())
            .modifier(ColorHoverFeedback(color: color, hoverColor: hoverColor))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    func editorHover(radius: CGFloat = 5) -> some View {
        modifier(HoverFeedback(radius: radius))
    }

    func editorHoverBrightness() -> some View {
        modifier(BrightnessHoverFeedback())
    }
}

private struct ColorHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let color: Color
    let hoverColor: Color

    func body(content: Content) -> some View {
        content
            .foregroundStyle(hovering && enabled ? hoverColor : color)
            .opacity(enabled ? 1 : 0.35)
            .onHover { hovering = $0 }
    }
}

private struct BrightnessHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .brightness(hovering && enabled ? 0.15 : 0)
            .onHover { hovering = $0 }
    }
}

private struct HoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .overlay {
                if enabled && hovering {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.white.opacity(0.10))
                        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.13)) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
