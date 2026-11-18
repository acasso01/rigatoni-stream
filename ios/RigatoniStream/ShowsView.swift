import SwiftUI

struct ShowsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: SeriesStore?

    var body: some View {
        NavigationStack {
            Group {
                if let store { ShowsBrowser(store: store) }
                else { ProgressView("Loading TV shows…") }
            }
            .navigationTitle("TV Shows").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("Provider settings")
                }
            }
        }
        .background { StreamBackdrop() }
        .onAppear { if store == nil { store = SeriesStore(model: model) } }
    }
}

private struct ShowsBrowser: View {
    @ObservedObject var store: SeriesStore
    @EnvironmentObject private var model: AppModel
    @State private var category = ""
    @State private var query = ""
    @State private var searchItems: [SeriesItem] = []
    @State private var searching = false
    @State private var searchProgress = ""
    @State private var searchNotice = ""
    @State private var visibleCount = 60
    @State private var retry = 0
    @State private var loadedRevision: Int?
    @State private var loadedRetry = -1
    @State private var loadedCategory = ""
    @AppStorage("rigatoni-appearance") private var appearance = "dark"

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchingCatalog: Bool { trimmedQuery.count >= 2 }
    private var visibleCategories: [CatalogCategory] {
        model.preferences.browseCategories(store.categories, section: .series)
    }
    private var matches: [SeriesItem] {
        guard searchingCatalog else { return store.series }
        return SeriesSearchScope.matching(searchItems, query: trimmedQuery, categories: store.categories, preferences: model.preferences)
    }

    @ViewBuilder private func showGrid(_ items: [SeriesItem], featured: Bool) -> some View {
        if featured, let first = items.first {
            NavigationLink { ShowDetailView(series: first, store: store) } label: {
                MobileHero(title: model.preferences.seriesTitle(first), poster: first.poster, badge: "TV SHOWS")
            }.buttonStyle(.plain).padding(.horizontal)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 20) {
            ForEach(Array(items.prefix(visibleCount)), id: \.scopedID) { series in
                NavigationLink { ShowDetailView(series: series, store: store) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        ProviderPoster(url: series.poster, kind: .movies).aspectRatio(2 / 3, contentMode: .fit)
                        Text(model.preferences.seriesTitle(series)).font(.subheadline.weight(.semibold)).lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(10)
                    }
                    .foregroundStyle(StreamTheme.text).background(StreamTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).contextMenu {
                    MobileSaveButton(record: SavedRecord(kind: "series", itemID: series.id, name: series.name, ext: "", categoryID: series.categoryID.isEmpty ? category : series.categoryID, addedAt: Date(), providerID: series.providerID))
                }
            }
        }.padding(.horizontal)
        if items.count > visibleCount { Button("Show more") { visibleCount += 60 }.padding() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search TV shows", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                if let reason = store.unavailableReason {
                    Text(reason).foregroundStyle(.secondary).padding()
                    Button("Provider settings") { model.settingsVisible = true }.padding(.horizontal)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(spacing: 10) {
                            ForEach(visibleCategories) { entry in
                                Button { category = entry.id } label: {
                                    Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        .padding(.horizontal, 18).frame(height: 54)
                                        .background(category == entry.id ? AnyShapeStyle(StreamTheme.accentFill) : AnyShapeStyle(StreamTheme.panel), in: Capsule())
                                        .foregroundStyle(category == entry.id ? StreamTheme.onAccent : StreamTheme.text)
                                }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                            }
                        }.padding(.horizontal).padding(.vertical, 8)
                    }.frame(height: 74).scrollClipDisabled()
                    if !trimmedQuery.isEmpty && !searchingCatalog {
                        Text("Enter at least two characters to search every TV show category.")
                            .foregroundStyle(.secondary).padding(.horizontal)
                    } else if searchingCatalog {
                        if searching { ProgressView(searchProgress.isEmpty ? "Searching TV shows…" : "Searching TV shows: \(searchProgress)").frame(maxWidth: .infinity).padding(30) }
                        if !searchNotice.isEmpty {
                            Text(searchNotice).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                            Button("Retry TV show search") { retry += 1 }.padding(.horizontal)
                        }
                        if matches.isEmpty && !(searching && searchItems.isEmpty) {
                            Text("No matching TV shows.").foregroundStyle(.secondary).padding()
                        } else if !matches.isEmpty {
                            showGrid(matches, featured: false)
                        }
                    } else if store.loading { ProgressView("Loading shows…").frame(maxWidth: .infinity).padding(30) }
                    else if !store.error.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.error).foregroundStyle(.secondary)
                            Button("Retry") { retry += 1 }
                        }.padding()
                    } else if matches.isEmpty {
                        Text("No TV shows in this category.").foregroundStyle(.secondary).padding()
                    } else {
                        showGrid(matches, featured: true)
                    }
                }
            }.padding(.bottom, 24)
        }
        .background { StreamBackdrop() }
        .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
        .onChange(of: query) { _, _ in visibleCount = 60 }
        .task(id: "\(model.libraryRevision)-\(retry)-\(searchingCatalog)") {
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
        .task(id: "\(model.libraryRevision)-\(retry)-\(category)") {
            if loadedRevision != model.libraryRevision || loadedRetry != retry {
                await store.loadCategories()
                guard !Task.isCancelled else { return }
                loadedRevision = model.libraryRevision; loadedRetry = retry; loadedCategory = ""
            }
            guard store.unavailableReason == nil, store.error.isEmpty else { return }
            if !visibleCategories.contains(where: { $0.id == category }) {
                category = visibleCategories.first?.id ?? ""
                return
            }
            guard !category.isEmpty, loadedCategory != category else { return }
            visibleCount = 60
            await store.loadSeries(categoryID: category)
            if !Task.isCancelled, store.error.isEmpty { loadedCategory = category }
        }
    }
}

struct ShowDetailView: View {
    let series: SeriesItem
    @ObservedObject var store: SeriesStore
    @EnvironmentObject private var model: AppModel
    @State private var seasons: [SeriesSeason] = []
    @State private var episodes: [Int: [SeriesEpisode]] = [:]
    @State private var season = 0
    @State private var loading = true
    @State private var retry = 0
    @State private var playing: CatalogItem?
    @State private var startSeconds = 0.0
    @State private var playbackError = ""
    @AppStorage("rigatoni-appearance") private var appearance = "dark"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    ProviderPoster(url: series.poster, kind: .movies).frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Text(model.preferences.seriesTitle(series)).font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                }
                MobileSaveButton(record: SavedRecord(kind: "series", itemID: series.id, name: series.name, ext: "", categoryID: "", addedAt: Date(), providerID: series.providerID))
                    .buttonStyle(.bordered)
                if loading { ProgressView("Loading episodes…") }
                else if !store.detailError.isEmpty {
                    Text(store.detailError).foregroundStyle(.secondary)
                    Button("Retry") { retry += 1 }
                } else if seasons.isEmpty { Text("No episodes found.").foregroundStyle(.secondary) }
                else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 10) {
                            ForEach(seasons) { item in
                                Button { season = item.number } label: {
                                    Text(item.name).padding(.horizontal, 18).frame(height: 48)
                                        .background(season == item.number ? AnyShapeStyle(StreamTheme.accentFill) : AnyShapeStyle(StreamTheme.panel), in: Capsule())
                                        .foregroundStyle(season == item.number ? StreamTheme.onAccent : StreamTheme.text)
                                }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                            }
                        }.padding(.vertical, 6)
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(episodes[season] ?? []) { episode in
                            let progress = model.preferences.progress[episode.progressID]
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Episode \(episode.number) · \(episode.title)").font(.headline)
                                HStack {
                                    Button(progress.map { "Continue from \($0.label)" } ?? "Play episode") {
                                        play(episode, seconds: progress?.seconds ?? 0)
                                    }.buttonStyle(.borderedProminent).foregroundStyle(StreamTheme.onAccent)
                                    if progress != nil {
                                        Button("Restart") {
                                            model.preferences.progress[episode.progressID] = nil
                                            model.preferences.write(key: model.preferenceKey)
                                            play(episode, seconds: 0)
                                        }.buttonStyle(.bordered)
                                    }
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(StreamTheme.card, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                if !playbackError.isEmpty { Text(playbackError).foregroundStyle(.secondary) }
            }.padding()
        }
        .background { StreamBackdrop() }
        .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
        .navigationTitle("Episodes").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.libraryRevision)-\(retry)-\(series.scopedID)") {
            loading = true; defer { loading = false }
            let result = await store.loadDetail(series: series)
            guard !Task.isCancelled else { return }
            seasons = result.seasons; episodes = result.episodes; season = seasons.first?.number ?? 0
        }
        .fullScreenCover(item: $playing) { item in
            DirectPlayerView(item: item, provider: model.provider(for: item), startSeconds: startSeconds, progressID: "series-" + item.id)
        }
    }

    private func play(_ episode: SeriesEpisode, seconds: Double) {
        playbackError = ""
        do {
            guard store.unavailableReason == nil else { throw AppFailure(store.unavailableReason ?? "Provider unavailable.") }
            let owner = store.provider(for: series)
            var item = CatalogItem(id: episode.id, name: "\(series.name) · S\(season) E\(episode.number) — \(episode.title)", kind: .movies, fileExtension: episode.ext, poster: series.poster, providerID: series.providerID)
            item.playbackURL = try SeriesStore.seriesStreamURL(provider: owner, episodeID: episode.id, ext: episode.ext)
            startSeconds = seconds; playing = item
        } catch { playbackError = error.localizedDescription }
    }
}
