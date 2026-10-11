import SwiftUI

@main
struct RigatoniStreamTVApp: App {
    // Shared with the iPhone build: AppModel/AccountAPI live in
    // ../ios/RigatoniStream/Core.swift and are compiled into this target.
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(model)
                .tint(TVTheme.red)
                .preferredColorScheme(.dark)
                .task { await model.restore() }
        }
    }
}
