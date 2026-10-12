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
    @State private var visibleCount = 60
    @State private var retry = 0
    @State private var loadedRevision: Int?
    @State private var loadedRetry = -1
    @State private var loadedCategory = ""
    @AppStorage("rigatoni-appearance") private var appearance = "dark"

    private var matches: [SeriesItem] {
        query.isEmpty ? store.series : store.series.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let reason = store.unavailableReason {
                    Text(reason).foregroundStyle(.secondary).padding()
                    Button("Provider settings") { model.settingsVisible = true }.padding(.horizontal)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(spacing: 10) {
                            ForEach(store.categories) { entry in
                                Button { category = entry.id } label: {
                                    Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        .padding(.horizontal, 18).frame(height: 54)
                                        .background(category == entry.id ? StreamTheme.accent : StreamTheme.panel, in: Capsule())
                                        .foregroundStyle(category == entry.id ? Color.white : StreamTheme.text)
                                }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                            }
                        }.padding(.horizontal).padding(.vertical, 8)
                    }.frame(height: 74).scrollClipDisabled()
                    if store.loading { ProgressView("Loading shows…").frame(maxWidth: .infinity).padding(30) }
                    else if !store.error.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.error).foregroundStyle(.secondary)
                            Button("Retry") { retry += 1 }
                        }.padding()
                    } else if matches.isEmpty {
                        Text(query.isEmpty ? "No TV shows in this category." : "No matching shows in this category.")
                            .foregroundStyle(.secondary).padding()
                    } else {
                        if query.isEmpty, let featured = matches.first {
                            NavigationLink { ShowDetailView(series: featured, store: store) } label: {
                                MobileHero(title: featured.name, poster: featured.poster, badge: "TV SHOWS")
                            }.buttonStyle(.plain).padding(.horizontal)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 20) {
                            ForEach(Array(matches.prefix(visibleCount))) { series in
                                NavigationLink { ShowDetailView(series: series, store: store) } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ProviderPoster(url: series.poster, kind: .movies).aspectRatio(2 / 3, contentMode: .fit)
                                        Text(series.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(10)
                                    }
                                    .foregroundStyle(StreamTheme.text).background(StreamTheme.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain).contextMenu {
                                    MobileSaveButton(record: SavedRecord(kind: "series", itemID: series.id, name: series.name, ext: "", categoryID: category, addedAt: Date()))
                                }
                            }
                        }.padding(.horizontal)
                        if matches.count > visibleCount { Button("Show more") { visibleCount += 60 }.padding() }
                    }
                }
            }.padding(.bottom, 24)
        }
        .background { StreamBackdrop() }
        .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
        .searchable(text: $query, prompt: "Search this TV show category")
        .onChange(of: query) { _, _ in visibleCount = 60 }
        .task(id: "\(model.libraryRevision)-\(retry)-\(category)") {
            if loadedRevision != model.libraryRevision || loadedRetry != retry {
                await store.loadCategories()
                guard !Task.isCancelled else { return }
                loadedRevision = model.libraryRevision; loadedRetry = retry; loadedCategory = ""
            }
            guard store.unavailableReason == nil, store.error.isEmpty else { return }
            if !store.categories.contains(where: { $0.id == category }) {
                category = store.categories.first?.id ?? ""
                return
            }
            guard !category.isEmpty, loadedCategory != category else { return }
            visibleCount = 60; query = ""
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
                    Text(series.name).font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                }
                MobileSaveButton(record: SavedRecord(kind: "series", itemID: series.id, name: series.name, ext: "", categoryID: "", addedAt: Date()))
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
                                        .background(season == item.number ? StreamTheme.accent : StreamTheme.panel, in: Capsule())
                                        .foregroundStyle(season == item.number ? Color.white : StreamTheme.text)
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
                                    }.buttonStyle(.borderedProminent)
                                    if progress != nil {
                                        Button("Restart") {
                                            model.preferences.progress[episode.progressID] = nil
                                            model.preferences.write(key: model.preferenceKey)
                                            play(episode, seconds: 0)
                                        }.buttonStyle(.bordered)
                                    }
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(StreamTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                if !playbackError.isEmpty { Text(playbackError).foregroundStyle(.secondary) }
            }.padding()
        }
        .background { StreamBackdrop() }
        .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
        .navigationTitle("Episodes").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.libraryRevision)-\(retry)") {
            loading = true; defer { loading = false }
            let result = await store.loadDetail(seriesID: series.id)
            guard !Task.isCancelled else { return }
            seasons = result.seasons; episodes = result.episodes; season = seasons.first?.number ?? 0
        }
        .fullScreenCover(item: $playing) { item in
            DirectPlayerView(item: item, provider: model.provider, startSeconds: startSeconds, progressID: "series-" + item.id)
        }
    }

    private func play(_ episode: SeriesEpisode, seconds: Double) {
        playbackError = ""
        do {
            guard store.unavailableReason == nil else { throw AppFailure(store.unavailableReason ?? "Provider unavailable.") }
            var item = CatalogItem(id: episode.id, name: "\(series.name) · S\(season) E\(episode.number) — \(episode.title)", kind: .movies, fileExtension: episode.ext, poster: series.poster)
            item.playbackURL = try SeriesStore.seriesStreamURL(provider: model.provider, episodeID: episode.id, ext: episode.ext)
            startSeconds = seconds; playing = item
        } catch { playbackError = error.localizedDescription }
    }
}
