import SwiftUI

// Home tab: quick-access rows for pinned Live TV categories.
// Pinning happens in Live TV; category IDs are stored locally on this Apple TV.
struct TVHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var playing: CatalogItem?

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    TVHomeBody(store: store, model: model, playing: $playing)
                        .fullScreenCover(item: $playing) { item in
                            CatalogDestination(item: item, channels: store.items)
                        }
                } else {
                    ProgressView("Loading…")
                }
            }
        }
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: .live, model: model) }
        }
    }
}

private struct TVHomeBody: View {
    @ObservedObject var store: TVLibraryStore
    @ObservedObject var model: AppModel
    @Binding var playing: CatalogItem?
    @StateObject private var shelves = HomeShelfLoader()
    @AppStorage("rigatoni-tmdb-api-key") private var tmdbKey = ""
    @State private var openedShow: SeriesItem?
    @State private var showDetail = false

    private var pinned: [CatalogCategory] {
        let ids = Set(store.pinnedIDs())
        return CategoryPins.ordered(model.preferences.browseCategories(store.categories, section: .live), pins: store.pinnedIDs())
            .filter { ids.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    StreamHeading(title: "Welcome home", subtitle: "Trending, recently added, and the channels you pinned.")
                }
                .padding(.top, 40)
                .tvLanding(for: .home)

                if model.providerReady {
                    if shelves.loading && shelves.trendingMovies.isEmpty && shelves.trendingShows.isEmpty {
                        ProgressView("Loading posters…")
                    }
                    PosterShelf(title: "Trending this week, Movies", posters: shelves.trendingMovies, width: 230) { open($0) }
                    PosterShelf(title: "Trending this week, Shows", posters: shelves.trendingShows, width: 230) { open($0) }
                    PosterShelf(title: "Recently added", posters: shelves.recent, width: 230) { open($0) }
                    TVHistoryRail(title: "Continue watching", onlyInProgress: true, hidesWhenEmpty: true)
                    TVHistoryRail()
                }

                if !model.providerReady {
                    Text("Save your provider in Settings to start watching.")
                        .foregroundStyle(TVTheme.muted)
                } else if store.loading && store.categories.isEmpty {
                    ProgressView(store.progress.isEmpty ? "Loading…" : store.progress)
                } else if pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pin categories in Live TV for quick access here.")
                            .foregroundStyle(TVTheme.muted)
                    }
                } else {
                    ForEach(pinned) { category in
                        TVPinnedRow(category: category, model: model, playing: $playing)
                    }
                }

                if !store.error.isEmpty { Text(store.error).foregroundStyle(TVTheme.muted) }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .background { StreamBackdrop() }
        .task(id: "\(model.libraryRevision)-\(tmdbKey.hashValue)") {
            await store.loadCategories()
            await shelves.load(model: model, tmdbKey: tmdbKey)
        }
        .navigationDestination(isPresented: $showDetail) {
            if let openedShow {
                TVSeriesDetailView(series: openedShow, store: SeriesStore(model: model))
            }
        }
    }

    private func open(_ poster: ShelfPoster) {
        switch poster.media {
        case .movie(let item): playing = item
        case .show(let series):
            openedShow = series
            showDetail = true
        }
    }
}

// One pinned category's horizontal row of channel cards.
private struct TVPinnedRow: View {
    let category: CatalogCategory
    @ObservedObject var model: AppModel
    @Binding var playing: CatalogItem?
    @State private var items: [CatalogItem] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category.name).font(.title2.bold())
            if loading {
                ProgressView().frame(height: 120)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(items.filter(model.preferences.visible).prefix(20), id: \.scopedID) { item in
                            Button { playing = item } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProviderPoster(url: item.poster, kind: .live)
                                        .frame(width: 240, height: 140)
                                        .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
                                    Text(model.preferences.itemTitle(item))
                                        .font(.headline)
                                        .lineLimit(1)
                                        .frame(width: 240, alignment: .leading)
                                }
                            }
                            .buttonStyle(TVCardButtonStyle())
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .task {
            loading = true
            defer { loading = false }
            do {
                // Lightweight per-row fetch using the shared catalog types.
                let loaded = try await model.catalog.items(kind: .live, category: category.id, model: model)
                try Task.checkCancellation(); items = loaded
            } catch { items = [] }
        }
    }
}
