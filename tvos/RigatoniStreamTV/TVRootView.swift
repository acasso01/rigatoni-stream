import SwiftUI

// Root of the tvOS app: provider setup when nothing is saved, then an X1-style left nav rail with
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
    case home, guide, live, multi, movies, shows, saved, search, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .guide: return "Guide"
        case .live: return "Live TV"
        case .multi: return "Multi View"
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
        case .multi: return "square.split.2x2"
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
    @Namespace private var railFocus
    @Namespace private var contentFocus
    /// Not `@StateObject`: a request must not rebuild the rail.
    @State private var focusRouter = TVFocusRouter()
    /// True after a right-move until focus comes back to the rail.
    @State private var contentOwnsFocus = false
    /// Ignores the focus engine's one-frame fallback while entry is in flight.
    @State private var entryGrace = false
    @State private var entryToken = UUID()
    @State private var entryTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            StreamBackdrop()
            Group {
                if model.starting {
                    ProgressView("Opening Ant Streams…")
                } else if !model.needsProviderSetup {
                    HStack(spacing: 0) {
                        navRail
                            .focusScope(railFocus)
                            .focusSection()
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focusSection()
                            .focusScope(contentFocus)
                            .environment(\.tvContentFocusScope, contentFocus)
                            .environment(\.tvRailAction, TVRailAction(returnToRail: { returnToRail() }))
                            .onExitCommand {
                                // Menu while entry is still resolving is the
                                // failed right-move, not a request to leave.
                                if !entryGrace { returnToRail() }
                            }
                    }
                    .onAppear {
                        if focusedItem == nil { focusedItem = selection }
                    }
                    .onChange(of: focusedItem) { _, item in
                        // Nil means focus left the rail for a content control.
                        // That must not select Home.
                        guard let item else { return }
                        if entryGrace { return }
                        if contentOwnsFocus {
                            // Left re-entered the rail. Keep the open tab
                            // selected instead of accepting the geometrically
                            // nearest button, which can be an unrelated tab.
                            contentOwnsFocus = false
                            focusRouter.cancel()
                            if item != selection { focusedItem = selection }
                        }
                        // Up/Down only move the rail highlight. The content
                        // pane changes when the user selects the item or moves
                        // right into it.
                    }
                    // Rebuild the whole tree on theme change so every
                    // TVTheme.xxx static resolves to the new theme.
                    .id(appearance + (model.vault.selectedID?.uuidString ?? ""))
                } else {
                    TVProviderSetupView()
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
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(TVTheme.muted)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)

            ForEach(TVSection.allCases) { section in
                let selected = selection == section
                let focused = focusedItem == section
                Button { enterContent(section) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 30))
                            .frame(width: 38)
                        Text(section.title)
                            .font(.system(size: 28, weight: selected ? .bold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 62, alignment: .leading)
                    .background {
                        if selected { TVTheme.accentFill }
                        else { focused ? TVTheme.focusCard : Color.clear }
                    }
                    .foregroundStyle(selected ? TVTheme.onAccent : TVTheme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(TVCompactButtonStyle())
                .focused($focusedItem, equals: section)
                .prefersDefaultFocus(selected, in: railFocus)
                .onMoveCommand { direction in
                    // Let tvOS perform vertical focus movement once. Reassigning
                    // @FocusState here races the focus engine and can turn one
                    // remote press into multiple rail steps.
                    if direction == .right { enterContent(section) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

        }
        .padding(.bottom, 20)
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(TVTheme.panel)
    }

    /// Right (or a click) opens the highlighted tab and moves focus into it.
    /// Up/Down can browse the rail without replacing the current content.
    private func enterContent(_ preferred: TVSection? = nil) {
        let section = preferred ?? focusedItem ?? selection
        if selection != section { selection = section }
        contentOwnsFocus = true
        entryGrace = true
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
        contentOwnsFocus = false
        focusRouter.cancel()
        focusedItem = selection
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home: TVHomeView()
        case .guide: TVGuideView()
        case .live: TVLiveView()
        case .multi: TVMultiView()
        case .movies: TVMoviesView()
        case .shows: TVShowsView()
        case .saved: TVSavedView()
        case .search: TVSearchView()
        case .settings: TVSettingsView()
        }
    }
}
