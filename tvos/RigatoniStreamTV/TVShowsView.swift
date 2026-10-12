import SwiftUI

// MARK: - Series browser

struct TVShowsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: SeriesStore?
    var body: some View {
        Group {
            if let store { TVSeriesBrowser(store: store) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(TVTheme.background)
        .onAppear {
            if store == nil { store = SeriesStore(model: model) }
        }
    }

}

private struct TVSeriesBrowser: View {
    @ObservedObject var store: SeriesStore
    @EnvironmentObject private var model: AppModel
    @State private var selectedCategory = ""
    @State private var selectedSeries: SeriesItem?
    @State private var showingSeriesDetail = false
    @State private var visibleCount = 60

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(isPresented: $showingSeriesDetail) {
                    if let series = selectedSeries { TVSeriesDetailView(series: series, store: store) }
                }
        }
            .task(id: model.libraryRevision) {
                selectedCategory = ""
                await store.loadCategories()
                guard !Task.isCancelled else { return }
                selectedCategory = store.categories.first?.id ?? ""
            }
            .task(id: selectedCategory) {
                guard !selectedCategory.isEmpty else { return }
                visibleCount = 60
                await store.loadSeries(categoryID: selectedCategory)
            }
    }

    private func openSeries(_ series: SeriesItem) {
        selectedSeries = series
        showingSeriesDetail = true
    }

    @ViewBuilder private var content: some View {

        if let reason = store.unavailableReason {
            Text(reason)
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if store.loading && store.categories.isEmpty {
            ProgressView("Loading TV shows…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("TV Shows")
                        .font(.largeTitle.bold())
                        .padding(.top, 40)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(store.categories) { category in
                                Button { selectedCategory = category.id } label: {
                                    Text(category.name)
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

                    if store.loading {
                        ProgressView("Loading…")
                    } else if !store.error.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.error).foregroundStyle(TVTheme.muted)
                            Button("Retry") { Task {
                                if store.categories.isEmpty {
                                    await store.loadCategories()
                                    selectedCategory = store.categories.first?.id ?? ""
                                } else { await store.loadSeries(categoryID: selectedCategory) }
                            } }
                                .buttonStyle(TVCardButtonStyle())
                        }
                    } else if store.series.isEmpty {
                        Text("No shows in this category.").foregroundStyle(TVTheme.muted)
                    } else {
                        if let hero = store.series.first {
                            TVHeroBanner(title: hero.name, subtitle: "TV show", badge: "FEATURED SHOW", poster: hero.poster, posterKind: .movies) { openSeries(hero) }
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220), spacing: 28)],
                            spacing: 32
                        ) {
                            ForEach(Array(store.series.prefix(visibleCount))) { item in
                                Button { openSeries(item) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        TVSeriesPoster(series: item)
                                        TVFocusTitle(title: item.name)
                                            .font(.headline)
                                            .lineLimit(2)
                                            .frame(width: 200, alignment: .leading)
                                    }
                                }
                                .buttonStyle(TVCardButtonStyle())
                                .contextMenu {
                                    Button(TVFavorites.contains(id: item.id, kind: "series", model: model) ? "Remove from Saved" : "Save to Favorites") { TVFavorites.toggleSeries(item, model: model) }
                                }
                            }
                        }
                        if store.series.count > visibleCount {
                            Button("Show more") { visibleCount += 60 }.buttonStyle(.bordered)
                        }
                        Text("\(store.series.count) shows")
                            .font(.caption)
                            .foregroundStyle(TVTheme.muted)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 60)
            }
            .foregroundStyle(TVTheme.text)

        }
    }
}

private struct TVSeriesPoster: View {
    let series: SeriesItem

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let url = series.poster {
                ProviderPoster(url: url, kind: .movies)
            } else {
                Image(systemName: "play.tv")
                    .font(.largeTitle)
                    .foregroundStyle(TVTheme.muted)
            }
        }
        .frame(width: 200, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
    }
}

// MARK: - Series detail: seasons -> episodes -> player

struct TVSeriesDetailView: View {
    let series: SeriesItem
    @ObservedObject var store: SeriesStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var seasons: [SeriesSeason] = []
    @State private var episodes: [Int: [SeriesEpisode]] = [:]
    @State private var selectedSeason = 0
    @State private var loading = true
    @State private var playing: CatalogItem?

    private var seasonEpisodes: [SeriesEpisode] {
        episodes[selectedSeason] ?? []
    }

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()
            HStack(spacing: 48) {
                TVSeriesPoster(series: series)
                    .frame(width: 300, height: 450)

                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Button { dismiss() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(TVCardButtonStyle())
                        Spacer()
                    }
                    Text(series.name)
                        .font(.system(size: 56, weight: .bold))
                        .lineLimit(2)

                    if loading {
                        ProgressView("Loading episodes…")
                    } else if seasons.isEmpty {
                        Text(store.detailError.isEmpty ? "No episodes found for this show." : store.detailError)
                            .foregroundStyle(TVTheme.muted)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(seasons) { season in
                                    Button { selectedSeason = season.number } label: {
                                        Text(season.name)
                                            .font(.headline)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(selectedSeason == season.number ? TVTheme.red : TVTheme.muted)
                                }
                            }
                            .padding(.vertical, 6)
                        }

                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(seasonEpisodes) { episode in
                                    Button { play(episode) } label: {
                                        HStack(spacing: 20) {
                                            Text("E\(episode.number)")
                                                .font(.headline)
                                                .foregroundStyle(TVTheme.red)
                                                .frame(width: 56, alignment: .leading)
                                            TVFocusTitle(title: episode.title)
                                                .font(.title3)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 36))
                                                .foregroundStyle(TVTheme.red)
                                        }
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 14)
                                        .background(Color.white.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(TVCardButtonStyle())
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(64)
            .foregroundStyle(TVTheme.text)
        }
        .task {
            loading = true
            defer { loading = false }
            let detail = await store.loadDetail(seriesID: series.id)
            seasons = detail.seasons
            episodes = detail.episodes
            selectedSeason = seasons.first?.number ?? 0
        }
        .fullScreenCover(item: $playing) { item in
            DirectPlayerView(item: item, provider: model.provider, startSeconds: model.preferences.progress["series-" + item.id]?.seconds ?? 0, progressID: "series-" + item.id)
        }
    }

    private func play(_ episode: SeriesEpisode) {
        do {
            let url = try SeriesStore.seriesStreamURL(
                provider: model.provider,
                episodeID: episode.id,
                ext: episode.ext
            )
            var item = CatalogItem(
                id: episode.id,
                name: "\(series.name) · S\(selectedSeason) E\(episode.number) — \(episode.title)",
                kind: .movies,
                fileExtension: episode.ext,
                poster: series.poster
            )
            item.playbackURL = url
            playing = item
        } catch {
            // Leave the detail screen up; the error surfaces on retry.
        }
    }
}
