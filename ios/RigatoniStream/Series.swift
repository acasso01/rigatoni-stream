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
            series = Self.parseSeries(rows, providerID: tag)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Loads every series for search using the same category-scoped requests
    /// as the TV Shows browser. Many Xtream providers reject an unscoped
    /// `get_series` request, so search must not depend on that optional form.
    func loadAllSeries(includeNonEnglish: Bool = false, update: (([SeriesItem], String) -> Void)? = nil) async -> [SeriesItem] {
        error = ""
        if let unavailableReason { error = unavailableReason; return [] }
        await loadCategories()
        guard !Task.isCancelled, error.isEmpty else { return [] }
        // Bound provider traffic while letting results arrive from every
        // category, including shows near the end of a large catalog.
        let searchableCategories = categories.filter {
            includeNonEnglish || !model.preferences.hideNonEnglishCategories || !CategoryRegion.isNonEnglish($0.name)
        }
        let requests = searchableCategories.enumerated().map { index, category -> (Int, String, Provider?, UUID?) in
            if model.libraryMode == .combined,
               let (id, raw) = CatalogItem.splitNamespaced(category.id),
               let profile = model.vault.profiles.first(where: { $0.id == id }) {
                return (index, raw, profile.provider, id)
            }
            return (index, category.id, nil, nil)
        }
        var batches: [Int: [SeriesItem]] = [:]
        var failures = 0
        var completed = 0
        var all: [SeriesItem] = []
        await withTaskGroup(of: (Int, [SeriesItem]?).self) { group in
            var next = 0
            func enqueue(_ request: (Int, String, Provider?, UUID?)) {
                group.addTask { [self] in
                    do {
                        try Task.checkCancellation()
                        guard let rows = try await fetchJSON(action: "get_series", extra: ["category_id": request.1], provider: request.2) as? [[String: Any]] else {
                            return (request.0, nil)
                        }
                        try Task.checkCancellation()
                        return (request.0, Self.parseSeries(rows, providerID: request.3))
                    } catch { return (request.0, nil) }
                }
            }
            for request in requests.prefix(3) { enqueue(request); next += 1 }
            while let (index, items) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                completed += 1
                if let items { batches[index] = items } else { failures += 1 }
                var seen = Set<String>()
                all = batches.keys.sorted().flatMap { batches[$0] ?? [] }.filter { seen.insert($0.scopedID).inserted }
                update?(all, "\(completed) of \(requests.count) categories")
                if next < requests.count { enqueue(requests[next]); next += 1 }
            }
        }
        guard !Task.isCancelled else { return [] }
        if failures > 0 {
            error = "Could not search \(failures) TV show categor\(failures == 1 ? "y" : "ies"). Retry to include the missing results."
        }
        return all
    }

    nonisolated static func parseSeries(_ rows: [[String: Any]], providerID: UUID? = nil) -> [SeriesItem] {
        rows.compactMap { row in
            let id = row["series_id"].map { String(describing: $0) } ?? ""
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            let rawCategory = ProviderFields.text(row["category_id"])
            let categoryID = rawCategory.isEmpty ? "" : CatalogItem.namespaced(providerID: providerID, id: rawCategory)
            return SeriesItem(id: id,
                            name: row["name"] as? String ?? "Untitled",
                            poster: validURL(row["cover"] as? String),
                            providerID: providerID,
                            categoryID: categoryID,
                            added: ProviderFields.added(from: row),
                            rating: ProviderFields.rating(from: row),
                            year: ProviderFields.year(from: row))
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
                    list.append(SeriesEpisode(id: id,
                                          number: number,
                                          title: row["title"] as? String ?? "Episode \(number)",
                                          ext: allowed.contains(ext) ? ext : "mp4"))
                }
                episodes[seasonNumber] = list.sorted { $0.number < $1.number }
            }
        }
        if seasons.isEmpty {
            seasons = episodes.keys.sorted().map { SeriesSeason(number: $0, name: "Season \($0)") }
        }
        return (seasons, episodes)
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

    private static func identity(_ item: SeriesItem) -> (title: String, key: String, year: String) {
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
        let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return (title, key, year)
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

    static func matches(_ items: [SeriesItem], query: String, categories: [CatalogCategory], preferences: LibraryPreferences) -> [SeriesSearchGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        var matched: [(item: SeriesItem, identity: (title: String, key: String, year: String))] = []
        for item in items {
            guard !Task.isCancelled else { return [] }
            guard preferences.categoryVisible(item.categoryID, section: .series), seen.insert(item.scopedID).inserted,
                  item.name.localizedStandardContains(query) else { continue }
            matched.append((item, identity(item)))
        }
        var years: [String: Set<String>] = [:]
        for entry in matched where !entry.identity.year.isEmpty { years[entry.identity.key, default: []].insert(entry.identity.year) }
        var grouped: [String: [SeriesItem]] = [:]
        var titles: [String: (String, String)] = [:]
        for entry in matched {
            let identity = entry.identity
            // A missing year may join one known edition, but never bridges
            // two remakes with the same name and different known years.
            let year = identity.year.isEmpty && years[identity.key]?.count == 1 ? years[identity.key]!.first! : identity.year
            let key = identity.key + ":" + year
            grouped[key, default: []].append(entry.item)
            titles[key] = (identity.title, year)
        }
        return grouped.compactMap { key, variants in
            guard variants.contains(where: { preferences.acceptsSeries($0, categories: categories) }), let title = titles[key] else { return nil }
            let sorted = variants.sorted {
                let lhs = rank($0, categories: categories), rhs = rank($1, categories: categories)
                if lhs != rhs { return lhs < rhs }
                if ($0.poster != nil) != ($1.poster != nil) { return $0.poster != nil }
                return $0.scopedID < $1.scopedID
            }
            return SeriesSearchGroup(id: key, title: title.0, year: title.1, variants: sorted)
        }.sorted {
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.year < $1.year
        }
    }
}
