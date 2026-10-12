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
    @State private var notice = ""

    var body: some View {
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
        .background(TVTheme.background)
        .foregroundStyle(TVTheme.text)
        .onAppear { reload() }
        .fullScreenCover(item: $playing) { item in
            TVPlayerView(item: item, provider: model.provider, lastWatchedKind: playingKind)
        }
        .fullScreenCover(item: $detailSeries) { request in
            TVSeriesDetailView(series: request.series, store: request.store)
                .environmentObject(model)
        }
    }

    private func reload() {
        notice = ""
        favorites = TVFavorites.items(provider: model.provider)
    }

    private func savedCard(_ record: TVFavoriteRecord) -> some View {
        let isLive = record.kind == "live"
        return Button { play(record) } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    ZStack {
                        TVTheme.card
                        if let url = record.poster.flatMap(URL.init(string:)) {
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
                Text(record.name)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(width: 240, alignment: .leading)
            }
        }
        .buttonStyle(.card)
        .contextMenu {
            Button("Remove from Saved") {
                TVFavorites.toggle(id: record.itemID, name: record.name,
                                   kind: record.kind, ext: record.ext,
                                   poster: record.poster, provider: model.provider)
                reload()
            }
        }
    }

    private func badge(_ text: String, red: Bool = false) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(red ? TVTheme.accent : Color.black.opacity(0.7))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .padding(12)
    }

    private func play(_ record: TVFavoriteRecord) {
        notice = ""
        playingKind = record.kind
        if record.kind == "series" {
            guard !model.provider.requiresGateway else {
                notice = "That show needs a direct provider connection."
                return
            }
            let store = TVSeriesStore(model: model)
            detailSeries = TVSeriesDetailRequest(
                series: TVSeries(id: record.itemID, name: record.name,
                                 poster: record.poster.flatMap(URL.init(string:))),
                store: store)
            return
        }
        let kind: LibraryKind = record.kind == "live" ? .live : .movies
        var item = CatalogItem(
            id: record.itemID,
            name: record.name,
            kind: kind,
            fileExtension: record.ext,
            poster: record.poster.flatMap(URL.init(string:))
        )
        do {
            if model.provider.requiresGateway {
                item.playbackURL = try model.gatewayPlaybackURL(id: record.itemID, kind: kind)
            }
            playing = item
        } catch {
            notice = error.localizedDescription
        }
    }
}

// TVSeriesDetailView is declared in TVShowsView.swift; this wrapper carries
// the series plus a store into the full-screen cover.
struct TVSeriesDetailRequest: Identifiable {
    var id: String { series.id }
    let series: TVSeries
    let store: TVSeriesStore
}
