import SwiftUI

// Shared, bounded Xtream series access for iPhone and Apple TV.
// Provider credentials stay in memory and this device’s Keychain, or the account vault when signed in.
struct SeriesItem: Identifiable {
    let id: String
    let name: String
    let poster: URL?
    /// Owning provider in combined-library mode. Nil = selected provider.
    var providerID: UUID? = nil
    var categoryID: String = ""
    var added: Int = 0
    var rating: Double = 0
    var year: String = ""
    /// Provider-supplied IMDb/TMDB identifier, when present. These IDs take
    /// precedence over title heuristics when combining language/provider copies.
    var externalID: String? = nil
    var scopedID: String { CatalogItem.namespaced(providerID: providerID, id: id) }
}

struct SeriesSeason: Identifiable {
    var id: String { "\(number)" }
    let number: Int
    let name: String
}

struct SeriesEpisode: Identifiable {
    var progressID: String { "series-" + id }
    let id: String
    let number: Int
    let title: String
    let ext: String
    var thumbnail: URL? = nil
    var synopsis: String = ""
    var durationSeconds: Int = 0
}

enum SeriesSearchBudget {
    static let maximumItems = 100_000
}

struct SeriesShowDetails {
    let seasons: [SeriesSeason]
    let episodes: [Int: [SeriesEpisode]]
    let synopsis: String
    let genre: String
    let year: String
    let rating: String
    let contentRating: String
    let backdrop: URL?
}

struct SeriesEpisodeSource: Identifiable {
    let series: SeriesItem
    let episode: SeriesEpisode
    var id: String { series.scopedID + ":" + episode.id }
    var progressID: String {
        series.providerID == nil ? episode.progressID : "series-\(series.scopedID)-\(episode.id)"
    }
}

struct UnifiedSeriesEpisode: Identifiable {
    let season: Int
    let number: Int
    let title: String
    let sources: [SeriesEpisodeSource]
    var id: String { "\(season):\(number):\(title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))" }
}

enum SeriesEpisodeGrouping {
    static func merge(_ entries: [(SeriesItem, SeriesShowDetails)]) -> [Int: [UnifiedSeriesEpisode]] {
        var grouped: [Int: [String: [SeriesEpisodeSource]]] = [:]
        var titles: [Int: [String: String]] = [:]
        for (series, details) in entries {
            for (season, episodes) in details.episodes {
                for episode in episodes {
                    let normalizedTitle = episode.title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    let key = episode.number > 0 ? "number:\(episode.number)" : "title:\(normalizedTitle)"
                    grouped[season, default: [:]][key, default: []].append(SeriesEpisodeSource(series: series, episode: episode))
                    if titles[season]?[key] == nil { titles[season, default: [:]][key] = episode.title }
                }
            }
        }
        var result: [Int: [UnifiedSeriesEpisode]] = [:]
        for (season, byKey) in grouped {
            result[season] = byKey.map { key, sources in
                let number = Int(key.replacingOccurrences(of: "number:", with: "")) ?? 0
                return UnifiedSeriesEpisode(season: season, number: number, title: titles[season]?[key] ?? "Episode \(number)", sources: sources.sorted { $0.series.scopedID < $1.series.scopedID })
            }.sorted {
                if $0.number != $1.number { return $0.number < $1.number }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return result
    }
}

@MainActor
final class SeriesStore: ObservableObject {
    private let model: AppModel

    @Published var categories: [CatalogCategory] = []
    @Published var series: [SeriesItem] = []
    @Published var loading = false
    @Published var progress = ""
    @Published var error = ""
    @Published var detailError = ""
    /// Partial TV-show search failures. Kept off `error` so browsing a category
    /// is not replaced by a search notice.
    @Published var searchNotice = ""

    init(model: AppModel) { self.model = model }

    var unavailableReason: String? {
        guard model.providerReady else {
            return "Save your provider to browse TV shows."
        }
        let kinds = model.libraryMode == .combined
            ? model.combinedProfiles.map(\.provider.kind)
            : [model.provider.kind]
        if !kinds.contains(.xtream) {
            return "M3U playlists do not supply seasons and episodes. Add an Xtream Codes provider for TV Shows; playlist video entries remain available in Movies."
        }
        return nil
    }
    /// Owning provider for a series item in combined mode.
    func provider(for series: SeriesItem) -> Provider {
        if model.libraryMode == .combined, let pid = series.providerID,
           let profile = model.vault.profiles.first(where: { $0.id == pid }) { return profile.provider }
        return model.provider
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
            .enumerated().map { index, value in
                index == 0 && !base.isEmpty ? value : (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            }
            .joined(separator: "/")
        guard let url = parts.url else { throw AppFailure("Invalid stream URL.") }
        return url
    }

    private func fetchJSON(action: String, extra: [String: String] = [:], provider: Provider? = nil) async throws -> Any {
        var components = URLComponents(url: try (provider ?? model.provider).apiURL(action: action),
                                       resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        for (key, value) in extra { items.append(URLQueryItem(name: key, value: value)) }
        components.queryItems = items
        guard let url = components.url else { throw AppFailure("Invalid provider URL.") }
        let data = try await BoundedTransfer(limit: 32 * 1024 * 1024).fetch(url)
        return try await Task.detached(priority: .userInitiated) { try JSONSerialization.jsonObject(with: data) }.value
    }

    func loadCategories() async {
        categories = []; series = []; error = ""
        guard unavailableReason == nil else { return }
        loading = true
        defer { loading = false }
        do {
            if model.libraryMode == .combined {
                let profiles = model.combinedProfiles.filter { $0.provider.kind == .xtream }
                var merged: [CatalogCategory] = []
                var lastError: Error?
                for profile in profiles {
                    try Task.checkCancellation()
                    do {
                        let rows = try await fetchJSON(action: "get_series_categories", provider: profile.provider) as? [[String: Any]] ?? []
                        let prefix = profiles.count > 1 ? profile.provider.name + " · " : ""
                        merged += rows.compactMap { row in
                            let id = row["category_id"].map { String(describing: $0) } ?? ""
                            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
                            return CatalogCategory(id: CatalogItem.namespaced(providerID: profile.id, id: id),
                                                   name: prefix + (row["category_name"] as? String ?? "Category"))
                        }
                    } catch { lastError = error }
                }
                try Task.checkCancellation()
                categories = merged
                if merged.isEmpty, let lastError { error = lastError.localizedDescription }
            } else {
                guard let rows = try await fetchJSON(action: "get_series_categories") as? [[String: Any]] else {
                    throw AppFailure("The provider returned an invalid category list.")
                }
                try Task.checkCancellation()
                categories = rows.compactMap { row in
                    let id = row["category_id"].map { String(describing: $0) } ?? ""
                    guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
                    return CatalogCategory(id: id, name: row["category_name"] as? String ?? "Category")
                }
            }
            if model.preferences.observeCategories(categories, section: .series) { model.savePreferences() }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func loadSeries(categoryID: String) async {
        series = []; error = ""
        guard unavailableReason == nil, !categoryID.isEmpty else { return }
        if let cached = model.catalog.cachedSeries(categoryID: categoryID) {
            series = SeriesSearchScope.visible(cached, categories: categories, preferences: model.preferences)
            return
        }
        if model.libraryMode == .separate, model.provider.kind == .xtream,
           let cached = await PersistentCatalogIndex.shared.loadSeries(scope: model.catalogCacheScope, categoryID: categoryID) {
            model.catalog.cacheSeries(cached, categoryID: categoryID)
            series = SeriesSearchScope.visible(cached, categories: categories, preferences: model.preferences)
            return
        }
        loading = true
        defer { loading = false }
        do {
            var owner: Provider? = nil
            var rawID = categoryID
            var tag: UUID? = nil
            if model.libraryMode == .combined,
               let (pid, raw) = CatalogItem.splitNamespaced(categoryID),
               let profile = model.vault.profiles.first(where: { $0.id == pid }) {
                owner = profile.provider; rawID = raw; tag = pid
            }
            guard let rows = try await fetchJSON(action: "get_series", extra: ["category_id": rawID], provider: owner) as? [[String: Any]] else {
                throw AppFailure("The provider returned an invalid series list.")
            }
            try Task.checkCancellation()
            series = Self.parseSeries(rows, providerID: tag, fallbackCategoryID: categoryID)
            model.catalog.cacheSeries(series, categoryID: categoryID)
            if model.libraryMode == .separate, model.provider.kind == .xtream {
                await PersistentCatalogIndex.shared.storeSeries(series, scope: model.catalogCacheScope, categoryID: categoryID, provider: model.provider)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Fast first-screen preview: fetch only a few enabled categories and
    /// publish as each finishes. Global search remains the only operation
    /// that deliberately walks the complete enabled catalog.
    func loadPreviewSeries(categoryLimit: Int = 3,
                           update: (([SeriesItem], String) -> Void)? = nil) async -> [SeriesItem] {
        searchNotice = ""
        if let unavailableReason { searchNotice = unavailableReason; update?([], ""); return [] }
        if categories.isEmpty {
            await loadCategories()
            guard !Task.isCancelled else { return [] }
        }
        let allowed = SeriesSearchScope.categories(categories, preferences: model.preferences)
        let selected = Array(allowed.prefix(max(1, categoryLimit)))
        guard !selected.isEmpty else { update?([], ""); return [] }

        loading = true
        defer { if !Task.isCancelled { loading = false } }
        var batches: [Int: [SeriesItem]] = [:]
        var missing: [(Int, CatalogCategory)] = []
        for (index, category) in selected.enumerated() {
            if let cached = model.catalog.cachedSeries(categoryID: category.id) { batches[index] = cached }
            else if model.libraryMode == .separate, model.provider.kind == .xtream,
                    let cached = await PersistentCatalogIndex.shared.loadSeries(scope: model.catalogCacheScope, categoryID: category.id) {
                model.catalog.cacheSeries(cached, categoryID: category.id)
                batches[index] = cached
            } else { missing.append((index, category)) }
        }
        func merged() -> [SeriesItem] {
            var seen = Set<String>()
            let flattened = batches.keys.sorted().flatMap { batches[$0] ?? [] }.filter { seen.insert($0.scopedID).inserted }
            return SeriesSearchScope.visible(flattened, categories: categories, preferences: model.preferences)
        }
        var completed = selected.count - missing.count
        update?(merged(), "\(completed) of \(selected.count) preview categories")
        guard !missing.isEmpty else { series = merged(); return series }

        let requests: [(Int, String, String, Provider?, UUID?)] = missing.map { index, category in
            if model.libraryMode == .combined,
               let (id, raw) = CatalogItem.splitNamespaced(category.id),
               let profile = model.vault.profiles.first(where: { $0.id == id }) {
                return (index, category.id, raw, profile.provider, id)
            }
            return (index, category.id, category.id, nil, nil)
        }
        await withTaskGroup(of: (Int, String, [SeriesItem]?).self) { group in
            var next = 0
            func enqueue(_ request: (Int, String, String, Provider?, UUID?)) {
                group.addTask { [self] in
                    do {
                        try Task.checkCancellation()
                        guard let rows = try await fetchJSON(action: "get_series", extra: ["category_id": request.2], provider: request.3) as? [[String: Any]] else {
                            return (request.0, request.1, nil)
                        }
                        try Task.checkCancellation()
                        return (request.0, request.1, Self.parseSeries(rows, providerID: request.4, fallbackCategoryID: request.1))
                    } catch { return (request.0, request.1, nil) }
                }
            }
            for request in requests.prefix(2) { enqueue(request); next += 1 }
            while let (index, categoryID, items) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                completed += 1
                if let items {
                    batches[index] = items
                    model.catalog.cacheSeries(items, categoryID: categoryID)
                    if model.libraryMode == .separate, model.provider.kind == .xtream {
                        await PersistentCatalogIndex.shared.storeSeries(items, scope: model.catalogCacheScope, categoryID: categoryID, provider: model.provider)
                    }
                }
                let partial = merged()
                series = partial
                update?(partial, "\(completed) of \(selected.count) preview categories")
                if next < requests.count { enqueue(requests[next]); next += 1 }
            }
        }
        guard !Task.isCancelled else { return [] }
        series = merged()
        return series
    }

    /// Loads every visible TV-show category for search. An unscoped `get_series`
    /// request is used once per session when the provider actually returns more
    /// than one category; many providers reject that form or echo only the
    /// category last browsed, so search then uses the same category-scoped
    /// requests as the browser. Results stay in the session catalog so repeat
    /// searches do not hammer the provider. Plain HTTP uses the same API URL.
    func loadAllSeries(update: (([SeriesItem], String) -> Void)? = nil) async -> [SeriesItem] {
        searchNotice = ""
        if let unavailableReason { searchNotice = unavailableReason; return [] }
        if categories.isEmpty {
            await loadCategories()
            guard !Task.isCancelled else { return [] }
            if !error.isEmpty { searchNotice = error; return [] }
        }
        guard !Task.isCancelled else { return [] }
        let allowed = SeriesSearchScope.categories(categories, preferences: model.preferences)
        if allowed.isEmpty {
            update?([], "")
            return []
        }
        if let full = model.catalog.cachedFullSeries() {
            let items = SeriesSearchScope.visible(full, categories: categories, preferences: model.preferences)
            update?(items, "")
            return items
        }
        if model.libraryMode == .separate, model.provider.kind == .xtream,
           let cached = await PersistentCatalogIndex.shared.loadSeriesSnapshot(scope: model.catalogCacheScope, categoryIDs: allowed.map(\.id)) {
            model.catalog.cacheFullSeries(cached)
            for category in allowed {
                let batch = cached.filter { $0.categoryID == category.id }
                model.catalog.cacheSeries(batch, categoryID: category.id)
            }
            let items = SeriesSearchScope.visible(cached, categories: categories, preferences: model.preferences)
            update?(items, "")
            return items
        }
        if model.libraryMode != .combined && allowed.count == categories.count && !model.catalog.seriesFullWasChecked() {
            let rows: [[String: Any]]?
            do {
                rows = try await fetchJSON(action: "get_series") as? [[String: Any]]
            } catch is CancellationError {
                return []
            } catch {
                rows = nil
            }
            guard !Task.isCancelled else { return [] }
            model.catalog.markSeriesFullChecked()
            if let rows, !rows.isEmpty {
                let parsed = Self.parseSeries(rows)
                if CatalogCoverage.isComplete(categoryIDs: parsed.map(\.categoryID), categoryCount: categories.count) {
                    model.catalog.cacheFullSeries(parsed)
                    if model.libraryMode == .separate, model.provider.kind == .xtream {
                        await PersistentCatalogIndex.shared.markSeriesSnapshot(parsed, scope: model.catalogCacheScope, categoryIDs: allowed.map(\.id), provider: model.provider)
                    }
                    let items = SeriesSearchScope.visible(parsed, categories: categories, preferences: model.preferences)
                    update?(items, "")
                    return items
                }
            }
        }
        var batches: [Int: [SeriesItem]] = [:]
        var reachedLimit = false
        var missing: [(Int, CatalogCategory)] = []
        for (index, category) in allowed.enumerated() {
            if let cached = model.catalog.cachedSeries(categoryID: category.id) {
                batches[index] = cached
            } else if model.libraryMode == .separate, model.provider.kind == .xtream,
                      let cached = await PersistentCatalogIndex.shared.loadSeries(scope: model.catalogCacheScope, categoryID: category.id) {
                // Reuse independently persisted categories after an interrupted
                // or partial index build instead of refetching the whole catalog.
                batches[index] = cached
                model.catalog.cacheSeries(cached, categoryID: category.id)
            } else {
                missing.append((index, category))
            }
        }
        func merged() -> [SeriesItem] {
            var items: [SeriesItem] = []
            var seen = Set<String>()
            outer: for key in batches.keys.sorted() {
                for item in batches[key] ?? [] where seen.insert(item.scopedID).inserted {
                    if items.count == SeriesSearchBudget.maximumItems { reachedLimit = true; break outer }
                    items.append(item)
                }
            }
            return SeriesSearchScope.visible(items, categories: categories, preferences: model.preferences)
        }
        var completed = allowed.count - missing.count
        update?(merged(), "\(completed) of \(allowed.count) categories")
        if missing.isEmpty { return merged() }
        let requests: [(Int, String, String, Provider?, UUID?)] = missing.map { index, category in
            if model.libraryMode == .combined,
               let (id, raw) = CatalogItem.splitNamespaced(category.id),
               let profile = model.vault.profiles.first(where: { $0.id == id }) {
                return (index, category.id, raw, profile.provider, id)
            }
            return (index, category.id, category.id, nil, nil)
        }
        var failures = 0
        await withTaskGroup(of: (Int, String, [SeriesItem]?).self) { group in
            var next = 0
            func enqueue(_ request: (Int, String, String, Provider?, UUID?)) {
                group.addTask { [self] in
                    do {
                        try Task.checkCancellation()
                        guard let rows = try await fetchJSON(action: "get_series", extra: ["category_id": request.2], provider: request.3) as? [[String: Any]] else {
                            return (request.0, request.1, nil)
                        }
                        try Task.checkCancellation()
                        return (request.0, request.1, Self.parseSeries(rows, providerID: request.4, fallbackCategoryID: request.1))
                    } catch { return (request.0, request.1, nil) }
                }
            }
            for request in requests.prefix(2) { enqueue(request); next += 1 }
            while let (index, categoryID, items) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                completed += 1
                if let items {
                    batches[index] = items
                    model.catalog.cacheSeries(items, categoryID: categoryID)
                    if model.libraryMode == .separate, model.provider.kind == .xtream {
                        await PersistentCatalogIndex.shared.storeSeries(items, scope: model.catalogCacheScope, categoryID: categoryID, provider: model.provider)
                    }
                } else { failures += 1 }
                let partial = merged()
                update?(partial, "\(completed) of \(allowed.count) categories")
                if reachedLimit {
                    group.cancelAll()
                    break
                }
                if next < requests.count { enqueue(requests[next]); next += 1 }
            }
        }
        guard !Task.isCancelled else { return [] }
        if reachedLimit {
            searchNotice = "Search reached its 100,000-show session limit. Narrow the categories in Settings to search a smaller catalog."
        }
        if failures > 0 {
            let failure = "Could not search \(failures) TV show categor\(failures == 1 ? "y" : "ies"). Retry to include the missing results."
            searchNotice = [searchNotice, failure].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let result = merged()
        if failures == 0, !reachedLimit, model.libraryMode == .separate, model.provider.kind == .xtream {
            await PersistentCatalogIndex.shared.markSeriesSnapshot(result, scope: model.catalogCacheScope, categoryIDs: allowed.map(\.id), provider: model.provider)
        }
        return result
    }

    /// Searches the persistent provider index first so warm global searches
    /// decode only matches instead of restoring a complete 100k-item array.
    /// On the first search, loadAllSeries builds the index from provider data.
    func searchSeries(_ query: String, update: (([SeriesItem], String) -> Void)? = nil) async -> [SeriesItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        if categories.isEmpty {
            await loadCategories()
            guard !Task.isCancelled else { return [] }
        }
        let allowed = SeriesSearchScope.categories(categories, preferences: model.preferences)
        if model.libraryMode == .separate, model.provider.kind == .xtream,
           await PersistentCatalogIndex.shared.hasSeriesSnapshot(scope: model.catalogCacheScope, categoryIDs: allowed.map(\.id)) {
            let matches = await PersistentCatalogIndex.shared.searchSeries(scope: model.catalogCacheScope, query: term, categoryIDs: allowed.map(\.id), limit: 1000)
            let visible = SeriesSearchScope.visible(matches, categories: categories, preferences: model.preferences)
            update?(visible, "")
            return visible
        }
        let all = await loadAllSeries(update: update)
        guard !Task.isCancelled else { return [] }
        return SeriesSearchScope.matching(all, query: term, categories: categories, preferences: model.preferences)
    }

    nonisolated static func parseSeries(_ rows: [[String: Any]], providerID: UUID? = nil, fallbackCategoryID: String = "") -> [SeriesItem] {
        rows.prefix(SeriesSearchBudget.maximumItems).compactMap { row in
            let id = row["series_id"].map { String(describing: $0) } ?? ""
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            let rawCategory = ProviderFields.text(row["category_id"])
            let categoryID = rawCategory.isEmpty ? fallbackCategoryID : CatalogItem.namespaced(providerID: providerID, id: rawCategory)
            let info = row["info"] as? [String: Any]
            let imdb = ProviderFields.text(row["imdb_id"] ?? row["imdb"] ?? info?["imdb_id"] ?? info?["imdb"])
            let tmdb = ProviderFields.text(row["tmdb_id"] ?? row["tmdb"] ?? info?["tmdb_id"] ?? info?["tmdb"])
            let externalID = !imdb.isEmpty ? "imdb:\(imdb.lowercased())" : (!tmdb.isEmpty ? "tmdb:\(tmdb)" : nil)
            return SeriesItem(id: id,
                            name: row["name"] as? String ?? "Untitled",
                            poster: validURL(row["cover"] as? String),
                            providerID: providerID,
                            categoryID: categoryID,
                            added: ProviderFields.added(from: row),
                            rating: ProviderFields.rating(from: row),
                            year: ProviderFields.year(from: row),
                            externalID: externalID)
        }
    }

    nonisolated private static func validURL(_ string: String?) -> URL? {
        let url = string.flatMap(URL.init(string:))
        return ["https", "http"].contains(url?.scheme ?? "") ? url : nil
    }

    /// Loads seasons and episodes for a series via get_series_info.
    func loadDetail(seriesID: String) async -> (seasons: [SeriesSeason], episodes: [Int: [SeriesEpisode]]) {
        detailError = ""
        do {
            guard let root = try await fetchJSON(action: "get_series_info", extra: ["series_id": seriesID]) as? [String: Any] else {
                throw AppFailure("The provider returned invalid series details.")
            }
            try Task.checkCancellation()
            return Self.parseDetail(root)
        } catch {
            if !Task.isCancelled { detailError = error.localizedDescription }
            return ([], [:])
        }
    }
    /// Detail load for a series list item: resolves the owning provider in
    /// combined mode, otherwise behaves exactly like loadDetail(seriesID:).
    func loadDetail(series: SeriesItem) async -> (seasons: [SeriesSeason], episodes: [Int: [SeriesEpisode]]) {
        detailError = ""
        do {
            let owner = provider(for: series)
            guard let root = try await fetchJSON(action: "get_series_info", extra: ["series_id": series.id], provider: owner) as? [String: Any] else {
                throw AppFailure("The provider returned invalid series details.")
            }
            try Task.checkCancellation()
            return Self.parseDetail(root)
        } catch {
            if !Task.isCancelled { detailError = error.localizedDescription }
            return ([], [:])
        }
    }

    func loadShowDetails(series: SeriesItem) async -> SeriesShowDetails? {
        detailError = ""
        do {
            guard let root = try await fetchJSON(action: "get_series_info", extra: ["series_id": series.id], provider: provider(for: series)) as? [String: Any] else {
                throw AppFailure("The provider returned invalid series details.")
            }
            try Task.checkCancellation()
            let parsed = Self.parseDetail(root)
            let info = root["info"] as? [String: Any] ?? [:]
            let backdropValue = info["backdrop_path"] ?? info["backdrop"]
            let backdropString = (backdropValue as? [String])?.first ?? ProviderFields.text(backdropValue)
            let backdrop = URL(string: backdropString).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let rawRating = ProviderFields.text(info["rating"] ?? info["rating_5based"])
            let rating = Double(rawRating).map { String(format: "%.1f", $0) }
                .map { "\($0) / 10" } ?? ""
            return SeriesShowDetails(
                seasons: parsed.seasons,
                episodes: parsed.episodes,
                synopsis: ProviderFields.text(info["plot"] ?? info["description"]),
                genre: ProviderFields.text(info["genre"]),
                year: ProviderFields.year(from: info),
                rating: rating,
                contentRating: ProviderFields.text(info["mpaa_rating"] ?? info["content_rating"] ?? info["age_rating"]),
                backdrop: backdrop
            )
        } catch {
            if !Task.isCancelled { detailError = error.localizedDescription }
            return nil
        }
    }

    func loadShowDetails(variants: [SeriesItem], progress: ((Int, Int) -> Void)? = nil) async -> [(SeriesItem, SeriesShowDetails)] {
        guard !variants.isEmpty else { return [] }
        var loaded: [Int: (SeriesItem, SeriesShowDetails)] = [:]
        var completed = 0
        await withTaskGroup(of: (Int, SeriesItem, SeriesShowDetails?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let series = variants[index]
                group.addTask { [self] in (index, series, await loadShowDetails(series: series)) }
            }
            while next < min(3, variants.count) { enqueue(next); next += 1 }
            while let (index, series, details) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                completed += 1
                if let details { loaded[index] = (series, details) }
                progress?(completed, variants.count)
                if next < variants.count { enqueue(next); next += 1 }
            }
        }
        return loaded.keys.sorted().compactMap { loaded[$0] }
    }
    static func parseDetail(_ root: [String: Any]) -> (seasons: [SeriesSeason], episodes: [Int: [SeriesEpisode]]) {
        var seasons: [SeriesSeason] = []
        if let rawSeasons = root["seasons"] as? [[String: Any]] {
            for row in rawSeasons {
                let number = Int(String(describing: row["season_number"] ?? "")) ?? 0
                guard number > 0 else { continue }
                seasons.append(SeriesSeason(number: number,
                                        name: row["name"] as? String ?? "Season \(number)"))
            }
        }
        seasons.sort { $0.number < $1.number }
        var episodes: [Int: [SeriesEpisode]] = [:]
        if let rawEpisodes = root["episodes"] as? [String: Any] {
            for (seasonKey, value) in rawEpisodes {
                guard let seasonNumber = Int(seasonKey),
                      let rows = value as? [[String: Any]] else { continue }
                var list: [SeriesEpisode] = []
                var seen = Set<String>()
                for row in rows {
                    let id = row["id"].map { String(describing: $0) } ?? ""
                    guard !id.isEmpty, id.allSatisfy(\.isNumber), seen.insert(id).inserted else { continue }
                    let number = Int(String(describing: row["episode_num"] ?? "")) ?? 0
                    let info = row["info"] as? [String: Any]
                    let ext = ((row["container_extension"] as? String) ?? (info?["container_extension"] as? String) ?? "mp4").lowercased()
                    let allowed = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "m3u8"]
                    let rawDuration = ProviderFields.text(info?["duration_secs"] ?? row["duration_secs"])
                    let duration = Int(rawDuration) ?? Self.durationSeconds(ProviderFields.text(info?["duration"] ?? row["duration"]))
                    let thumbnail = validURL(ProviderFields.text(info?["movie_image"] ?? info?["cover_big"] ?? row["movie_image"]))
                    list.append(SeriesEpisode(id: id,
                                          number: number,
                                          title: row["title"] as? String ?? "Episode \(number)",
                                          ext: allowed.contains(ext) ? ext : "mp4",
                                          thumbnail: thumbnail,
                                          synopsis: ProviderFields.text(info?["plot"] ?? info?["description"]),
                                          durationSeconds: max(0, duration)))
                }
                episodes[seasonNumber] = list.sorted { $0.number < $1.number }
            }
        }
        if seasons.isEmpty {
            seasons = episodes.keys.sorted().map { SeriesSeason(number: $0, name: "Season \($0)") }
        }
        return (seasons, episodes)
    }

    private static func durationSeconds(_ value: String) -> Int {
        let components = value.split(separator: ":").compactMap { Int($0) }
        guard !components.isEmpty else { return 0 }
        return components.suffix(3).reduce(0) { $0 * 60 + $1 }
    }

}

/// Which TV-show categories a search may request, and which titles match.
/// Manually hidden categories, non-English categories (when that toggle is on)
/// and categories tagged for another country (when U.S. only is on) are not
/// requested, so they cannot leak into results. That matches the category
/// toggles: U.S. only hides a category such as "UK|", it does not keep the
/// category in search because one title is tagged English.
enum SeriesSearchScope {
    static func categories(_ categories: [CatalogCategory], preferences: LibraryPreferences) -> [CatalogCategory] {
        categories.filter { preferences.allows($0, section: .series) }
    }

    static func merge(_ batches: [[SeriesItem]]) -> [SeriesItem] {
        var seen = Set<String>()
        return batches.flatMap { $0 }.filter { seen.insert($0.scopedID).inserted }
    }

    static func visible(_ items: [SeriesItem], categories: [CatalogCategory], preferences: LibraryPreferences) -> [SeriesItem] {
        let allowed = Set(self.categories(categories, preferences: preferences).map(\.id))
        return merge([items.filter { item in
            if item.categoryID.isEmpty { return preferences.acceptsSeries(item, categories: categories) }
            return allowed.contains(item.categoryID)
        }])
    }

    static func matching(_ items: [SeriesItem], query: String, categories: [CatalogCategory], preferences: LibraryPreferences) -> [SeriesItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return visible(items, categories: categories, preferences: preferences).filter { item in
            let title = preferences.seriesTitle(item)
            return item.name.localizedCaseInsensitiveContains(term) || title.localizedCaseInsensitiveContains(term)
        }
    }
}

// A search result represents a title; provider series IDs remain separate
// versions so selecting one always loads that provider's seasons/episodes.
struct SeriesSearchGroup: Identifiable {
    let id: String
    let title: String
    let year: String
    let variants: [SeriesItem]
    var preferred: SeriesItem { variants[0] }
}

enum SeriesSearchGrouping {
    private static let yearPattern = try! NSRegularExpression(pattern: #"\s*[\(\[]((?:19|20)\d{2})[\)\]]\s*"#)
    private static let languageSuffix = try! NSRegularExpression(pattern: #"\s*(?:[\(\[](?:EN|ENG|ENGLISH|US|UK|AR|ES|FR|DE)[\)\]]|\b(?:EN|ENG|ENGLISH))\s*$"#, options: [.caseInsensitive])
    private static let languagePrefix = try! NSRegularExpression(pattern: #"^(?:EN|ENG|ENGLISH)\s+"#, options: [.caseInsensitive])

    private static func identity(_ item: SeriesItem) -> (title: String, key: String, year: String, normalized: String) {
        var title = NameCleaner.clean(item.name)
        var year = item.year.count >= 4 ? String(item.year.prefix(4)) : ""
        if Int(year).map({ (1900...2099).contains($0) }) != true { year = "" }
        if let match = yearPattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let range = Range(match.range(at: 1), in: title) { year = String(title[range]) }
        title = yearPattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: " ")
        title = languagePrefix.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        for _ in 0..<2 {
            title = languageSuffix.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if title.isEmpty { title = item.name }
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        // A verified provider metadata ID can group differently localized titles.
        // Otherwise keep unknown-year and known-year shows separate so an
        // unlabelled remake cannot be incorrectly merged with a dated one.
        let key = item.externalID.map { "external:\($0.lowercased())" } ?? "title:\(normalized):\(year)"
        return (title, key, year, normalized)
    }

    static func identityKey(_ item: SeriesItem) -> String { identity(item).key }

    /// Resolves every enabled catalog entry for a show. Unknown-year entries
    /// join a dated version only when the catalog has one unambiguous year for
    /// that title; conflicting provider metadata IDs are never merged.
    static func relatedVariants(to target: SeriesItem, among items: [SeriesItem]) -> [SeriesItem] {
        let targetIdentity = identity(target)
        let candidates = items.filter { identity($0).normalized == targetIdentity.normalized }
        let knownYears = Set(candidates.compactMap { candidate -> String? in
            let value = identity(candidate)
            return value.year.isEmpty ? nil : value.year
        })
        let canJoinUnknownYear = knownYears.count == 1
        let matches = candidates.filter { candidate in
            let value = identity(candidate)
            if let targetID = target.externalID, let candidateID = candidate.externalID,
               targetID.caseInsensitiveCompare(candidateID) != .orderedSame { return false }
            if !targetIdentity.year.isEmpty && !value.year.isEmpty {
                return targetIdentity.year == value.year
            }
            return canJoinUnknownYear
        }
        var seen = Set<String>()
        let result = matches.filter { seen.insert($0.scopedID).inserted }
        return result.isEmpty ? [target] : result
    }

    static func label(_ item: SeriesItem, categories: [CatalogCategory]) -> String {
        let category = categories.first { $0.id == item.categoryID }?.name ?? ""
        let raw = item.name + " | " + category
        var labels: [String] = []
        for code in ["US", "UK", "CA", "AU", "AR", "ES", "FR", "DE", "IT", "PT", "IN", "TR", "RU", "NL"] {
            if NameCleaner.hasSeparatedTag(raw, codes: code == "US" ? ["US", "USA", "U.S.", "U.S.A."] : [code]) { labels.append(code) }
        }
        if CategoryRegion.isEnglish(raw) { labels.append("EN · English") }
        if !labels.isEmpty { return labels.joined(separator: " · ") }
        return category.isEmpty ? "Available version" : category
    }

    private static func rank(_ item: SeriesItem, categories: [CatalogCategory]) -> Int {
        let text = label(item, categories: categories)
        if text.hasPrefix("US") { return 0 }
        if text.contains("EN · English") { return 1 }
        return 2
    }

    static func groups(_ items: [SeriesItem], categories: [CatalogCategory], preferences: LibraryPreferences) -> [SeriesSearchGroup] {
        var seen = Set<String>()
        var matched: [(item: SeriesItem, identity: (title: String, key: String, year: String, normalized: String))] = []
        for item in items {
            guard !Task.isCancelled else { return [] }
            guard preferences.acceptsSeries(item, categories: categories), seen.insert(item.scopedID).inserted else { continue }
            matched.append((item, identity(item)))
        }
        var grouped: [String: [SeriesItem]] = [:]
        for entry in matched {
            let identity = entry.identity
            grouped[identity.key, default: []].append(entry.item)
        }
        return grouped.compactMap { key, variants in
            let sorted = variants.sorted {
                let lhs = rank($0, categories: categories), rhs = rank($1, categories: categories)
                if lhs != rhs { return lhs < rhs }
                if ($0.poster != nil) != ($1.poster != nil) { return $0.poster != nil }
                return $0.scopedID < $1.scopedID
            }
            guard let preferred = sorted.first else { return nil }
            let preferredIdentity = identity(preferred)
            let year = sorted.compactMap { identity($0).year.isEmpty ? nil : identity($0).year }.first ?? preferredIdentity.year
            return SeriesSearchGroup(id: key, title: preferredIdentity.title, year: year, variants: sorted)
        }.sorted {
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if $0.year != $1.year { return $0.year < $1.year }
            return $0.id < $1.id
        }
    }

    static func matches(_ items: [SeriesItem], query: String, categories: [CatalogCategory], preferences: LibraryPreferences) -> [SeriesSearchGroup] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let normalizedQuery = searchNormalize(term)
        guard !normalizedQuery.isEmpty else { return [] }
        return groups(items, categories: categories, preferences: preferences)
            .compactMap { group -> (SeriesSearchGroup, Int)? in
                let titles = [group.title] + group.variants.map(\.name)
                let ranks = titles.map { searchRank($0, query: normalizedQuery) }
                guard let rank = ranks.min(), rank < 6 else { return nil }
                return (group, rank)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                let lhs = identity($0.0.preferred)
                let rhs = identity($1.0.preferred)
                if lhs.year != rhs.year { return lhs.year > rhs.year }
                return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private static func searchNormalize(_ value: String) -> String {
        let title = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalars = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Lower score is better: exact title, yearless exact, prefix, whole word,
    /// partial phrase, then conservative single-edit fuzzy matching.
    private static func searchRank(_ rawTitle: String, query: String) -> Int {
        let title = searchNormalize(rawTitle)
        guard !title.isEmpty else { return Int.max }
        if title == query { return 0 }
        let yearless = searchNormalize(yearPattern.stringByReplacingMatches(in: rawTitle, range: NSRange(rawTitle.startIndex..., in: rawTitle), withTemplate: " "))
        if yearless == query { return 1 }
        if title.hasPrefix(query + " ") || yearless.hasPrefix(query + " ") { return 2 }
        let words = (title + " " + yearless).split(separator: " ").map(String.init)
        if words.contains(query) { return 3 }
        if title.contains(query) || yearless.contains(query) { return 4 }
        guard query.count >= 5 else { return Int.max }
        return words.contains(where: { editDistanceAtMostOne($0, query) }) ? 5 : Int.max
    }

    private static func editDistanceAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 }
            else if b.count > a.count { j += 1 }
            else { i += 1; j += 1 }
        }
        if i < a.count || j < b.count { edits += 1 }
        return edits <= 1
    }
}
