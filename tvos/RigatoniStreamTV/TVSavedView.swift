import SwiftUI

// Saved tab: the user's favorited channels, movies and shows.
// Long-press (hold) a channel, movie or show anywhere in the app to add
// or remove it here. Playback URLs are rebuilt from the provider at play
// time; series need a direct provider connection.
struct TVSavedView: View {
    @EnvironmentObject private var model: AppModel
    @State private var favorites: [TVFavoriteRecord] = []
    @State private var playing: CatalogItem?
    @State private var playingKind: String?
    @State private var detailSeries: TVSeriesDetailRequest?
    // Detail screens push on a NavigationStack so the player's cover is a
    // single modal level (nested fullScreenCovers silently fail on tvOS).
    @State private var detailItem: CatalogItem?
    @State private var showingDetail = false
    @State private var showingSeriesDetail = false
    @State private var notice = ""
    @State private var connecting = false

    var body: some View {
        NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Saved")
                    .font(.largeTitle.bold())
                    .padding(.top, 40)

                if !model.providerReady {
                    Text("Save your provider in Settings to see your favorites.")
                        .font(.title3)
                        .foregroundStyle(TVTheme.muted)
                } else if favorites.isEmpty {
                    Text("Nothing saved yet — hold a channel, movie or show to add it here.")
                        .font(.title3)
                        .foregroundStyle(TVTheme.muted)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 28)],
                        spacing: 32
                    ) {
                        ForEach(favorites) { record in
                            savedCard(record)
                        }
                    }
                }

                if !notice.isEmpty {
                    Text(notice).foregroundStyle(TVTheme.red)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .navigationDestination(isPresented: $showingDetail) {
            if let item = detailItem { MovieDetailView(item: item) }
        }
        .navigationDestination(isPresented: $showingSeriesDetail) {
            if let request = detailSeries { TVSeriesDetailView(series: request.series, store: request.store).environmentObject(model) }
        }
        }
        .background(TVTheme.background)
        .foregroundStyle(TVTheme.text)
        .onAppear { reload() }
        .onChange(of: model.libraryRevision) { _, _ in reload() }
        .fullScreenCover(item: $playing) { item in
            CatalogDestination(item: item)
        }
    }

    private func reload() {
        notice = ""
        favorites = TVFavorites.items(model: model).filter { record in
            record.kind == "series" || model.preferences.visible(CatalogItem(id: record.itemID, name: record.name, kind: record.kind == "live" ? .live : .movies, fileExtension: record.ext, poster: nil, categoryID: record.categoryID))
        }
    }

    private func savedCard(_ record: TVFavoriteRecord) -> some View {
        let isLive = record.kind == "live"
        return Button { play(record) } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    ZStack {
                        TVTheme.card
                        if let url = TVFavorites.poster(record, model: model) {
                            ProviderPoster(url: url, kind: isLive ? .live : .movies)
                        } else {
                            Image(systemName: isLive ? "tv" : "film")
                                .font(.largeTitle)
                                .foregroundStyle(TVTheme.muted)
                        }
                    }
                    .frame(width: 240, height: isLive ? 150 : 320)
                    .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))

                    badge(record.kind == "series" ? "TV SHOW" : isLive ? "LIVE" : "MOVIE",
                          red: isLive)
                }
                TVFocusTitle(title: record.name)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(width: 240, alignment: .leading)
            }
        }
        .buttonStyle(TVCardButtonStyle())
        .disabled(connecting)
        .contextMenu {
            Button("Remove from Saved") {
                TVFavorites.toggle(id: record.itemID, name: record.name,
                                   kind: record.kind, ext: record.ext,
                                   categoryID: record.categoryID, poster: nil, model: model)
                reload()
            }
        }
    }

    private func badge(_ text: String, red: Bool = false) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(red ? AnyShapeStyle(TVTheme.accentFill) : AnyShapeStyle(Color.black.opacity(0.7)))
            .foregroundStyle(red ? TVTheme.onAccent : .white)
            .clipShape(Capsule())
            .padding(12)
    }

    private func play(_ record: TVFavoriteRecord) {
        notice = ""
        playingKind = record.kind
        if record.kind == "series" {
            let seriesItem = SeriesItem(id: record.itemID, name: record.name,
                                        poster: TVFavorites.poster(record, model: model),
                                        providerID: record.providerID)
            let seriesStore = SeriesStore(model: model)
            guard seriesStore.provider(for: seriesItem).kind == .xtream else {
                notice = "TV Shows requires an Xtream Codes provider."
                return
            }
            detailSeries = TVSeriesDetailRequest(series: seriesItem, store: seriesStore)
            showingSeriesDetail = true
            return
        }
        let kind: LibraryKind = record.kind == "live" ? .live : .movies
        var item = CatalogItem(
            id: record.itemID,
            name: record.name,
            kind: kind,
            fileExtension: record.ext,
            poster: TVFavorites.poster(record, model: model), categoryID: record.categoryID,
            providerID: record.providerID
        )
        Task {
            connecting = true; defer { connecting = false }
            let scope = model.preferenceKey
            do {
                let fresh = try await model.resolve(item)
                guard scope == model.preferenceKey else { return }
                if kind == .movies { detailItem = fresh; showingDetail = true }
                else { playing = fresh }
            } catch { if scope == model.preferenceKey { notice = error.localizedDescription } }
        }
    }
}

// TVSeriesDetailView is declared in TVShowsView.swift; this wrapper carries
// the series plus a store into the full-screen cover.
struct TVSeriesDetailRequest: Identifiable {
    var id: String { series.id }
    let series: SeriesItem
    let store: SeriesStore
}
