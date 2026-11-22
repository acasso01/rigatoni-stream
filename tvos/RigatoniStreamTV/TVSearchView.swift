import SwiftUI

// Shared memory-only catalogs: one search across Movies and Live TV.
struct TVSearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var query = ""
    @State private var filter = "all"
    @State private var results: [SearchHit] = []
    @State private var notices: [String] = []
    @State private var playing: CatalogItem?
    @State private var seriesStore: SeriesStore?
    @State private var allSeries: [SeriesItem] = []
    @State private var seriesGroups: [SeriesSearchGroup] = []
    @State private var seriesDataRevision = 0
    @State private var groupedKey = ""
    @State private var selectedGroup: SeriesSearchGroup?
    @State private var showingVersions = false
    @State private var seriesLoading = false
    @State private var seriesNotice = ""
    @State private var seriesProgress = ""
    @State private var seriesComplete = false
    @State private var seriesRequest = UUID()
    @State private var completedLoadKey: String?
    @State private var limit = 60
    @State private var retry = 0
    // Detail screens push on a NavigationStack so the player's cover is a
    // single modal level (nested fullScreenCovers silently fail on tvOS).
    @State private var detailItem: CatalogItem?
    @State private var showingDetail = false
    @State private var detailSeries: SeriesItem?
    @State private var showingSeriesDetail = false
    // The search field mounts synchronously, so focusing it on appear is
    // deterministic. Selecting it opens the tvOS keyboard.
    @FocusState private var fieldFocused: Bool
    private var loadKey: String { "\(hasQuery)-\(filter)-\(model.libraryRevision)-\(retry)" }
    private var includesSeries: Bool { filter == "all" || filter == "series" }
    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasQuery: Bool { normalizedQuery.count >= 2 }
    private var groupingKey: String { "\(normalizedQuery)-\(seriesDataRevision)-\(model.libraryRevision)" }
    private var seriesMatches: [SeriesSearchGroup] { seriesGroups }

    var body: some View {
        NavigationStack {
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                StreamHeading(title: "Search", subtitle: "Movies, live channels and TV shows. Every category. One place.")
                VStack(alignment: .leading, spacing: 24) {
                    TVEntryControl(section: .search) {
                        TextField("Search movies, Live TV and TV shows", text: $query)
                            .font(.system(size: 26))
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .focused($fieldFocused)
                            .tvContentEntry()
                            .accessibilityLabel("Search movies, live TV and TV shows")
                    }
                    Text("Select the search field to type with your remote or iPhone.")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                    StreamOptionPicker(options: [("all", "All"), (LibraryKind.movies.rawValue, "Movies"), (LibraryKind.live.rawValue, "Live TV"), ("series", "TV Shows")], selection: $filter)
                        .frame(maxWidth: 580)
                        .focusSection()
                }
                .onAppear { fieldFocused = true }
                if !hasQuery {
                    Label("Enter at least two characters to explore your library", systemImage: "sparkle.magnifyingglass")
                        .foregroundStyle(.secondary).padding(36).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                } else {
                    ForEach(LibraryKind.allCases.filter { filter == "all" || $0.rawValue == filter }) { kind in
                        if let progress = catalog.progress[kind] { ProgressView("\(kind.title): \(progress)") }
                    }
                    ForEach(notices, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    if !notices.isEmpty { Button("Retry unavailable catalogs") { retry += 1 } }
                    if filter == "all" || filter == "series" {
                        if seriesLoading { ProgressView(seriesProgress.isEmpty ? "Loading TV shows…" : "Searching TV shows: \(seriesProgress)") }
                        if !seriesNotice.isEmpty {
                            Text("TV show search: \(seriesNotice)")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Retry TV show search") { retry += 1 }
                        }
                        if filter == "series", seriesComplete, groupedKey == groupingKey, !seriesLoading, seriesNotice.isEmpty, seriesMatches.isEmpty {
                            Text("No TV shows match “\(normalizedQuery)”. Check the selected Xtream Codes provider and try again.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 32)], alignment: .leading, spacing: 36) {
                        ForEach(Array(results.prefix(limit))) { hit in
                            Button { openResult(hit.item) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    TVCatalogCard(item: hit.item)
                                    Label(hit.item.kind.title, systemImage: hit.item.kind.symbol)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(TVCardButtonStyle()).contextMenu {
                                Button(TVFavorites.contains(item: hit.item, model: model) ? "Remove from Saved" : "Save to Favorites") { TVFavorites.toggle(item: hit.item, model: model) }
                            }
                        }
                    }.padding(.vertical, 20)
                    if results.count > limit { Button("More results") { limit += 60 } }
                    if filter == "all" || filter == "series" {
                        if !seriesMatches.isEmpty {
                            Text("TV Shows").font(.title2.bold()).padding(.top, 12)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 32)], alignment: .leading, spacing: 36) {
                                ForEach(Array(seriesMatches.prefix(limit))) { group in
                                    Button { openGroup(group) } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            ProviderPoster(url: group.preferred.poster, kind: .movies)
                                                .frame(width: 200, height: 300)
                                                .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
                                            Text(group.title).font(.headline).lineLimit(2)
                                            if !group.year.isEmpty { Text(group.year).font(.caption).foregroundStyle(.secondary) }
                                            Label(group.variants.count > 1 ? "\(group.variants.count) versions" : "TV Show", systemImage: "play.tv")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.buttonStyle(TVCardButtonStyle())
                                    .accessibilityIdentifier("series-group-\(group.id)")
                                }
                            }.padding(.vertical, 20)
                            .focusSection()
                            if seriesMatches.count > limit {
                                Button("More TV show results") { limit += 60 }
                            }
                        }
                    }
                    if filter != "series", completedLoadKey == loadKey, catalog.progress.isEmpty, results.isEmpty,
                       (!includesSeries || (seriesComplete && groupedKey == groupingKey && seriesMatches.isEmpty)), !seriesLoading, seriesNotice.isEmpty {
                        Text("No matching titles in the loaded catalogs.").foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 64).padding(.vertical, 40)
            .navigationDestination(isPresented: $showingDetail) {
                if let item = detailItem { MovieDetailView(item: item) }
            }
            .navigationDestination(isPresented: $showingVersions) {
                if let selectedGroup, let store = seriesStore {
                    let ids = Set(selectedGroup.variants.map(\.scopedID))
                    let group = seriesGroups.first { $0.id == selectedGroup.id }
                        ?? seriesGroups.first { $0.variants.contains { ids.contains($0.scopedID) } }
                        ?? selectedGroup
                    TVSeriesDetailView(series: group.preferred, store: store, variants: group.variants, groupID: group.id)
                }
            }
            .navigationDestination(isPresented: $showingSeriesDetail) {
                if let series = detailSeries, let store = seriesStore { TVSeriesDetailView(series: series, store: store) }
            }
            }
        }
        .background { StreamBackdrop() }
        .task(id: groupingKey) {
            let key = groupingKey
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let items = allSeries
            let categories = seriesStore?.categories ?? []
            let preferences = model.preferences
            let term = normalizedQuery
            let job = Task.detached(priority: .userInitiated) {
                SeriesSearchGrouping.matches(items, query: term, categories: categories, preferences: preferences)
            }
            let groups = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
            guard !Task.isCancelled else { return }
            seriesGroups = groups
            groupedKey = key
        }
        .task(id: loadKey) {
            completedLoadKey = nil
            guard hasQuery, model.providerReady else { return }
            let key = loadKey
            defer { if !Task.isCancelled, loadKey == key { completedLoadKey = key } }
            notices = []
            // Only load the catalogs the selected filter needs.
            let scope = filter
            if scope == "all" {
                async let movies: Void = load(.movies)
                async let live: Void = load(.live)
                async let series: Void = loadSeries()
                _ = await (movies, live, series)
            } else if scope == LibraryKind.movies.rawValue {
                await load(.movies)
            } else if scope == LibraryKind.live.rawValue {
                await load(.live)
            } else if scope == "series" {
                await loadSeries()
            }
        }
        .task(id: "\(query)-\(filter)-\(catalog.revision)-\(model.libraryRevision)") {
            limit = 60
            guard hasQuery else { results = []; return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let snapshot = LibraryKind.allCases.flatMap { kind in
                let categories = catalog.knownCategories(kind: kind)
                return (catalog.searchable[kind] ?? []).filter {
                    model.preferences.accepts($0, categories: categories)
                }
            }
            let term = normalizedQuery; let choice = filter
            let worker = Task.detached(priority: .userInitiated) { UnifiedSearch.matches(snapshot, query: term, filter: choice) }
            let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }; results = found
        }
        .fullScreenCover(item: $playing) {
            CatalogDestination(item: $0, channels: catalog.searchable[.live] ?? [])
        }
    }
    private func load(_ kind: LibraryKind) async {
        do {
            let result = try await catalog.loadAll(kind: kind, model: model)
            if !Task.isCancelled && !result.notice.isEmpty { notices.append("\(kind.title): \(result.notice)") }
        } catch { if !Task.isCancelled { notices.append("\(kind.title): \(error.localizedDescription)") } }
    }
    private func loadSeries() async {
        // Each request owns its store. A cancelled All search must not clear
        // the loading/results state of a newer TV Shows filter request.
        let request = UUID()
        seriesRequest = request
        let store = SeriesStore(model: model)
        seriesStore = store
        allSeries = []
        seriesGroups = []
        seriesDataRevision += 1
        seriesLoading = true
        seriesComplete = false
        seriesProgress = ""
        seriesNotice = ""
        defer { if seriesRequest == request { seriesLoading = false } }
        let items = await store.loadAllSeries { items, progress in
            guard !Task.isCancelled, seriesRequest == request else { return }
            allSeries = items
            seriesDataRevision += 1
            seriesProgress = progress
        }
        guard !Task.isCancelled, seriesRequest == request else { return }
        allSeries = items
        seriesDataRevision += 1
        seriesNotice = store.searchNotice
        seriesComplete = true
    }

    private func openResult(_ item: CatalogItem) {
        if item.kind == .movies { detailItem = item; showingDetail = true }
        else { playing = item }
    }

    private func openGroup(_ group: SeriesSearchGroup) {
        if group.variants.count == 1, !seriesLoading { openSeries(group.preferred) }
        else { selectedGroup = group; showingVersions = true }
    }

    private func openSeries(_ series: SeriesItem) {
        detailSeries = series
        showingSeriesDetail = true
    }
}
