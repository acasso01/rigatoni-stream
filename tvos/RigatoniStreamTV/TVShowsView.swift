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
    @State private var selectedGroup: SeriesSearchGroup?
    @State private var showingVersions = false
    @State private var allSeries: [SeriesItem] = []
    @State private var allGroups: [SeriesSearchGroup] = []
    @State private var allLoading = false
    @State private var allProgress = ""
    @State private var visibleCount = 60
    @State private var query = ""
    @State private var searchItems: [SeriesItem] = []
    @State private var searchGroups: [SeriesSearchGroup] = []
    @State private var searching = false
    @State private var searchProgress = ""
    @State private var searchNotice = ""
    @State private var searchRetry = 0
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchingCatalog: Bool { trimmedQuery.count >= 2 }
    private let allCategoriesID = "__all_enabled_series_categories__"
    private let recentCategoriesID = "__recent_series_categories__"
    private var searchMatches: [SeriesSearchGroup] { searchGroups }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(isPresented: $showingSeriesDetail) {
                    if let series = selectedSeries { TVSeriesDetailView(series: series, store: store) }
                }
                .navigationDestination(isPresented: $showingVersions) {
                    if let selectedGroup { TVSeriesDetailView(series: selectedGroup.preferred, store: store, variants: selectedGroup.variants, groupID: selectedGroup.id) }
                }
        }
            .task(id: model.libraryRevision) {
                selectedCategory = ""
                await store.loadCategories()
                guard !Task.isCancelled else { return }
                selectedCategory = allCategoriesID
            }
            .task(id: selectedCategory) {
                guard !selectedCategory.isEmpty else { return }
                visibleCount = 60
                if selectedCategory == allCategoriesID || selectedCategory == recentCategoriesID {
                    allLoading = true
                    allProgress = ""
                    defer { if !Task.isCancelled { allLoading = false } }
                    let loaded = await store.loadPreviewSeries(categoryLimit: 3) { items, progress in
                        guard !Task.isCancelled else { return }
                        allSeries = items
                        allProgress = progress
                    }
                    guard !Task.isCancelled else { return }
                    allSeries = loaded
                } else {
                    await store.loadSeries(categoryID: selectedCategory)
                }
            }
            .task(id: "\(model.libraryRevision)-\(searchRetry)-\(trimmedQuery)") {
                guard searchingCatalog else { searchItems = []; searchProgress = ""; searchNotice = ""; return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !Task.isCancelled else { return }
                searching = true
                searchNotice = ""
                defer { searching = false }
                let term = trimmedQuery
                let items = await store.searchSeries(term) { items, progress in
                    guard !Task.isCancelled else { return }
                    searchItems = items
                    searchProgress = progress
                }
                guard !Task.isCancelled else { return }
                searchItems = items
                searchProgress = ""
                searchNotice = store.searchNotice
            }
            .task(id: "\(trimmedQuery)-\(searchItems.count)-\(model.libraryRevision)") {
                guard searchingCatalog, !searchItems.isEmpty else { searchGroups = []; return }
                let term = trimmedQuery
                let items = searchItems
                let categories = store.categories
                let preferences = model.preferences
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                let worker = Task.detached(priority: .userInitiated) {
                    SeriesSearchGrouping.matches(items, query: term, categories: categories, preferences: preferences)
                }
                let groups = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                searchGroups = groups
            }
            .task(id: "all-groups-\(allSeries.count)-\(model.libraryRevision)") {
                guard !allSeries.isEmpty else { allGroups = []; return }
                let items = allSeries
                let categories = store.categories
                let preferences = model.preferences
                let worker = Task.detached(priority: .userInitiated) {
                    SeriesSearchGrouping.groups(items, categories: categories, preferences: preferences)
                }
                let groups = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                allGroups = groups
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

    private func groupCard(_ group: SeriesSearchGroup) -> some View {
        Button {
            selectedGroup = group
            showingVersions = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                TVSeriesPoster(series: group.preferred)
                TVFocusTitle(title: group.title).font(.headline).lineLimit(2)
                    .frame(width: 200, alignment: .leading)
                if !group.year.isEmpty { Text(group.year).font(.caption).foregroundStyle(TVTheme.muted) }
                if group.variants.count > 1 {
                    Label("\(group.variants.count) sources", systemImage: "play.tv").font(.caption).foregroundStyle(TVTheme.muted)
                }
            }
        }
        .buttonStyle(TVCardButtonStyle())
        .accessibilityIdentifier("series-group-\(group.id)")
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
            HStack(alignment: .top, spacing: 28) {
                categorySidebar
                    .frame(width: 350)
                    .focusSection()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Text(searchingCatalog ? "Search TV Shows" : selectedCategory == recentCategoriesID ? "Recently Added" : "TV Shows")
                            .font(.largeTitle.bold()).padding(.top, 28)
                        TextField("Search all TV shows", text: $query)
                            .font(.system(size: 26)).frame(maxWidth: 720, minHeight: 64)
                            .focused($searchFocused).tvContentEntry()
                            .accessibilityLabel("Search all TV shows")
                        Text(searchingCatalog ? "Searching every enabled TV show category." : "Browse a category or search across all enabled categories.")
                            .font(.system(size: 20)).foregroundStyle(TVTheme.muted)

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
                                ForEach(Array(searchMatches.prefix(visibleCount))) { group in
                                    groupCard(group)
                                }
                            }
                            if searchMatches.count > visibleCount {
                                Button("Show more") { visibleCount += 60 }.buttonStyle(.bordered)
                            }
                            Text("\(searchMatches.count) shows")
                                .font(.caption)
                                .foregroundStyle(TVTheme.muted)
                        }
                    } else if selectedCategory == allCategoriesID || selectedCategory == recentCategoriesID {
                        TVHistoryRail(title: "Continue Watching", onlyInProgress: true, hidesWhenEmpty: true)
                        if allLoading && allGroups.isEmpty {
                            ProgressView(allProgress.isEmpty ? "Loading a quick preview…" : allProgress)
                        }
                        let latest = allGroups.sorted { $0.preferred.added > $1.preferred.added }
                        let popular = allGroups.sorted { $0.preferred.rating > $1.preferred.rating }
                        if selectedCategory == allCategoriesID {
                            groupShelf("Popular Shows", groups: popular)
                            groupShelf("Latest Releases", groups: latest)
                        } else if !latest.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 28)], spacing: 32) {
                                ForEach(Array(latest.prefix(visibleCount))) { group in groupCard(group) }
                            }
                            if latest.count > visibleCount { Button("Show more") { visibleCount += 60 }.buttonStyle(.bordered) }
                        }
                        if allGroups.isEmpty && !allLoading {
                            Text("No shows found in the enabled categories.").foregroundStyle(TVTheme.muted)
                        }
                        if allLoading && !allGroups.isEmpty {
                            Text("Updating preview… \(allProgress)").font(.caption).foregroundStyle(TVTheme.muted)
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
                    .padding(.horizontal, 34).padding(.bottom, 50)
                }
                .focusSection()
            }
            .padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 30)
            .foregroundStyle(TVTheme.text)
            .background { StreamBackdrop() }

        }
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TV Shows").font(.title2.bold()).padding(.horizontal, 20).padding(.top, 20)
            Text("LIBRARY").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(TVTheme.muted).padding(.horizontal, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    TVEntryControl(section: .shows) {
                        sidebarButton(id: allCategoriesID, title: "All Shows", icon: "square.stack")
                    }
                    sidebarButton(id: recentCategoriesID, title: "Recently Added", icon: "clock")
                    ForEach(model.preferences.browseCategories(store.categories, section: .series)) { category in
                        sidebarButton(id: category.id, title: category.name, icon: "folder")
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(TVTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private func sidebarButton(id: String, title: String, icon: String) -> some View {
        let selected = selectedCategory == id
        return Button { selectedCategory = id } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 18, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .padding(.horizontal, 12)
        }
        .buttonStyle(TVCatalogRowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func groupShelf(_ title: String, groups: [SeriesSearchGroup]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            if groups.isEmpty {
                Text("Loading from enabled categories…").font(.callout).foregroundStyle(TVTheme.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(Array(groups.prefix(20))) { group in groupCard(group) }
                    }.padding(.vertical, 16).padding(.horizontal, 8)
                }
            }
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
    let variants: [SeriesItem]
    let groupID: String
    @ObservedObject var store: SeriesStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var seasons: [SeriesSeason] = []
    @State private var episodes: [Int: [UnifiedSeriesEpisode]] = [:]
    @State private var details: SeriesShowDetails?
    @State private var selectedSeason = 0
    @State private var loading = true
    @State private var sourceProgress = ""
    @State private var playing: CatalogItem?
    @State private var selectedEpisode: UnifiedSeriesEpisode?
    @State private var showingSources = false
    @State private var chosenSource: SeriesEpisodeSource?
    @State private var isFavorite = false
    @State private var isWatched = false
    @State private var activeProgressID = ""

    init(series: SeriesItem, store: SeriesStore, variants: [SeriesItem]? = nil, groupID: String? = nil) {
        self.series = series
        self.store = store
        self.variants = variants ?? [series]
        self.groupID = groupID ?? SeriesSearchGrouping.identityKey(series)
    }

    private var seasonEpisodes: [UnifiedSeriesEpisode] {
        episodes[selectedSeason] ?? []
    }

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                ZStack(alignment: .bottomLeading) {
                    if let backdrop = details?.backdrop ?? series.poster {
                        ProviderPoster(url: backdrop, kind: .live)
                            .frame(height: 310)
                            .clipped()
                            .overlay(LinearGradient(colors: [.clear, TVTheme.background.opacity(0.95)], startPoint: .center, endPoint: .bottom))
                    } else { TVTheme.background.frame(height: 310) }
                    HStack(alignment: .bottom, spacing: 28) {
                        TVSeriesPoster(series: series).frame(width: 168, height: 252)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.preferences.seriesTitle(series)).font(.system(size: 48, weight: .bold)).lineLimit(2)
                            Text([details?.year.isEmpty == false ? details?.year : series.year, details?.genre, details?.contentRating, details?.rating].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.title3).foregroundStyle(TVTheme.muted)
                            if let synopsis = details?.synopsis, !synopsis.isEmpty {
                                Text(synopsis).font(.body).lineLimit(3).foregroundStyle(TVTheme.text)
                            }
                            HStack {
                                Button(isFavorite ? "Remove Favorite" : "Add to Favorites") {
                                    isFavorite = TVFavorites.toggleSeries(series, model: model)
                                }
                                Button(isWatched ? "Mark Unwatched" : "Mark Watched") {
                                    isWatched.toggle()
                                    TVFavorites.setSeriesWatched(series, watched: isWatched, model: model)
                                }
                            }.buttonStyle(TVCardButtonStyle())
                        }.padding(.bottom, 8)
                        Spacer()
                    }.padding(.horizontal, 44).padding(.bottom, 12)
                }
                .frame(height: 310)

                if loading {
                    ProgressView(sourceProgress.isEmpty ? "Loading seasons and available sources…" : "Loading available sources… \(sourceProgress)")
                } else if seasons.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(store.detailError.isEmpty ? "No episodes found for this show." : store.detailError).foregroundStyle(TVTheme.muted)
                        if !sourceProgress.isEmpty {
                            ProgressView(sourceProgress)
                        }
                    }
                } else {
                    if !sourceProgress.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(sourceProgress).font(.caption).foregroundStyle(TVTheme.muted)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(seasons) { season in
                                Button { selectedSeason = season.number } label: {
                                    Text(season.name).font(.headline).padding(.horizontal, 20).padding(.vertical, 12)
                                }.buttonStyle(.bordered).tint(selectedSeason == season.number ? TVTheme.red : TVTheme.muted)
                            }
                        }.padding(.vertical, 6)
                    }
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(seasonEpisodes) { episode in
                                let progress = episode.sources.compactMap { model.preferences.progress[$0.progressID] }.first
                                Button {
                                        chooseEpisode(episode)
                                } label: {
                                    HStack(spacing: 20) {
                                        if let thumbnail = episode.sources.first?.episode.thumbnail {
                                            ProviderPoster(url: thumbnail, kind: .live)
                                                .frame(width: 150, height: 84)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        }
                                        Text("E\(episode.number)").font(.headline).foregroundStyle(TVTheme.red).frame(width: 56, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 4) {
                                            TVFocusTitle(title: episode.title).font(.title3).lineLimit(1)
                                            let duration = episode.sources.first?.episode.durationSeconds ?? 0
                                            let runtime = duration > 0 ? "\(duration / 60) min" : ""
                                            Text([progress.map { "Resume from \($0.label)" } ?? (episode.sources.count > 1 ? "\(episode.sources.count) available sources" : "Play episode"), runtime].filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(TVTheme.muted)
                                            if let synopsis = episode.sources.first?.episode.synopsis, !synopsis.isEmpty {
                                                Text(synopsis).font(.caption2).lineLimit(2).foregroundStyle(TVTheme.muted)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(TVTheme.red)
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 14)
                                    .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(TVCardButtonStyle())
                            }
                        }.padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 48).padding(.bottom, 36)
            .foregroundStyle(TVTheme.text)
        }
        .task {
            loading = true
            isFavorite = TVFavorites.contains(id: series.id, kind: "series", providerID: series.providerID, model: model)
            isWatched = TVFavorites.isSeriesWatched(series, model: model)
            let loaded = await store.loadShowDetails(variants: variants) { completed, total in
                sourceProgress = "Loading show versions · \(completed) of \(total)"
            }
            guard !Task.isCancelled else { return }
            if let preferred = loaded.first(where: { $0.0.scopedID == series.scopedID })?.1 ?? loaded.first?.1 { details = preferred }
            mergeDetails(loaded, chooseInitialSeason: true)
            loading = false

            // All Shows is a quick preview of a few categories. Discover other
            // matching entries only after the detail screen is open so the
            // first screen stays fast while seasons from categories such as
            // Nordic can still be added here.
            sourceProgress = "Checking enabled categories…"
            let catalog = await store.loadAllSeries { _, progress in
                guard !Task.isCancelled else { return }
                sourceProgress = "Checking enabled categories · \(progress)"
            }
            guard !Task.isCancelled else { return }
            let related = SeriesSearchGrouping.relatedVariants(to: series, among: catalog)
            let loadedIDs = Set(loaded.map { $0.0.scopedID })
            let additional = related.filter { !loadedIDs.contains($0.scopedID) }
            if !additional.isEmpty {
                let extra = await store.loadShowDetails(variants: additional) { completed, total in
                    guard !Task.isCancelled else { return }
                    sourceProgress = "Loading more seasons and sources · \(completed) of \(total)"
                }
                guard !Task.isCancelled else { return }
                mergeDetails(loaded + extra, chooseInitialSeason: false)
            }
            sourceProgress = ""
        }
        .sheet(isPresented: $showingSources, onDismiss: {
            guard let chosenSource, let selectedEpisode else { return }
            play(chosenSource, episode: selectedEpisode)
            self.chosenSource = nil
        }) {
            if let selectedEpisode {
                TVSeriesSourcePicker(
                    episode: selectedEpisode,
                    sources: sourceOptions(selectedEpisode),
                    preferredID: preferredSourceID,
                    unavailable: sourceUnavailable,
                    label: sourceLabel
                ) { chosenSource = $0; showingSources = false }
            }
        }
        .fullScreenCover(item: $playing) { item in
            DirectPlayerView(item: item, provider: model.provider(for: item), startSeconds: model.preferences.progress[activeProgressID]?.seconds ?? 0, progressID: activeProgressID)
        }
    }

    private func mergeDetails(_ loaded: [(SeriesItem, SeriesShowDetails)], chooseInitialSeason: Bool) {
        var seenSeasons = Set<Int>()
        seasons = loaded.flatMap { $0.1.seasons }
            .filter { seenSeasons.insert($0.number).inserted }
            .sorted { $0.number < $1.number }
        episodes = SeriesEpisodeGrouping.merge(loaded)
        if chooseInitialSeason || !seasons.contains(where: { $0.number == selectedSeason }) {
            selectedSeason = seasons.first?.number ?? 0
        }
    }

    private func sourceLabel(_ source: SeriesEpisodeSource) -> String {
        let language = SeriesSearchGrouping.label(source.series, categories: store.categories)
        let provider = store.provider(for: source.series).name
        return [language, provider].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var preferredSourceID: String? { TVFavorites.preferredSeriesSource(groupID: groupID, model: model) }
    private var sourceUnavailable: Bool {
        guard let selectedEpisode, let preferredSourceID else { return false }
        return !selectedEpisode.sources.contains { $0.series.scopedID == preferredSourceID }
    }

    private func sourceOptions(_ episode: UnifiedSeriesEpisode) -> [SeriesEpisodeSource] {
        episode.sources.sorted {
            let lhsPreferred = $0.series.scopedID == preferredSourceID
            let rhsPreferred = $1.series.scopedID == preferredSourceID
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return sourceLabel($0).localizedStandardCompare(sourceLabel($1)) == .orderedAscending
        }
    }

    private func chooseEpisode(_ episode: UnifiedSeriesEpisode) {
        selectedEpisode = episode
        let preferredIsMissing = preferredSourceID.map { preferred in !episode.sources.contains { $0.series.scopedID == preferred } } ?? false
        if episode.sources.count > 1 || preferredIsMissing { showingSources = true }
        else if let source = episode.sources.first { play(source, episode: episode) }
    }

    private func play(_ source: SeriesEpisodeSource, episode: UnifiedSeriesEpisode) {
        do {
            let owner = store.provider(for: source.series)
            let url = try SeriesStore.seriesStreamURL(
                provider: owner,
                episodeID: source.episode.id,
                ext: source.episode.ext
            )
            var item = CatalogItem(
                id: source.episode.id,
                name: "\(series.name) · S\(selectedSeason) E\(episode.number) — \(episode.title)",
                kind: .movies,
                fileExtension: source.episode.ext,
                poster: source.series.poster,
                providerID: source.series.providerID
            )
            item.playbackURL = url
            activeProgressID = source.progressID
            TVFavorites.setPreferredSeriesSource(source.series.scopedID, groupID: groupID, model: model)
            playing = item
        } catch {
            // Leave the detail screen up; the error surfaces on retry.
        }
    }
}

private struct TVSeriesSourcePicker: View {
    let episode: UnifiedSeriesEpisode
    let sources: [SeriesEpisodeSource]
    let preferredID: String?
    let unavailable: Bool
    let label: (SeriesEpisodeSource) -> String
    let choose: (SeriesEpisodeSource) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(unavailable ? "Your saved source is unavailable. Choose another." : "Choose where to stream")
                        .font(.headline).foregroundStyle(TVTheme.muted).padding(.bottom, 8)
                    ForEach(sources) { source in
                        Button { choose(source) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("S\(episode.season) · E\(episode.number) — \(episode.title)")
                                    .font(.title3.weight(.semibold)).lineLimit(1)
                                Text(label(source)).font(.callout).foregroundStyle(TVTheme.muted).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.vertical, 15)
                            .background(source.series.scopedID == preferredID ? TVTheme.red.opacity(0.78) : TVTheme.panel,
                                        in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(TVCardButtonStyle())
                        .accessibilityIdentifier("series-source-\(source.id)")
                    }
                }.padding(28)
            }
            .background { StreamBackdrop() }
            .navigationTitle("Select Stream")
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
