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
    @State private var query = ""
    @State private var searchItems: [SeriesItem] = []
    @State private var searching = false
    @State private var searchProgress = ""
    @State private var searchNotice = ""
    @State private var searchRetry = 0
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchingCatalog: Bool { trimmedQuery.count >= 2 }
    private var searchMatches: [SeriesItem] {
        SeriesSearchScope.matching(searchItems, query: trimmedQuery, categories: store.categories, preferences: model.preferences)
    }

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
                selectedCategory = model.preferences.browseCategories(store.categories, section: .series).first?.id ?? ""
            }
            .task(id: selectedCategory) {
                guard !selectedCategory.isEmpty else { return }
                visibleCount = 60
                await store.loadSeries(categoryID: selectedCategory)
            }
            .task(id: "\(model.libraryRevision)-\(searchRetry)-\(searchingCatalog)") {
                guard searchingCatalog else { searchItems = []; searchProgress = ""; searchNotice = ""; return }
                searching = true
                searchNotice = ""
                defer { searching = false }
                let items = await store.loadAllSeries { items, progress in
                    guard !Task.isCancelled else { return }
                    searchItems = items
                    searchProgress = progress
                }
                guard !Task.isCancelled else { return }
                searchItems = items
                searchProgress = ""
                searchNotice = store.searchNotice
            }
            .onChange(of: query) { _, _ in visibleCount = 60 }
    }

    private func openSeries(_ series: SeriesItem) {
        selectedSeries = series
        showingSeriesDetail = true
    }

    private func seriesCard(_ item: SeriesItem) -> some View {
        Button { openSeries(item) } label: {
            VStack(alignment: .leading, spacing: 10) {
                TVSeriesPoster(series: item)
                TVFocusTitle(title: model.preferences.seriesTitle(item))
                    .font(.headline)
                    .lineLimit(2)
                    .frame(width: 200, alignment: .leading)
            }
        }
        .buttonStyle(TVCardButtonStyle())
        .contextMenu {
            Button(TVFavorites.contains(id: item.id, kind: "series", providerID: item.providerID, model: model) ? "Remove from Saved" : "Save to Favorites") { TVFavorites.toggleSeries(item, model: model) }
        }
    }

    @ViewBuilder private var content: some View {

        if let reason = store.unavailableReason {
            Text(reason)
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tvLanding(for: .shows)

        } else if store.loading && store.categories.isEmpty {
            ProgressView("Loading TV shows…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tvLanding(for: .shows)

        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("TV Shows")
                        .font(.largeTitle.bold())
                        .padding(.top, 40)
                        .tvLanding(for: .shows, when: store.categories.isEmpty)

                    TextField("Search all TV shows", text: $query)
                        .font(.system(size: 26))
                        .frame(maxWidth: 720, minHeight: 64)
                        .focused($searchFocused)
                        .tvContentEntry()
                        .accessibilityLabel("Search all TV shows")
                    Text(searchingCatalog ? "Searching every TV show category." : "Select the search field to look across every category.")
                        .font(.system(size: 20))
                        .foregroundStyle(TVTheme.muted)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(Array(model.preferences.browseCategories(store.categories, section: .series).enumerated()), id: \.element.id) { index, category in
                                let button = Button { selectedCategory = category.id } label: {
                                    Text(category.name)
                                        .font(.headline)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 14)
                                }
                                .buttonStyle(.bordered)
                                .tint(selectedCategory == category.id ? TVTheme.red : TVTheme.muted)
                                if index == 0 {
                                    TVEntryControl(section: .shows) { button }
                                } else {
                                    button
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    if !trimmedQuery.isEmpty && !searchingCatalog {
                        Text("Enter at least two characters to search every TV show category.")
                            .foregroundStyle(TVTheme.muted)
                    } else if searchingCatalog {
                        if searching { ProgressView(searchProgress.isEmpty ? "Searching TV shows…" : "Searching TV shows: \(searchProgress)") }
                        if !searchNotice.isEmpty {
                            Text(searchNotice).foregroundStyle(TVTheme.muted)
                            Button("Retry TV show search") { searchRetry += 1 }.buttonStyle(TVCardButtonStyle())
                        }
                        if searchMatches.isEmpty && !(searching && searchItems.isEmpty) {
                            Text("No matching TV shows.").foregroundStyle(TVTheme.muted)
                        } else if !searchMatches.isEmpty {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 220), spacing: 28)],
                                spacing: 32
                            ) {
                                ForEach(Array(searchMatches.prefix(visibleCount)), id: \.scopedID) { item in
                                    seriesCard(item)
                                }
                            }
                            if searchMatches.count > visibleCount {
                                Button("Show more") { visibleCount += 60 }.buttonStyle(.bordered)
                            }
                            Text("\(searchMatches.count) shows")
                                .font(.caption)
                                .foregroundStyle(TVTheme.muted)
                        }
                    } else if store.loading {
                        ProgressView("Loading…")
                    } else if !store.error.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.error).foregroundStyle(TVTheme.muted)
                            Button("Retry") { Task {
                                if store.categories.isEmpty {
                                    await store.loadCategories()
                                    selectedCategory = model.preferences.browseCategories(store.categories, section: .series).first?.id ?? ""
                                } else { await store.loadSeries(categoryID: selectedCategory) }
                            } }
                                .buttonStyle(TVCardButtonStyle())
                        }
                    } else if store.series.isEmpty {
                        Text("No shows in this category.").foregroundStyle(TVTheme.muted)
                    } else {
                        if let hero = store.series.first {
                            TVHeroBanner(title: model.preferences.seriesTitle(hero), subtitle: PosterCaption.series(year: hero.year), badge: "FEATURED SHOW", poster: hero.poster, posterKind: .movies) { openSeries(hero) }
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220), spacing: 28)],
                            spacing: 32
                        ) {
                            ForEach(Array(store.series.prefix(visibleCount)), id: \.scopedID) { item in
                                seriesCard(item)
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
            let detail = await store.loadDetail(series: series)
            seasons = detail.seasons
            episodes = detail.episodes
            selectedSeason = seasons.first?.number ?? 0
        }
        .fullScreenCover(item: $playing) { item in
            DirectPlayerView(item: item, provider: model.provider(for: item), startSeconds: model.preferences.progress["series-" + item.id]?.seconds ?? 0, progressID: "series-" + item.id)
        }
    }

    private func play(_ episode: SeriesEpisode) {
        do {
            let owner = store.provider(for: series)
            let url = try SeriesStore.seriesStreamURL(
                provider: owner,
                episodeID: episode.id,
                ext: episode.ext
            )
            var item = CatalogItem(
                id: episode.id,
                name: "\(series.name) · S\(selectedSeason) E\(episode.number) — \(episode.title)",
                kind: .movies,
                fileExtension: episode.ext,
                poster: series.poster,
                providerID: series.providerID
            )
            item.playbackURL = url
            playing = item
        } catch {
            // Leave the detail screen up; the error surfaces on retry.
        }
    }
}

// Search opens one title, then keeps each provider entry as a selectable
// version. Country/language badges describe provider labels, not audio analysis.
struct TVSeriesVersionsView: View {
    let group: SeriesSearchGroup
    @ObservedObject var store: SeriesStore
    var loading = false
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SeriesItem?
    @State private var showingDetail = false
    @FocusState private var focusedVersion: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                    Spacer()
                }.focusSection()
                Text(group.title).font(.largeTitle.bold())
                Text("Choose a version").font(.title2)
                Text("US and English versions first. Choose an entry to see its seasons and episodes.")
                    .foregroundStyle(TVTheme.muted)
                if loading { ProgressView("Checking other available versions…") }
                ForEach(group.variants, id: \.scopedID) { item in
                    Button {
                        selected = item
                        showingDetail = true
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(SeriesSearchGrouping.label(item, categories: store.categories)).font(.title3.bold())
                            Text(item.name).font(.headline)
                            let category = store.categories.first { $0.id == item.categoryID }?.name ?? ""
                            let provider = store.provider(for: item).name
                            Text([category, provider].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(TVTheme.muted)
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TVTheme.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(TVCardButtonStyle())
                    .focused($focusedVersion, equals: item.scopedID)
                    .accessibilityIdentifier("series-version-\(item.scopedID)")
                }
            }.padding(60)
        }
        .background { StreamBackdrop() }
        .foregroundStyle(TVTheme.text)
        .defaultFocus($focusedVersion, group.preferred.scopedID)
        .navigationDestination(isPresented: $showingDetail) {
            if let selected { TVSeriesDetailView(series: selected, store: store) }
        }
    }
}
