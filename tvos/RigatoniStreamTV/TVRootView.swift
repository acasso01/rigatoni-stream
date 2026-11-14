import SwiftUI

// Root of the tvOS app: sign-in gate, then an X1-style left nav rail with
// the content area to its right. The rail replaces the old top tab bar.
// The content tree is rebuilt when the theme changes (`.id(theme)`), which
// keeps the static TVTheme color accessors in sync without touching every
// view.
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
    @Namespace private var contentFocus
    /// Not `@StateObject`: a request must not rebuild the rail.
    @State private var focusRouter = TVFocusRouter()
    /// True after a right-move until focus comes back to the rail.
    @State private var contentOwnsFocus = false
    /// Ignores the focus engine's one-frame fallback while entry is in flight.
    @State private var entryGrace = false
    @State private var entryToken = UUID()
    @State private var entryTask: Task<Void, Never>?
    /// After a tab swap, ignore a focus reset onto the Home rail button.
    @State private var restoringRail = false
    @State private var restoreToken = UUID()
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()
            Group {
                if model.starting {
                    ProgressView("Opening Ant Streams…")
                } else if model.signedIn {
                    HStack(spacing: 0) {
                        navRail
                            .focusSection()
                            .onMoveCommand { direction in
                                if direction == .right { enterContent() }
                            }
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focusSection()
                            .focusScope(contentFocus)
                            .environment(\.tvContentFocusScope, contentFocus)
                            .onExitCommand {
                                // Menu while entry is still resolving is the
                                // failed right-move, not a request to leave.
                                if !entryGrace { returnToRail() }
                            }
                    }
                    .onChange(of: focusedItem) { _, item in
                        // Nil means focus left the rail for a content control.
                        // That must not select Home.
                        guard let item else { return }
                        if entryGrace { return }
                        if contentOwnsFocus {
                            // Left (or a failed move) re-entered the rail.
                            // Park on the open tab instead of whichever
                            // button is geometrically nearest — often Home.
                            contentOwnsFocus = false
                            focusRouter.cancel()
                            if item != selection { focusedItem = selection }
                            return
                        }
                        if restoringRail, item == .home, selection != .home {
                            focusedItem = selection
                            return
                        }
                        guard item != selection else { return }
                        selection = item
                        beginRestoreWindow()
                    }
                    // Rebuild the whole tree on theme change so every
                    // TVTheme.xxx static resolves to the new theme.
                    .id(appearance)
                } else {
                    TVLoginView()
                }
            }
            .foregroundStyle(TVTheme.text)
        }
        .environmentObject(focusRouter)
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
                Button { enterContent(section) } label: {
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

    /// Right (or a click) moves into the highlighted tab. The tab is already
    /// selected by rail focus, so this does not swap the content view out
    /// from under the focus engine, and it never falls back to Home when the
    /// rail binding clears mid-move.
    private func enterContent(_ preferred: TVSection? = nil) {
        let highlighted = focusedItem ?? selection
        // A content swap can dump focus onto the Home rail button for a
        // frame. The committed tab is `selection` during that window.
        let section = preferred ?? (restoringRail && highlighted == .home && selection != .home ? selection : highlighted)
        if selection != section { selection = section }
        contentOwnsFocus = true
        entryGrace = true
        restoringRail = false
        let token = UUID()
        entryToken = token
        focusRouter.request(section)
        entryTask?.cancel()
        entryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, entryToken == token else { return }
            entryGrace = false
            guard contentOwnsFocus, let item = focusedItem else { return }
            // Focus is still on the rail, so the content control did not take it.
            // A nil binding means the entry succeeded — leave that focus alone.
            contentOwnsFocus = false
            focusRouter.cancel()
            if item != section { focusedItem = section }
        }
    }

    /// Menu, or focus returning from the content pane. Does not change tabs.
    private func returnToRail() {
        entryToken = UUID()
        entryGrace = false
        restoringRail = false
        contentOwnsFocus = false
        focusRouter.cancel()
        focusedItem = selection
    }

    private func beginRestoreWindow() {
        restoringRail = true
        restoreTask?.cancel()
        let token = UUID()
        restoreToken = token
        restoreTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, restoreToken == token else { return }
            restoringRail = false
        }
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
