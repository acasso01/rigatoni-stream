import SwiftUI

// Home tab: a warm "Welcome back" greeting and a "Last watched" / Continue
// Watching rail. Playback URLs are rebuilt from the provider at play time
// (direct URLs via Provider, gateway via opaque tickets); nothing secret is
// stored. Series episodes need a direct provider connection.
struct TVHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var watched: [TVWatchedRecord] = []
    @State private var playing: CatalogItem?
    @State private var playingKind: String?
    @State private var notice = ""

    private var greetingName: String? {
        model.account.session?.user.email?
            .split(separator: "@").first
            .map(String.init)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(greetingName.map { "Welcome back, \($0)" } ?? "Welcome back")
                        .font(.system(size: 76, weight: .bold))
                    Text("Pick up right where you left off.")
                        .font(.title3)
                        .foregroundStyle(TVTheme.muted)
                }
                .padding(.top, 90)

                VStack(alignment: .leading, spacing: 28) {
                    Text("Last watched")
                        .font(.system(size: 40, weight: .bold))

                    if !model.providerReady {
                        Text("Save your provider in Settings to start watching.")
                            .font(.title3)
                            .foregroundStyle(TVTheme.muted)
                    } else if watched.isEmpty {
                        Text("Nothing here yet — play something and it will show up here.")
                            .font(.title3)
                            .foregroundStyle(TVTheme.muted)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 32) {
                                ForEach(watched) { record in
                                    lastWatchedCard(record)
                                }
                            }
                            .padding(.vertical, 16)
                        }
                    }
                }

                if !notice.isEmpty {
                    Text(notice).foregroundStyle(TVTheme.red)
                }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 80)
        }
        .background(TVTheme.background)
        .foregroundStyle(TVTheme.text)
        .onAppear { reload() }
        .fullScreenCover(item: $playing) { item in
            TVPlayerView(item: item, provider: model.provider, lastWatchedKind: playingKind)
        }
    }

    private func reload() {
        notice = ""
        watched = TVLastWatched.items(provider: model.provider)
    }

    private func lastWatchedCard(_ record: TVWatchedRecord) -> some View {
        let isLive = record.kind == "live"
        let width: CGFloat = isLive ? 300 : 220
        let height: CGFloat = isLive ? 170 : 330
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
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))

                    if record.kind == "series" {
                        badge("TV SHOW")
                    } else if isLive {
                        badge("LIVE", red: true)
                    }
                }
                Text(record.name)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.card)
    }

    private func badge(_ text: String, red: Bool = false) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(red ? TVTheme.red : Color.black.opacity(0.7))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .padding(12)
    }

    private func play(_ record: TVWatchedRecord) {
        notice = ""
        playingKind = record.kind
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
                guard record.kind != "series" else {
                    notice = "That episode needs a direct provider connection."
                    return
                }
                item.playbackURL = try model.gatewayPlaybackURL(id: record.itemID, kind: kind)
            } else if record.kind == "series" {
                item.playbackURL = try TVSeriesStore.seriesStreamURL(
                    provider: model.provider,
                    episodeID: record.itemID,
                    ext: record.ext
                )
            }
            // Live/movie on a direct provider: TVPlayerView resolves the
            // stream URL itself via Provider.streamURL(item).
            playing = item
        } catch {
            notice = error.localizedDescription
        }
    }
}
