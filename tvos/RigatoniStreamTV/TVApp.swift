import SwiftUI

@main
struct RigatoniStreamTVApp: App {
    // Shared with the iPhone build: AppModel/AccountAPI live in
    // ../ios/RigatoniStream/Core.swift and are compiled into this target.
    @StateObject private var model = AppModel()
    @StateObject private var themeStore = TVThemeStore.shared

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(model)
                .environmentObject(themeStore)
                .tint(TVTheme.accent)
                // The body re-evaluates when the theme changes, so the tint
                // and color scheme always follow the selected theme.
                .preferredColorScheme(themeStore.theme == .light ? .light : .dark)
                .task { await model.restore() }
        }
    }
}
