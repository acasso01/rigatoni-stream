import SwiftUI

// Design tokens mirrored from the web app's theme.css so the TV build
// looks like Ant Streams: dark background, off-white text, red accent.
enum TVTheme {
    static var background: Color { StreamTheme.background } // #09090b
    static var panel: Color { StreamTheme.panel }      // #17171b
    static let text = Color.primary       // #fafafa
    static var card: Color { StreamTheme.panel }
    static var focusCard: Color { StreamTheme.accent.opacity(0.22) }
    static var accent: Color { StreamTheme.accent }
    static var red: Color { StreamTheme.accent }        // #e50914
    static var muted: Color { StreamTheme.muted }
    static let corner: CGFloat = 18
}

// Observe mutations inside the reference store held by each tab.
struct TVObservedStore<Content: View>: View {
    @ObservedObject var store: TVLibraryStore
    @ViewBuilder var content: (TVLibraryStore) -> Content
    var body: some View { content(store) }
}

// Keep titles readable on the white focus highlight in every theme.
struct TVFocusTitle: View {
    let title: String
    @Environment(\.isFocused) private var focused
    var body: some View {
        Text(title).foregroundStyle(focused ? Color.black : TVTheme.text)
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
                        .stroke(focused ? Color.white : Color.clear, lineWidth: 3)
                }
        }
    }
}
