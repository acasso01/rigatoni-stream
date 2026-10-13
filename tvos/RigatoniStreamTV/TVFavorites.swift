import Foundation

typealias TVFavoriteRecord = SavedRecord
@MainActor enum TVFavorites {
    private static var artwork: [String: URL] = [:]
    static func reset() {
        artwork.removeAll()
        for key in UserDefaults.standard.dictionaryRepresentation().keys where (key.hasPrefix("tvos-favorites-") || key.hasPrefix("tvos-last-watched-")) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    static func key(model: AppModel) -> String? { model.preferenceKey.map { $0 + "-favorites-v2" } }
    static func items(model: AppModel) -> [SavedRecord] { SavedCollection.items(key: key(model: model)) }
    static func contains(id: String, kind: String, providerID: UUID? = nil, model: AppModel) -> Bool {
        items(model: model).contains { $0.id == SavedRecord.makeID(kind: kind, itemID: id, providerID: providerID) }
    }
    static func contains(item: CatalogItem, model: AppModel) -> Bool {
        contains(id: item.id, kind: item.kind == .live ? "live" : "movie", providerID: item.providerID, model: model)
    }
    static func poster(_ record: SavedRecord, model: AppModel) -> URL? {
        key(model: model).flatMap { artwork[$0 + ":" + record.id] }
    }
    @discardableResult static func toggle(item: CatalogItem, model: AppModel) -> Bool {
        toggle(id: item.id, name: item.name, kind: item.kind == .live ? "live" : "movie", ext: item.fileExtension, categoryID: item.categoryID, poster: item.poster, providerID: item.providerID, model: model)
    }
    @discardableResult static func toggleSeries(_ series: SeriesItem, model: AppModel) -> Bool {
        toggle(id: series.id, name: series.name, kind: "series", ext: "mp4", categoryID: "", poster: series.poster, providerID: series.providerID, model: model)
    }
    @discardableResult static func toggle(id: String, name: String, kind: String, ext: String, categoryID: String, poster: URL?, providerID: UUID? = nil, model: AppModel) -> Bool {
        guard let key = key(model: model) else { return false }
        let record = SavedRecord(kind: kind, itemID: id, name: name, ext: ext, categoryID: categoryID, addedAt: Date(), providerID: providerID)
        let adding = SavedCollection.toggle(record, key: key)
        let artKey = key + ":" + record.id
        if adding { artwork[artKey] = poster } else { artwork[artKey] = nil }
        if artwork.count > 500 { artwork.removeAll() }
        return adding
    }
}
