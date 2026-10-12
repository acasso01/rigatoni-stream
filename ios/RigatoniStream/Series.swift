import SwiftUI

// Shared, bounded Xtream series access for iPhone and Apple TV.
// Provider credentials stay in memory and the existing encrypted account vault.
struct SeriesItem: Identifiable {
    let id: String
    let name: String
    let poster: URL?
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
            .enumerated().map { index, value in
                index == 0 && !base.isEmpty ? value : (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            }
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
        return try await Task.detached(priority: .userInitiated) { try JSONSerialization.jsonObject(with: data) }.value
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
                return SeriesItem(id: id,
                                name: row["name"] as? String ?? "Untitled",
                                poster: validURL(row["cover"] as? String))
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
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
