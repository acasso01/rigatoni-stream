import Foundation

// Only catalog metadata is persisted. Artwork and playback URLs stay in memory.
struct SavedRecord: Codable, Identifiable {
    var id: String { kind + ":" + itemID }
    let kind: String
    let itemID: String
    let name: String
    let ext: String
    let categoryID: String
    let addedAt: Date
}
enum SavedCollection {
    static func items(key: String?) -> [SavedRecord] {
        guard let key, let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([SavedRecord].self, from: data) else { return [] }
        return Array(items.sorted { $0.addedAt > $1.addedAt }.prefix(500))
    }
    @discardableResult static func toggle(_ record: SavedRecord, key: String?) -> Bool {
        guard let key else { return false }
        var items = items(key: key)
        let adding = !items.contains { $0.id == record.id }
        items.removeAll { $0.id == record.id }
        if adding { items.insert(record, at: 0) }
        if let data = try? JSONEncoder().encode(Array(items.prefix(500))) { UserDefaults.standard.set(data, forKey: key) }
        return adding
    }
}
