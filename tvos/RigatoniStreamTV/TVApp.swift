import SwiftUI

@main
struct RigatoniStreamTVApp: App {
    // Shared with the iPhone build: AppModel/AccountAPI live in
    // ../ios/RigatoniStream/Core.swift and are compiled into this target.
    @StateObject private var model = AppModel()
    @AppStorage("rigatoni-appearance") private var appearance = "dark"

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(model)
                .environmentObject(model.catalog)
                .tint((AppAppearance(rawValue: appearance) ?? .dark).accent)
                .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .dark).scheme)
                .task { await model.restore() }
        }
    }
}
