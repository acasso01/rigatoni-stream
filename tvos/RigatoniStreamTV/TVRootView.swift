import SwiftUI

// Root of the tvOS app: sign-in gate, then an X1-style left nav rail with
// the content area to its right. The rail replaces the old top tab bar.
// The content tree is rebuilt when the theme changes (`.id(theme)`), which
// keeps the static TVTheme color accessors in sync without touching every
// view.
//
// Focus model (tvOS focus engine, no programmatic handoffs): the rail keeps
// a @FocusState for styling, arrow keys move between rail and content
// naturally, and each content view sets its own initial focus when its
// controls are ready. Menu anywhere in content returns focus to the rail.
enum TVSection: String, CaseIterable, Identifiable {
    case home, guide, live, movies, shows, saved, search, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .guide: return "Guide"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .shows: return "TV Shows"
        case .saved: return "Saved"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .guide: return "square.grid.2x2"
        case .live: return "tv"
        case .movies: return "film"
        case .shows: return "play.tv"
        case .saved: return "bookmark"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct TVRootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @State private var selection: TVSection = .home
    @FocusState private var focusedItem: TVSection?

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()
            Group {
                if model.starting {
                    ProgressView("Opening Ant Streams…")
                } else if model.providerReady {
                    HStack(spacing: 0) {
                        navRail
                            .focusSection()
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focusSection()
                            .onExitCommand { focusedItem = selection }
                    }
                    // Rebuild the whole tree on theme change so every
                    // TVTheme.xxx static resolves to the new theme.
                    .id(appearance + (model.vault.selectedID?.uuidString ?? ""))
                } else {
                    ProviderWelcomeView()
                }
            }
            .foregroundStyle(TVTheme.text)
        }
    }

    // MARK: - Nav rail

    private var navRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ANT STREAMS")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(TVTheme.muted)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 20)

            ForEach(TVSection.allCases) { section in
                let selected = selection == section
                let focused = focusedItem == section
                Button { selection = section } label: {
                    HStack(spacing: 14) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 26))
                            .frame(width: 32)
                        Text(section.title)
                            .font(.system(size: 25, weight: selected ? .bold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .background(
                        selected ? TVTheme.accent
                        : focused ? TVTheme.focusCard
                        : Color.clear
                    )
                    .foregroundStyle(selected ? .white : TVTheme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(TVCompactButtonStyle())
                .focused($focusedItem, equals: section)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .frame(width: 300)
        .background(TVTheme.panel)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home: TVHomeView()
        case .guide: TVGuideView()
        case .live: TVLiveView()
        case .movies: TVMoviesView()
        case .shows: TVShowsView()
        case .saved: TVSavedView()
        case .search: TVSearchView()
        case .settings: TVSettingsView()
        }
    }
}
