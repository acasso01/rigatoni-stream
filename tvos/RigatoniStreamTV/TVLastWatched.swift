import Foundation

// Last-watched persistence feeding the Home tab's "Last watched" section.
// Stored in UserDefaults, namespaced per provider host. Never stores
// credentials or stream URLs — playback URLs are rebuilt from the provider
// at play time (direct URLs via Provider, gateway via opaque tickets).
struct TVWatchedRecord: Codable, Identifiable {
    var id: String { kind + ":" + itemID }
    /// "live" | "movie" | "series"
    let kind: String
    let itemID: String
    let name: String
    let ext: String
    let poster: String?
    let watchedAt: Date
}

enum TVLastWatched {
    private static let maxItems = 24

    static func key(provider: Provider) -> String {
        let host = (try? provider.baseURL().host) ?? "unknown"
        return "tvos-last-watched-" + host
    }

    static func record(kind: String, item: CatalogItem, provider: Provider) {
        let entry = TVWatchedRecord(
            kind: kind,
            itemID: item.id,
            name: item.name,
            ext: item.fileExtension,
            poster: item.poster?.absoluteString,
            watchedAt: Date()
        )
        var items = items(provider: provider).filter { $0.id != entry.id }
        items.insert(entry, at: 0)
        items = Array(items.prefix(maxItems))
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key(provider: provider))
        }
    }

    static func items(provider: Provider) -> [TVWatchedRecord] {
        guard let data = UserDefaults.standard.data(forKey: key(provider: provider)),
              let items = try? JSONDecoder().decode([TVWatchedRecord].self, from: data)
        else { return [] }
        return items.sorted { $0.watchedAt > $1.watchedAt }
    }
}
