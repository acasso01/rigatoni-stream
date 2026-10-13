import SwiftUI

// Native theme tokens shared with the iPhone app.
enum TVTheme {
    static var background: Color { StreamTheme.background } // #09090b
    static var panel: Color { StreamTheme.panel }      // #17171b
    static var text: Color { StreamTheme.text }
    static var card: Color { StreamTheme.card }
    static var accent: Color { StreamTheme.accent }
    static var accentFill: LinearGradient { StreamTheme.accentFill }
    static var onAccent: Color { StreamTheme.onAccent }
    static var red: Color { StreamTheme.accent }        // #e50914
    static var muted: Color { StreamTheme.muted }
    static let corner: CGFloat = 18

    /// Focus fill: a clearly visible darker tint on focused cards. On the
    /// Light theme the old accent-wash was invisible against white cards,
    /// so focused items get a strong dark overlay instead.
    static var focusFill: Color {
        switch StreamTheme.appearance {
        case .light: return Color.black.opacity(0.32)
        default: return StreamTheme.accent.opacity(0.28)
        }
    }
    /// Focus ring: near-black on Light (white was invisible), white on dark themes.
    static var focusRing: Color {
        switch StreamTheme.appearance {
        case .light: return Color.black.opacity(0.9)
        default: return Color.white
        }
    }
    /// Kept for the nav rail; now theme-aware like focusFill.
    static var focusCard: Color { focusFill }
}

// Observe mutations inside the reference store held by each tab.
struct TVObservedStore<Content: View>: View {
    @ObservedObject var store: TVLibraryStore
    @ViewBuilder var content: (TVLibraryStore) -> Content
    var body: some View { content(store) }
}

// Keep titles readable on the focused overlay in every theme.
// The overlay is always dark-ish (dark tint on Light, accent tint on
// dark themes), so focused titles stay white.
struct TVFocusTitle: View {
    let title: String
    @Environment(\.isFocused) private var focused
    var body: some View {
        Text(title).foregroundStyle(focused ? Color.white : TVTheme.text)
    }
}

// Explicit focus feedback without the system button's extra insets or scale.
// Fixed-width navigation and guide cells must retain their measured size.
struct TVCompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration)
    }

    private struct FocusBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.75 : 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(focused ? TVTheme.focusRing : Color.clear, lineWidth: 3)
                }
        }
    }
}

// Theme-aware replacement for the system .card button style. The system
// style's white focus highlight washes out completely on the Light theme's
// white cards, so focused cards get an unmistakable dark tint + strong ring
// in every theme instead.
struct TVCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.8 : 1)
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: TVTheme.corner)
                            .fill(TVTheme.focusFill)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: TVTheme.corner)
                        .stroke(focused ? TVTheme.focusRing : Color.clear, lineWidth: 4)
                }
                .scaleEffect(focused ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

// NOTE: tvOS focus is handled per-view with @FocusState entry points (see
// TVRootView). The previous prefersDefaultFocus/resetFocus handoff proved
// unreliable against async content loading and was removed.
