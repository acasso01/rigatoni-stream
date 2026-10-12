import SwiftUI

// Generic tvOS catalog browser used by the Live TV and Movies tabs.
// Same data path as the iPhone build (shared TVLibraryStore / CatalogLoader),
// rebuilt for the Siri Remote: focusable category bar, focusable card grid,
// pin/unpin for Live TV. Pressing a card plays it full-screen; the Menu
// button backs out of the player automatically.
struct TVCatalogBrowser: View {
    let kind: LibraryKind
    let allowPins: Bool

    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var selectedCategory = ""
    @State private var pinnedIDs: [String] = []
    @State private var playing: CatalogItem?
    @State private var visibleCount = 60
    @FocusState private var focusedCard: String?

    private var orderedCategories: [CatalogCategory] {
        guard let store else { return [] }
        return allowPins ? CategoryPins.ordered(store.categories, pins: pinnedIDs) : store.categories
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
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: kind, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(kind.title)
                    .font(.largeTitle.bold())
                    .padding(.top, 40)

                if !model.providerReady {
                    Text("Save your provider in Settings to browse \(kind.title.lowercased()).")
                        .foregroundStyle(TVTheme.muted)
                } else if store.loading && store.categories.isEmpty {
                    ProgressView(store.progress.isEmpty ? "Loading \(kind.title.lowercased())…" : store.progress)
                } else {
                    categoryBar(store)
                    if kind == .movies, let hero = store.items.first, !store.loading {
                        TVHeroBanner(
                            title: hero.name,
                            subtitle: selectedName.isEmpty ? "Movie" : selectedName,
                            badge: "FEATURED MOVIE",
                            poster: hero.poster,
                            posterKind: .movies
                        ) { playing = hero }
                    }
                    if store.loading {
                        ProgressView(store.progress.isEmpty ? "Loading…" : store.progress)
                    } else if !store.error.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.error).foregroundStyle(TVTheme.muted)
                            Button("Retry") { store.revision += 1 }
                                .buttonStyle(.card)
                        }
                    } else {
                        itemGrid(store)
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .background(TVTheme.background)
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
            focusedCard = store.items.first?.id
        }
        .onChange(of: store.items.map(\.id)) { _, ids in
            if focusedCard == nil { focusedCard = ids.first }
        }
        .fullScreenCover(item: $playing) { item in
            TVPlayerView(item: item, provider: model.provider, channels: kind == .live ? store.items : [])
        }
    }

    @ViewBuilder
    private func categoryBar(_ store: TVLibraryStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(orderedCategories) { category in
                        Button {
                            selectedCategory = category.id
                        } label: {
                            Text((allowPins && pinnedIDs.contains(category.id) ? "★ " : "") + category.name)
                                .font(.headline)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedCategory == category.id ? TVTheme.red : TVTheme.muted)
                    }
                }
                .padding(.vertical, 8)
            }
            if allowPins {
                Button(isPinned ? "Unpin “\(selectedName)”" : "Pin “\(selectedName)”") {
                    pinnedIDs = CategoryPins.toggled(selectedCategory, in: pinnedIDs)
                    if let key = store.pinKey {
                        UserDefaults.standard.set(pinnedIDs, forKey: key)
                    }
                }
                .disabled(selectedCategory.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func itemGrid(_ store: TVLibraryStore) -> some View {
        let visible = Array(store.items.prefix(visibleCount))
        if visible.isEmpty {
            Text("No titles available.").foregroundStyle(TVTheme.muted)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: kind == .movies ? 220 : 260), spacing: 28)],
                spacing: 32
            ) {
                ForEach(visible) { item in
                    Button { playing = item } label: {
                        TVCatalogCard(item: item)
                    }
                    .buttonStyle(.card)
                    .focused($focusedCard, equals: item.id)
                    .contextMenu {
                        Button(TVFavorites.contains(item: item, provider: model.provider)
                               ? "Remove from Saved" : "Save to Favorites") {
                            TVFavorites.toggle(item: item, provider: model.provider)
                        }
                    }
                }
            }
            if store.items.count > visibleCount {
                Button("Show more (\(store.items.count - visibleCount) remaining)") {
                    visibleCount += 60
                }
                .buttonStyle(.card)
                .padding(.top, 8)
            }
            Text("\(store.items.count) titles")
                .font(.caption)
                .foregroundStyle(TVTheme.muted)
                .padding(.top, 8)
        }
    }
}

// One focusable catalog card. Poster loading reuses the shared
// ProviderPoster view (same bounded in-memory fetch as the iPhone build).
struct TVCatalogCard: View {
    let item: CatalogItem

    private var cardWidth: CGFloat { item.kind == .movies ? 200 : 260 }
    private var cardHeight: CGFloat { item.kind == .movies ? 300 : 146 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderPoster(url: item.poster, kind: item.kind)
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
            Text(item.name)
                .font(.headline)
                .lineLimit(2)
                .frame(width: cardWidth, alignment: .leading)
        }
        .foregroundStyle(TVTheme.text)
    }
}
