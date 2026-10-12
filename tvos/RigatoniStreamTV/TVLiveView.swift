import SwiftUI

// Live TV tab: two full-height columns — a category sidebar (1/3) and the
// channel list (2/3). Both panels stretch from below the top tab bar to the
// bottom edge of the screen; the channel list scrolls inside its own
// full-height panel. Pin/unpin is a long-press (context menu) on a category
// row; the Pin button stays as a secondary path. Pins use the same
// CategoryPins UserDefaults key as the iPhone build, so they sync.
struct TVLiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var selectedCategory = ""
    @State private var pinnedIDs: [String] = []
    @State private var playing: CatalogItem?
    @State private var visibleCount = 60
    @FocusState private var focusedChannel: String?
    @FocusState private var focusedCategory: String?

    private var orderedCategories: [CatalogCategory] {
        guard let store else { return [] }
        return CategoryPins.ordered(store.categories, pins: pinnedIDs)
    }

    private var selectedName: String {
        orderedCategories.first { $0.id == selectedCategory }?.name ?? ""
    }

    private var isPinned: Bool { pinnedIDs.contains(selectedCategory) }

    var body: some View {
        Group {
            if let store { content(store) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(TVTheme.background)
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: .live, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        if !model.providerReady {
            Text("Save your provider in Settings to browse live TV.")
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.loading && store.categories.isEmpty {
            ProgressView(store.progress.isEmpty ? "Loading live TV…" : store.progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                HStack(spacing: 24) {
                    sidebar(store)
                        .frame(width: geo.size.width * 0.32, maxHeight: .infinity)
                    channelPanel(store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.libraryRevision) {
            await store.loadCategories()
            pinnedIDs = store.pinnedIDs()
            if selectedCategory.isEmpty || !orderedCategories.contains(where: { $0.id == selectedCategory }) {
                selectedCategory = orderedCategories.first?.id ?? ""
            }
        }
        .task(id: selectedCategory) {
            guard !selectedCategory.isEmpty else { return }
            visibleCount = 60
            await store.loadItems(categoryID: selectedCategory)
            focusedChannel = store.items.first?.id
        }
        .onChange(of: store.items.map(\.id)) { _, ids in
            if focusedChannel == nil { focusedChannel = ids.first }
        }
        .fullScreenCover(item: $playing) { item in
            TVPlayerView(item: item, provider: model.provider, channels: store.items)
        }
    }

    // MARK: - Sidebar

    private func sidebar(_ store: TVLibraryStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Live TV")
                .font(.largeTitle.bold())
                .padding(.horizontal, 28)
                .padding(.top, 28)
            Text("CATEGORIES")
                .font(.caption)
                .foregroundStyle(TVTheme.muted)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(orderedCategories) { category in
                        let pinned = pinnedIDs.contains(category.id)
                        let selected = selectedCategory == category.id
                        let focused = focusedCategory == category.id
                        Button { selectedCategory = category.id } label: {
                            HStack(spacing: 12) {
                                Text((pinned ? "★ " : "") + category.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(
                                selected ? TVTheme.accent
                                : focused ? TVTheme.focusCard
                                : TVTheme.card
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .focused($focusedCategory, equals: category.id)
                        .contextMenu {
                            Button(pinned ? "Unpin Category" : "Pin Category") {
                                togglePin(category.id, store: store)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            Button(isPinned ? "Unpin “\(selectedName)”" : "Pin category") {
                togglePin(selectedCategory, store: store)
            }
            .buttonStyle(.bordered)
            .tint(TVTheme.red)
            .disabled(selectedCategory.isEmpty)
            .padding(20)
        }
        .foregroundStyle(TVTheme.text)
        .background(TVTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
    }

    private func togglePin(_ id: String, store: TVLibraryStore) {
        guard !id.isEmpty else { return }
        pinnedIDs = CategoryPins.toggled(id, in: pinnedIDs)
        if let key = store.pinKey {
            UserDefaults.standard.set(pinnedIDs, forKey: key)
        }
    }

    // MARK: - Channel list

    private func channelPanel(_ store: TVLibraryStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.loading {
                ProgressView(store.progress.isEmpty ? "Loading…" : store.progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.error.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(store.error).foregroundStyle(TVTheme.muted)
                    Button("Retry") { store.revision += 1 }
                        .buttonStyle(.card)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                let visible = Array(store.items.prefix(visibleCount))
                if visible.isEmpty {
                    Text("No channels in this category.")
                        .foregroundStyle(TVTheme.muted)
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(visible) { item in
                                Button { playing = item } label: {
                                    HStack(spacing: 20) {
                                        TVChannelLogo(item: item)
                                        Text(item.name)
                                            .font(.title3)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 40))
                                            .foregroundStyle(TVTheme.red)
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(TVTheme.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.card)
                                .focused($focusedChannel, equals: item.id)
                                .contextMenu {
                                    Button(TVFavorites.contains(item: item, provider: model.provider)
                                           ? "Remove from Saved" : "Save to Favorites") {
                                        TVFavorites.toggle(item: item, provider: model.provider)
                                    }
                                }
                            }
                        }
                        .padding(24)

                        if store.items.count > visibleCount {
                            Button("Show more (\(store.items.count - visibleCount) remaining)") {
                                visibleCount += 60
                            }
                            .buttonStyle(.card)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                        }
                        Text("\(store.items.count) channels")
                            .font(.caption)
                            .foregroundStyle(TVTheme.muted)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .foregroundStyle(TVTheme.text)
        .background(TVTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
    }
}

// Channel logo box. Logos come from the provider's stream_icon and load
// through ProviderPoster (same bounded in-memory fetch as the iPhone build).
// Notes on blank logos:
// - Direct providers: the URL is fetched as-is. HTTP icon URLs need the
//   Mac-time ATS exception (tvos/configure_http.py, same as the iPhone
//   build's configure_http.py) or they are blocked.
// - Gateway providers: the gateway deliberately strips live channel icons
//   ("Provider icons can be HTTP or carry provider credentials"), so the
//   app never receives a logo URL. Restoring them needs the gateway to
//   relay icons through session.register like it does for movie posters
//   (gateway/server.mjs, /api/connect channels projection).
// Logo URLs never carry provider credentials: the gateway only relays
// opaque /media tickets, and direct loads use the raw icon URL.
struct TVChannelLogo: View {
    let item: CatalogItem

    var body: some View {
        ZStack {
            TVTheme.card
            if let url = item.poster {
                ProviderPoster(url: url, kind: .live)
            } else {
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.title.bold())
                    .foregroundStyle(TVTheme.muted)
            }
        }
        .frame(width: 120, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
