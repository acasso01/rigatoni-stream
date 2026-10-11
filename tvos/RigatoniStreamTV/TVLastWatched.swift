import Foundation

// Last-watched persistence feeding the Home tab's "Last watched" section.
// Stored in UserDefaults, namespaced per signed-in account and provider. Never stores
// credentials or stream URLs — playback URLs are rebuilt from the provider
// at play time (direct URLs via Provider, gateway via opaque tickets).
struct TVWatchedRecord: Codable, Identifiable {
    var id: String { kind + ":" + itemID }
    /// "live" | "movie" | "series"
    let kind: String
    let itemID: String
    let name: String
    let ext: String
    let categoryID: String
    let watchedAt: Date
}

@MainActor
enum TVLastWatched {
    private static let maxItems = 24

    static func key(model: AppModel) -> String? {
        model.preferenceKey.map { $0 + "-last-watched" }
    }

    static func record(kind: String, item: CatalogItem, model: AppModel) {
        guard let key = key(model: model) else { return }
        let entry = TVWatchedRecord(
            kind: kind,
            itemID: item.id,
            name: item.name,
            ext: item.fileExtension,
            categoryID: item.categoryID,
            watchedAt: Date()
        )
        var items = items(model: model).filter { $0.id != entry.id }
        items.insert(entry, at: 0)
        items = Array(items.prefix(maxItems))
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func items(model: AppModel) -> [TVWatchedRecord] {
        guard let key = key(model: model),
              let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([TVWatchedRecord].self, from: data)
        else { return [] }
        return items.sorted { $0.watchedAt > $1.watchedAt }
    }
}
