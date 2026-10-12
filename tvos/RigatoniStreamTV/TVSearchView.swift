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
    @State private var selectedSeries: SeriesItem?
    @State private var limit = 60
    @State private var retry = 0
    // The search field mounts synchronously, so focusing it on appear is
    // deterministic. Selecting it opens the tvOS keyboard.
    @FocusState private var fieldFocused: Bool
    private var hasQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                StreamHeading(title: "Search", subtitle: "Movies, live channels and TV shows. Every category. One place.")
                VStack(alignment: .leading, spacing: 24) {
                    TextField("Search movies, Live TV and TV shows", text: $query)
                        .font(.system(size: 26))
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .focused($fieldFocused)
                        .accessibilityLabel("Search movies, live TV and TV shows")
                    Text("Select the search field to type with your remote or iPhone.")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                    Picker("Search in", selection: $filter) {
                        Text("All").tag("all")
                        Text("Movies").tag(LibraryKind.movies.rawValue)
                        Text("Live TV").tag(LibraryKind.live.rawValue)
                        Text("TV Shows").tag("series")
                    }.pickerStyle(.segmented).frame(maxWidth: 580)
                }
                .onAppear { fieldFocused = true }
                if !hasQuery {
                    Label("Enter at least two characters to explore your library", systemImage: "sparkle.magnifyingglass")
                        .foregroundStyle(.secondary).padding(36).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                } else {
                    ForEach(LibraryKind.allCases) { kind in
                        if let progress = catalog.progress[kind] { ProgressView("\(kind.title): \(progress)") }
                    }
                    ForEach(notices, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    if !notices.isEmpty { Button("Retry unavailable catalogs") { retry += 1 } }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 32)], alignment: .leading, spacing: 36) {
                        ForEach(Array(results.prefix(limit))) { hit in
                            Button { playing = hit.item } label: {
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
                        let seriesMatches = allSeries.filter { $0.name.localizedCaseInsensitiveContains(query) }
                        if !seriesMatches.isEmpty {
                            Text("TV Shows").font(.title2.bold()).padding(.top, 12)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 32)], alignment: .leading, spacing: 36) {
                                ForEach(Array(seriesMatches.prefix(limit))) { series in
                                    Button { selectedSeries = series } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            ProviderPoster(url: series.poster, kind: .movies)
                                                .frame(width: 200, height: 300)
                                                .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
                                            Text(series.name).font(.headline).lineLimit(2)
                                            Label("TV Show", systemImage: "play.tv")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.buttonStyle(TVCardButtonStyle())
                                }
                            }.padding(.vertical, 20)
                        }
                    }
                    if catalog.progress.isEmpty && results.isEmpty {
                        Text("No matching titles in the loaded catalogs.").foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 64).padding(.vertical, 40)
        }
        .background { StreamBackdrop() }
        .task(id: "\(hasQuery)-\(model.libraryRevision)-\(retry)") {
            guard hasQuery, model.providerReady else { return }
            notices = []
            async let movies: Void = load(.movies)
            async let live: Void = load(.live)
            async let series: Void = loadSeries()
            _ = await (movies, live, series)
        }
        .task(id: "\(query)-\(filter)-\(catalog.revision)-\(model.libraryRevision)") {
            limit = 60
            guard hasQuery else { results = []; return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let snapshot = LibraryKind.allCases.flatMap { catalog.searchable[$0] ?? [] }.filter(model.preferences.visible)
            let term = query; let choice = filter
            let worker = Task.detached(priority: .userInitiated) { UnifiedSearch.matches(snapshot, query: term, filter: choice) }
            let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }; results = found
        }
        .fullScreenCover(item: $playing) {
            CatalogDestination(item: $0, channels: catalog.searchable[.live] ?? [])
        }
        .fullScreenCover(item: $selectedSeries) { series in
            if let store = seriesStore { TVSeriesDetailView(series: series, store: store) }
        }
    }
    private func load(_ kind: LibraryKind) async {
        do {
            let result = try await catalog.loadAll(kind: kind, model: model)
            if !Task.isCancelled && !result.notice.isEmpty { notices.append("\(kind.title): \(result.notice)") }
        } catch { if !Task.isCancelled { notices.append("\(kind.title): \(error.localizedDescription)") } }
    }
    private func loadSeries() async {
        if seriesStore == nil { seriesStore = SeriesStore(model: model) }
        guard let store = seriesStore else { return }
        let items = await store.loadAllSeries()
        guard !Task.isCancelled else { return }
        allSeries = items
    }
}
