import SwiftUI

// Root of the tvOS app: sign-in gate, then a top tab bar with
// Home, Live TV, Movies, Search and Settings.
struct TVRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            StreamBackdrop()
            Group {
                if model.starting {
                    ProgressView("Opening Rigatoni Stream…")
                } else if model.signedIn {
                    TabView {
                        TVHomeView()
                            .tabItem { Label("Home", systemImage: "house") }
                        TVMoviesView()
                            .tabItem { Label("Movies", systemImage: "film") }
                        TVLiveView()
                            .tabItem { Label("Live TV", systemImage: "tv") }
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
