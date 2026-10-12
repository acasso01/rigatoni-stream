import Foundation

// Favorites powering the Saved tab. Stored in UserDefaults, namespaced per
// provider host. Never stores credentials or stream URLs — playback URLs
// are rebuilt from the provider at play time.
struct TVFavoriteRecord: Codable, Identifiable {
    var id: String { kind + ":" + itemID }
    /// "live" | "movie" | "series"
    let kind: String
    let itemID: String
    let name: String
    let ext: String
    let poster: String?
    let addedAt: Date
}

enum TVFavorites {
    static func key(provider: Provider) -> String {
        let host = (try? provider.baseURL().host) ?? "unknown"
        return "tvos-favorites-" + host
    }

    static func items(provider: Provider) -> [TVFavoriteRecord] {
        guard let data = UserDefaults.standard.data(forKey: key(provider: provider)),
              let items = try? JSONDecoder().decode([TVFavoriteRecord].self, from: data)
        else { return [] }
        return items.sorted { $0.addedAt > $1.addedAt }
    }

    static func contains(id: String, kind: String, provider: Provider) -> Bool {
        items(provider: provider).contains { $0.id == kind + ":" + id }
    }

    static func contains(item: CatalogItem, provider: Provider) -> Bool {
        contains(id: item.id,
                 kind: item.kind == .live ? "live" : "movie",
                 provider: provider)
    }

    @discardableResult
    static func toggle(item: CatalogItem, provider: Provider) -> Bool {
        toggle(id: item.id,
               name: item.name,
               kind: item.kind == .live ? "live" : "movie",
               ext: item.fileExtension,
               poster: item.poster?.absoluteString,
               provider: provider)
    }

    @discardableResult
    static func toggleSeries(_ series: TVSeries, provider: Provider) -> Bool {
        toggle(id: series.id,
               name: series.name,
               kind: "series",
               ext: "mp4",
               poster: series.poster?.absoluteString,
               provider: provider)
    }

    /// Toggles the record. Returns true when it is now a favorite.
    @discardableResult
    static func toggle(id: String, name: String, kind: String,
                               ext: String, poster: String?,
                               provider: Provider) -> Bool {
        var list = items(provider: provider)
        let recordID = kind + ":" + id
        if let index = list.firstIndex(where: { $0.id == recordID }) {
            list.remove(at: index)
            persist(list, provider: provider)
            return false
        }
        list.insert(TVFavoriteRecord(kind: kind, itemID: id, name: name,
                                     ext: ext, poster: poster, addedAt: Date()),
                    at: 0)
        persist(list, provider: provider)
        return true
    }

    private static func persist(_ list: [TVFavoriteRecord], provider: Provider) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key(provider: provider))
        }
    }
}
