import SwiftUI

// Root of the tvOS app: sign-in gate, then a top tab bar with
// Home, Live TV, Movies, Search and Settings.
struct TVRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()
            Group {
                if model.starting {
                    ProgressView("Opening Rigatoni Stream…")
                } else if model.signedIn {
                    TabView {
                        TVHomeView()
                            .tabItem { Label("Home", systemImage: "house") }
                        TVLiveView()
                            .tabItem { Label("Live TV", systemImage: "tv") }
                        TVMoviesView()
                            .tabItem { Label("Movies", systemImage: "film") }
                        TVSearchView()
                            .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        TVSettingsView()
                            .tabItem { Label("Settings", systemImage: "gearshape") }
                    }
                } else {
                    TVLoginView()
                }
            }
            .foregroundStyle(TVTheme.text)
        }
    }
}
