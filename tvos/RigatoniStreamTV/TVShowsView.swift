import SwiftUI

// TV Shows tab (new — the iPhone build never had series). Uses the Xtream
// player_api series endpoints through the shared Provider/AppModel code.
// The shared LibraryKind only covers live/movies (and lives in ios/, which
// this branch must not modify), so this tab keeps tvOS-local series types.
// Series are NOT available through the HTTPS gateway — the gateway leaves
// series as a placeholder — so this tab needs a direct provider connection.
struct TVSeries: Identifiable {
    let id: String
    let name: String
    let poster: URL?
}

struct TVSeason: Identifiable {
    var id: String { "\(number)" }
    let number: Int
    let name: String
}

struct TVEpisode: Identifiable {
    let id: String
    let number: Int
    let title: String
    let ext: String
}

@MainActor
final class TVSeriesStore: ObservableObject {
    private let model: AppModel

    @Published var categories: [CatalogCategory] = []
    @Published var series: [TVSeries] = []
    @Published var loading = false
    @Published var progress = ""
    @Published var error = ""

    init(model: AppModel) { self.model = model }

    var unavailableReason: String? {
        guard model.signedIn, model.providerReady else {
            return "Save your provider in Settings to browse TV shows."
        }
        if model.provider.requiresGateway {
            return "TV Shows needs a direct provider connection — it isn't available through the gateway yet."
        }
        return nil
    }

    /// Series stream URL: {server}/series/{username}/{password}/{episode_id}.{ext}.
    /// Mirrors Provider.streamURL's encoding so credentials stay in the path
    /// (never in a query string or log).
    static func seriesStreamURL(provider: Provider, episodeID: String, ext: String) throws -> URL {
        var parts = URLComponents(url: try provider.baseURL(), resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let base = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = [base, "series", provider.username, provider.password, "\(episodeID).\(ext)"]
            .filter { !$0.isEmpty }
        parts.percentEncodedPath = "/" + components
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        guard let url = parts.url else { throw AppFailure("Invalid stream URL.") }
        return url
    }

    private func fetchJSON(action: String, extra: [String: String] = [:]) async throws -> Any {
        var components = URLComponents(url: try model.provider.apiURL(action: action),
                                       resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        for (key, value) in extra { items.append(URLQueryItem(name: key, value: value)) }
        components.queryItems = items
        guard let url = components.url else { throw AppFailure("Invalid provider URL.") }
        let data = try await BoundedTransfer(limit: 32 * 1024 * 1024).fetch(url)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func validURL(_ string: String?) -> URL? {
        let url = string.flatMap(URL.init(string:))
        return ["https", "http"].contains(url?.scheme ?? "") ? url : nil
    }

    func loadCategories() async {
        categories = []; series = []; error = ""
        guard unavailableReason == nil else { return }
        loading = true
        defer { loading = false }
        do {
            guard let rows = try await fetchJSON(action: "get_series_categories") as? [[String: Any]] else {
                throw AppFailure("The provider returned an invalid category list.")
            }
            try Task.checkCancellation()
            categories = rows.compactMap { row in
                let id = row["category_id"].map { String(describing: $0) } ?? ""
                guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
                return CatalogCategory(id: id, name: row["category_name"] as? String ?? "Category")
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func loadSeries(categoryID: String) async {
        series = []; error = ""
        guard unavailableReason == nil, !categoryID.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            guard let rows = try await fetchJSON(action: "get_series", extra: ["category_id": categoryID]) as? [[String: Any]] else {
                throw AppFailure("The provider returned an invalid series list.")
            }
            try Task.checkCancellation()
            series = rows.compactMap { row in
                let id = row["series_id"].map { String(describing: $0) } ?? ""
                guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
                return TVSeries(id: id,
                                name: row["name"] as? String ?? "Untitled",
                                poster: validURL(row["cover"] as? String))
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Loads seasons and episodes for a series via get_series_info.
    func loadDetail(seriesID: String) async -> (seasons: [TVSeason], episodes: [Int: [TVEpisode]]) {
        do {
            guard let root = try await fetchJSON(action: "get_series_info", extra: ["series_id": seriesID]) as? [String: Any] else {
                throw AppFailure("The provider returned invalid series details.")
            }
            try Task.checkCancellation()
            var seasons: [TVSeason] = []
            if let rawSeasons = root["seasons"] as? [[String: Any]] {
                for row in rawSeasons {
                    let number = Int(String(describing: row["season_number"] ?? "")) ?? 0
                    guard number > 0 else { continue }
                    seasons.append(TVSeason(number: number,
                                            name: row["name"] as? String ?? "Season \(number)"))
                }
            }
            seasons.sort { $0.number < $1.number }
            var episodes: [Int: [TVEpisode]] = [:]
            if let rawEpisodes = root["episodes"] as? [String: Any] {
                for (seasonKey, value) in rawEpisodes {
                    guard let seasonNumber = Int(seasonKey),
                          let rows = value as? [[String: Any]] else { continue }
                    var list: [TVEpisode] = []
                    for row in rows {
                        let id = row["id"].map { String(describing: $0) } ?? ""
                        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { continue }
                        let number = Int(String(describing: row["episode_num"] ?? "")) ?? 0
                        let info = row["info"] as? [String: Any]
                        let ext = ((info?["container_extension"] as? String) ?? "mp4").lowercased()
                        let allowed = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "m3u8"]
                        list.append(TVEpisode(id: id,
                                              number: number,
                                              title: row["title"] as? String ?? "Episode \(number)",
                                              ext: allowed.contains(ext) ? ext : "mp4"))
                    }
                    episodes[seasonNumber] = list.sorted { $0.number < $1.number }
                }
            }
            if seasons.isEmpty {
                seasons = episodes.keys.sorted().map { TVSeason(number: $0, name: "Season \($0)") }
            }
            return (seasons, episodes)
        } catch {
            return ([], [:])
        }
    }
}

// MARK: - Series browser

struct TVShowsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: TVSeriesStore?
    @State private var selectedCategory = ""
    @State private var selectedSeries: TVSeries?

    var body: some View {
        Group {
            if let store { content(store) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(TVTheme.background)
        .onAppear {
            if store == nil { store = TVSeriesStore(model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVSeriesStore) -> some View {
        if let reason = store.unavailableReason {
            Text(reason)
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: model.libraryRevision) { await store.loadCategories() }
        } else if store.loading && store.categories.isEmpty {
            ProgressView("Loading TV shows…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: model.libraryRevision) { await store.loadCategories() }
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
                            Button("Retry") { Task { await store.loadSeries(categoryID: selectedCategory) } }
                                .buttonStyle(.card)
                        }
                    } else if store.series.isEmpty {
                        Text("No shows in this category.").foregroundStyle(TVTheme.muted)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220), spacing: 28)],
                            spacing: 32
                        ) {
                            ForEach(store.series) { item in
                                Button { selectedSeries = item } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        TVSeriesPoster(series: item)
                                        Text(item.name)
                                            .font(.headline)
                                            .lineLimit(2)
                                            .frame(width: 200, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.card)
                            }
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
            .task(id: model.libraryRevision) {
                await store.loadCategories()
                if selectedCategory.isEmpty {
                    selectedCategory = store.categories.first?.id ?? ""
                }
            }
            .task(id: selectedCategory) {
                await store.loadSeries(categoryID: selectedCategory)
            }
            .fullScreenCover(item: $selectedSeries) { series in
                TVSeriesDetailView(series: series, store: store)
                    .environmentObject(model)
            }
        }
    }
}

private struct TVSeriesPoster: View {
    let series: TVSeries

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

private struct TVSeriesDetailView: View {
    let series: TVSeries
    @ObservedObject var store: TVSeriesStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var seasons: [TVSeason] = []
    @State private var episodes: [Int: [TVEpisode]] = [:]
    @State private var selectedSeason = 0
    @State private var loading = true
    @State private var playing: CatalogItem?

    private var seasonEpisodes: [TVEpisode] {
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
                        .buttonStyle(.card)
                        Spacer()
                    }
                    Text(series.name)
                        .font(.system(size: 56, weight: .bold))
                        .lineLimit(2)

                    if loading {
                        ProgressView("Loading episodes…")
                    } else if seasons.isEmpty {
                        Text("No episodes found for this show.")
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
                                            Text(episode.title)
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
                                    .buttonStyle(.card)
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
            TVPlayerView(item: item, provider: model.provider, lastWatchedKind: "series")
        }
    }

    private func play(_ episode: TVEpisode) {
        do {
            let url = try TVSeriesStore.seriesStreamURL(
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
