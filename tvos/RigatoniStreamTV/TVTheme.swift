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

private struct TVContentFocusKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
extension EnvironmentValues {
    var tvContentFocusScope: Namespace.ID? {
        get { self[TVContentFocusKey.self] }
        set { self[TVContentFocusKey.self] = newValue }
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
