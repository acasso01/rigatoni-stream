import SwiftUI

@main
struct RigatoniStreamTVApp: App {
    // Shared with the iPhone build: AppModel live in
    // ../ios/RigatoniStream/Core.swift and are compiled into this target.
    @StateObject private var model = AppModel()
    @AppStorage("rigatoni-appearance") private var appearance = "dark"

    init() {
        if UserDefaults.standard.string(forKey: "rigatoni-appearance") == "netflix" {
            UserDefaults.standard.set("dark", forKey: "rigatoni-appearance")
        }
        if UserDefaults.standard.string(forKey: "rigatoni-appearance") == "xfinity" {
            UserDefaults.standard.set("midnight", forKey: "rigatoni-appearance")
        }
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
