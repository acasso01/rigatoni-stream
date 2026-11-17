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

struct TVRailAction {
    var returnToRail: () -> Void = {}
}

private struct TVRailActionKey: EnvironmentKey {
    static let defaultValue = TVRailAction()
}

private struct TVContentFocusKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
extension EnvironmentValues {
    var tvContentFocusScope: Namespace.ID? {
        get { self[TVContentFocusKey.self] }
        set { self[TVContentFocusKey.self] = newValue }
    }
    var tvRailAction: TVRailAction {
        get { self[TVRailActionKey.self] }
        set { self[TVRailActionKey.self] = newValue }
    }
}

/// The focus engine's geometric search treats a tall view on the right as the
/// Down target. Re-apply the vertical target after that search runs.
enum TVColumnFocus {
    @MainActor
    static func keep<ID: Hashable>(_ binding: FocusState<ID?>.Binding, _ next: ID) {
        // One request per press. Delayed repeats can reclaim focus after
        // another key press or Back has already moved to a different column.
        binding.wrappedValue = next
    }
}
private struct TVContentEntry: ViewModifier {
    @Environment(\.tvContentFocusScope) private var scope
    let preferred: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if let scope { content.prefersDefaultFocus(preferred, in: scope) }
        else { content }
    }
}
extension View {
    func tvContentEntry(_ preferred: Bool = true) -> some View {
        modifier(TVContentEntry(preferred: preferred))
    }

    /// Re-apply the content focus scope inside containers (NavigationStack,
    /// for example) that don't inherit the outer scope's default-focus target.
    func tvAdoptContentFocusScope() -> some View {
        modifier(TVAdoptContentFocusScope())
    }

    /// Focusable placeholder so a tab with no other controls can still take
    /// a right-move from the rail. `when` is false leaves the view unchanged
    /// so a screen never installs two entry targets.
    @ViewBuilder func tvLanding(for section: TVSection, when enabled: Bool = true) -> some View {
        if enabled { TVEntryControl(section: section) { self.focusable() } }
        else { self }
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

private struct TVAdoptContentFocusScope: ViewModifier {
    @Environment(\.tvContentFocusScope) private var scope
    @ViewBuilder func body(content: Content) -> some View {
        if let scope { content.focusScope(scope) }
        else { content }
    }
}

/// Asks the selected tab to focus its entry control. Held with `@State` (not
/// `@StateObject`) so publishing a request does not rebuild the rail.
@MainActor
final class TVFocusRouter: ObservableObject {
    @Published private(set) var requested: TVSection?
    private var generation = 0

    func request(_ section: TVSection) {
        generation += 1
        let generation = generation
        requested = nil
        Task { @MainActor in
            guard generation == self.generation else { return }
            self.requested = section
        }
    }

    func cancel() {
        generation += 1
        requested = nil
    }
}

/// Focuses `content` when the rail moves right into `section`.
/// The closure runs in `body` so bindings and the focus scope stay attached.
struct TVEntryControl<Content: View>: View {
    let section: TVSection
    private let content: () -> Content
    @EnvironmentObject private var router: TVFocusRouter
    @FocusState private var focused: Bool

    init(section: TVSection, @ViewBuilder content: @escaping () -> Content) {
        self.section = section
        self.content = content
    }

    var body: some View {
        content()
            .focused($focused)
            .onChange(of: router.requested) { _, requested in
                if requested == section { focused = true }
            }
    }
}

// NOTE: tvOS focus is handled per-view with @FocusState entry points (see
// TVRootView). The previous prefersDefaultFocus/resetFocus handoff proved
// unreliable against async content loading and was removed.
