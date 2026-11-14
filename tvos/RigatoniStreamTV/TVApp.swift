import SwiftUI

@main
struct RigatoniStreamTVApp: App {
    // Shared with the iPhone build: AppModel live in
    // ../ios/RigatoniStream/Core.swift and are compiled into this target.
    @StateObject private var model = AppModel()
    @AppStorage("rigatoni-appearance") private var appearance = "dark"

    init() {
        AppAppearance.migrateStoredSelection()
    }
    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(model)
                .environmentObject(model.catalog)
                .tint((AppAppearance(rawValue: appearance) ?? .dark).accent)
                .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
            .environment(\.colorScheme, (AppAppearance(rawValue: appearance) ?? .dark).scheme)
            .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .dark).scheme)
                .task { await model.restore() }
        }
    }
}
