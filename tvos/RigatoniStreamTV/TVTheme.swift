import SwiftUI

// The three user-selectable app themes, switchable in Settings and
// persisted per-device in UserDefaults. The Xfinity theme is *inspired by*
// the X1 layout language only — no Xfinity/Comcast logos, trademarks or
// copied assets anywhere in the app.
enum TVAppTheme: String, CaseIterable, Identifiable {
    case dark, light, xfinity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .xfinity: return "Xfinity"
        }
    }

    /// Full token set for the theme.
    var tokens: TVThemeTokens {
        switch self {
        case .dark:
            // The original Rigatoni Stream look, from theme.css.
            return TVThemeTokens(
                background: Color(red: 0.035, green: 0.035, blue: 0.043), // #09090b
                panel: Color(red: 0.090, green: 0.090, blue: 0.106),      // #17171b
                card: Color.white.opacity(0.06),
                focusCard: Color.white.opacity(0.18),
                text: Color(red: 0.980, green: 0.980, blue: 0.980),      // #fafafa
                muted: Color(red: 0.631, green: 0.631, blue: 0.667),     // #a1a1aa
                accent: Color(red: 0.898, green: 0.035, blue: 0.078))     // #e50914
        case .light:
            // iOS-style light appearance.
            return TVThemeTokens(
                background: Color(red: 0.949, green: 0.949, blue: 0.969), // #F2F2F7
                panel: .white,
                card: Color.black.opacity(0.05),
                focusCard: Color.black.opacity(0.12),
                text: Color(red: 0.110, green: 0.110, blue: 0.118),      // #1C1C1E
                muted: Color(red: 0.420, green: 0.447, blue: 0.502),      // #6B7280
                accent: Color(red: 0.898, green: 0.035, blue: 0.078))     // #e50914
        case .xfinity:
            // X1-inspired: deep navy surfaces, bright blue accent.
            return TVThemeTokens(
                background: Color(red: 0.043, green: 0.106, blue: 0.200), // #0B1B33
                panel: Color(red: 0.075, green: 0.161, blue: 0.294),      // #13294B
                card: Color.white.opacity(0.08),
                focusCard: Color.white.opacity(0.22),
                text: .white,
                muted: Color(red: 0.561, green: 0.639, blue: 0.749),      // #8FA3BF
                accent: Color(red: 0.231, green: 0.616, blue: 1.000))      // #3B9DFF
        }
    }
}

struct TVThemeTokens {
    let background: Color
    let panel: Color
    let card: Color
    let focusCard: Color
    let text: Color
    let muted: Color
    let accent: Color
}

// Shared, per-device theme selection. @Published (not @AppStorage) so the
// object reliably notifies SwiftUI; persistence is manual in didSet.
// Views read colors through the TVTheme statics below; the root view
// rebuilds the tree when the theme changes (`.id(theme)`), so the statics
// always resolve to the current theme without touching every call site.
final class TVThemeStore: ObservableObject {
    static let shared = TVThemeStore()

    @Published var theme: TVAppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey) }
    }

    private static let storageKey = "tvos-app-theme"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        self.theme = TVAppTheme(rawValue: raw ?? "") ?? .dark
    }
}

// Backwards-compatible accessor: every existing `TVTheme.xxx` call site
// now resolves through the selected theme's token set.
enum TVTheme {
    private static var tokens: TVThemeTokens { TVThemeStore.shared.theme.tokens }

    static var background: Color { tokens.background }
    static var panel: Color { tokens.panel }
    static var card: Color { tokens.card }
    static var focusCard: Color { tokens.focusCard }
    static var text: Color { tokens.text }
    static var muted: Color { tokens.muted }
    static var accent: Color { tokens.accent }
    /// Kept as an alias: the existing call sites use `.red` for the accent.
    static var red: Color { tokens.accent }
    static let corner: CGFloat = 16
}
