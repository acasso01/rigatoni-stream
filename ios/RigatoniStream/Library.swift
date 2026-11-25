import Foundation
import ImageIO
import SwiftUI
import CryptoKit
import SQLite3

/// A rebuildable, provider-scoped cache for catalog metadata. Credentials and
/// playback URLs are deliberately excluded; only titles, category IDs and
/// artwork references needed to render/search the library are persisted.
actor PersistentCatalogIndex {
    static let shared = PersistentCatalogIndex()

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let cacheLifetime: TimeInterval = 4 * 60 * 60

    init(databaseURL: URL? = nil) {
        let url: URL
        if let databaseURL { url = databaseURL }
        else {
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            url = root.appendingPathComponent("AntStreamsCatalog.sqlite")
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 4_000)
        _ = run("PRAGMA journal_mode=WAL")
        _ = run("PRAGMA synchronous=NORMAL")
        _ = run("CREATE TABLE IF NOT EXISTS catalog_categories (scope TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(scope,kind,id))")
        _ = run("CREATE TABLE IF NOT EXISTS catalog_category_state (scope TEXT NOT NULL, kind TEXT NOT NULL, category_id TEXT NOT NULL, item_count INTEGER NOT NULL, PRIMARY KEY(scope,kind,category_id))")
        _ = run("CREATE TABLE IF NOT EXISTS catalog_items (scope TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, year TEXT NOT NULL, category_id TEXT NOT NULL, poster TEXT, ext TEXT NOT NULL, number TEXT NOT NULL, added INTEGER NOT NULL, rating REAL NOT NULL, provider_id TEXT, PRIMARY KEY(scope,kind,id))")
        _ = run("CREATE INDEX IF NOT EXISTS catalog_items_category ON catalog_items(scope,kind,category_id)")
        _ = run("CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(scope UNINDEXED, kind UNINDEXED, item_id UNINDEXED, title, category, tokenize='unicode61 remove_diacritics 2')")
        _ = run("CREATE TABLE IF NOT EXISTS catalog_snapshots (scope TEXT NOT NULL, kind TEXT NOT NULL, signature TEXT NOT NULL, updated REAL NOT NULL, PRIMARY KEY(scope,kind))")
        _ = run("CREATE TABLE IF NOT EXISTS series_items (scope TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, year TEXT NOT NULL, category_id TEXT NOT NULL, poster TEXT, added INTEGER NOT NULL, rating REAL NOT NULL, external_id TEXT, provider_id TEXT, PRIMARY KEY(scope,id))")
        _ = run("CREATE INDEX IF NOT EXISTS series_items_category ON series_items(scope,category_id)")
        _ = run("CREATE VIRTUAL TABLE IF NOT EXISTS series_fts USING fts5(scope UNINDEXED, item_id UNINDEXED, title, category, tokenize='unicode61 remove_diacritics 2')")
        _ = run("CREATE TABLE IF NOT EXISTS series_category_state (scope TEXT NOT NULL, category_id TEXT NOT NULL, item_count INTEGER NOT NULL, PRIMARY KEY(scope,category_id))")
        _ = run("CREATE TABLE IF NOT EXISTS series_snapshots (scope TEXT PRIMARY KEY, signature TEXT NOT NULL, updated REAL NOT NULL)")
        // Best-effort schema upgrades for caches created by older app builds.
        _ = run("ALTER TABLE catalog_categories ADD COLUMN updated REAL NOT NULL DEFAULT 0")
        _ = run("ALTER TABLE catalog_category_state ADD COLUMN updated REAL NOT NULL DEFAULT 0")
        _ = run("ALTER TABLE series_category_state ADD COLUMN updated REAL NOT NULL DEFAULT 0")
    }

    deinit { sqlite3_close(db) }

    private func run(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func statement(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK else { return nil }
        return value
    }

    private func text(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func isFresh(_ timestamp: Double) -> Bool {
        timestamp > 0 && Date().timeIntervalSince1970 - timestamp < cacheLifetime
    }

    static func signature(_ ids: [String]) -> String {
        let source = ids.sorted().joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func loadCategories(scope: String, kind: String) -> [CatalogCategory]? {
        guard let statement = statement("SELECT id,name,updated FROM catalog_categories WHERE scope=? AND kind=? ORDER BY rowid") else { return nil }
        defer { sqlite3_finalize(statement) }
        text(scope, at: 1, in: statement); text(kind, at: 2, in: statement)
        var result: [CatalogCategory] = []; var fresh = true
        while sqlite3_step(statement) == SQLITE_ROW {
            fresh = fresh && isFresh(sqlite3_column_double(statement, 2))
            result.append(CatalogCategory(id: string(statement, 0), name: string(statement, 1)))
        }
        return result.isEmpty || !fresh ? nil : result
    }

    func storeCategories(_ categories: [CatalogCategory], scope: String, kind: String) {
        guard run("BEGIN IMMEDIATE") else { return }
        defer { _ = run("COMMIT") }
        guard let remove = statement("DELETE FROM catalog_categories WHERE scope=? AND kind=?") else { return }
        text(scope, at: 1, in: remove); text(kind, at: 2, in: remove); _ = sqlite3_step(remove); sqlite3_finalize(remove)
        guard let insert = statement("INSERT OR REPLACE INTO catalog_categories(scope,kind,id,name,updated) VALUES(?,?,?,?,?)") else { return }
        defer { sqlite3_finalize(insert) }
        for category in categories {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            text(scope, at: 1, in: insert); text(kind, at: 2, in: insert)
            text(category.id, at: 3, in: insert); text(category.name, at: 4, in: insert)
            sqlite3_bind_double(insert, 5, Date().timeIntervalSince1970)
            _ = sqlite3_step(insert)
        }
    }

    func hasCategory(scope: String, kind: String, id: String) -> Bool {
        guard let statement = statement("SELECT updated FROM catalog_category_state WHERE scope=? AND kind=? AND category_id=? LIMIT 1") else { return false }
        defer { sqlite3_finalize(statement) }
        text(scope, at: 1, in: statement); text(kind, at: 2, in: statement); text(id, at: 3, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW && isFresh(sqlite3_column_double(statement, 0))
    }

    func loadItems(scope: String, kind: LibraryKind, categoryID: String) -> [CatalogItem]? {
        guard hasCategory(scope: scope, kind: kind.rawValue, id: categoryID),
              let statement = statement("SELECT id,title,year,category_id,poster,ext,number,added,rating,provider_id FROM catalog_items WHERE scope=? AND kind=? AND category_id=?") else { return nil }
        defer { sqlite3_finalize(statement) }
        text(scope, at: 1, in: statement); text(kind.rawValue, at: 2, in: statement); text(categoryID, at: 3, in: statement)
        return readItems(statement, kind: kind)
    }

    func loadSnapshot(scope: String, kind: LibraryKind, categoryIDs: [String]) -> [CatalogItem]? {
        let sig = Self.signature(categoryIDs)
        guard let state = statement("SELECT signature,updated FROM catalog_snapshots WHERE scope=? AND kind=?") else { return nil }
        text(scope, at: 1, in: state); text(kind.rawValue, at: 2, in: state)
        let matches = sqlite3_step(state) == SQLITE_ROW && string(state, 0) == sig && isFresh(sqlite3_column_double(state, 1))
        sqlite3_finalize(state)
        guard matches else { return nil }
        guard !categoryIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: categoryIDs.count).joined(separator: ",")
        guard let query = statement("SELECT id,title,year,category_id,poster,ext,number,added,rating,provider_id FROM catalog_items WHERE scope=? AND kind=? AND category_id IN (\(placeholders))") else { return nil }
        defer { sqlite3_finalize(query) }
        text(scope, at: 1, in: query); text(kind.rawValue, at: 2, in: query)
        for (offset, id) in categoryIDs.enumerated() { text(id, at: Int32(offset + 3), in: query) }
        return readItems(query, kind: kind)
    }

    private func readItems(_ query: OpaquePointer, kind: LibraryKind) -> [CatalogItem] {
        var items: [CatalogItem] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let provider = UUID(uuidString: string(query, 9))
            let poster = URL(string: string(query, 4)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            items.append(CatalogItem(id: string(query, 0), name: string(query, 1), kind: kind,
                fileExtension: string(query, 5), poster: poster, playbackURL: nil,
                categoryID: string(query, 3), number: string(query, 6), added: Int(sqlite3_column_int64(query, 7)),
                rating: sqlite3_column_double(query, 8), year: string(query, 2), providerID: provider))
        }
        return items
    }

    func storeItems(_ items: [CatalogItem], scope: String, kind: LibraryKind, categoryID: String?, provider: Provider) {
        guard let db, run("BEGIN IMMEDIATE") else { return }
        defer { _ = run("COMMIT") }
        if let categoryID, let removal = statement("SELECT id FROM catalog_items WHERE scope=? AND kind=? AND category_id=?") {
            text(scope, at: 1, in: removal); text(kind.rawValue, at: 2, in: removal); text(categoryID, at: 3, in: removal)
            var ids: [String] = []; while sqlite3_step(removal) == SQLITE_ROW { ids.append(string(removal, 0)) }
            sqlite3_finalize(removal)
            for id in ids { deleteFTS(table: "catalog_fts", scope: scope, kind: kind.rawValue, id: id) }
            if let delete = statement("DELETE FROM catalog_items WHERE scope=? AND kind=? AND category_id=?") {
                text(scope, at: 1, in: delete); text(kind.rawValue, at: 2, in: delete); text(categoryID, at: 3, in: delete); _ = sqlite3_step(delete); sqlite3_finalize(delete)
            }
        }
        guard let insert = statement("INSERT OR REPLACE INTO catalog_items(scope,kind,id,title,year,category_id,poster,ext,number,added,rating,provider_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)") else { return }
        defer { sqlite3_finalize(insert) }
        for item in items.prefix(CatalogIndex.maximumItems) {
            deleteFTS(table: "catalog_fts", scope: scope, kind: kind.rawValue, id: item.scopedID)
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            text(scope, at: 1, in: insert); text(kind.rawValue, at: 2, in: insert); text(item.scopedID, at: 3, in: insert)
            text(item.name, at: 4, in: insert); text(item.year, at: 5, in: insert); text(item.categoryID, at: 6, in: insert)
            text(safePoster(item.poster, provider: provider), at: 7, in: insert); text(item.fileExtension, at: 8, in: insert)
            text(item.number, at: 9, in: insert); sqlite3_bind_int64(insert, 10, Int64(item.added)); sqlite3_bind_double(insert, 11, item.rating)
            text(item.providerID?.uuidString, at: 12, in: insert); _ = sqlite3_step(insert)
            insertFTS(table: "catalog_fts", scope: scope, kind: kind.rawValue, id: item.scopedID, title: item.name, category: "")
        }
        if let categoryID, let state = statement("INSERT OR REPLACE INTO catalog_category_state(scope,kind,category_id,item_count,updated) VALUES(?,?,?,?,?)") {
            text(scope, at: 1, in: state); text(kind.rawValue, at: 2, in: state); text(categoryID, at: 3, in: state)
            sqlite3_bind_int64(state, 4, Int64(items.count)); sqlite3_bind_double(state, 5, Date().timeIntervalSince1970); _ = sqlite3_step(state); sqlite3_finalize(state)
        }
        _ = db
    }

    func markSnapshot(scope: String, kind: LibraryKind, categoryIDs: [String], items: [CatalogItem], provider: Provider) {
        if let rows = statement("SELECT id FROM catalog_items WHERE scope=? AND kind=?") {
            text(scope, at: 1, in: rows); text(kind.rawValue, at: 2, in: rows)
            var oldIDs: [String] = []; while sqlite3_step(rows) == SQLITE_ROW { oldIDs.append(string(rows, 0)) }
            sqlite3_finalize(rows)
            for id in oldIDs { deleteFTS(table: "catalog_fts", scope: scope, kind: kind.rawValue, id: id) }
        }
        if let rows = statement("DELETE FROM catalog_items WHERE scope=? AND kind=?") {
            text(scope, at: 1, in: rows); text(kind.rawValue, at: 2, in: rows); _ = sqlite3_step(rows); sqlite3_finalize(rows)
        }
        if let rows = statement("DELETE FROM catalog_category_state WHERE scope=? AND kind=?") {
            text(scope, at: 1, in: rows); text(kind.rawValue, at: 2, in: rows); _ = sqlite3_step(rows); sqlite3_finalize(rows)
        }
        storeItems(items, scope: scope, kind: kind, categoryID: nil, provider: provider)
        var counts: [String: Int] = [:]
        for item in items { counts[item.categoryID, default: 0] += 1 }
        if let state = statement("INSERT OR REPLACE INTO catalog_category_state(scope,kind,category_id,item_count,updated) VALUES(?,?,?,?,?)") {
            defer { sqlite3_finalize(state) }
            for (categoryID, count) in counts {
                sqlite3_reset(state); sqlite3_clear_bindings(state)
                text(scope, at: 1, in: state); text(kind.rawValue, at: 2, in: state); text(categoryID, at: 3, in: state)
                sqlite3_bind_int64(state, 4, Int64(count)); sqlite3_bind_double(state, 5, Date().timeIntervalSince1970); _ = sqlite3_step(state)
            }
        }
        guard let statement = statement("INSERT OR REPLACE INTO catalog_snapshots(scope,kind,signature,updated) VALUES(?,?,?,?)") else { return }
        text(scope, at: 1, in: statement); text(kind.rawValue, at: 2, in: statement); text(Self.signature(categoryIDs), at: 3, in: statement)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970); _ = sqlite3_step(statement); sqlite3_finalize(statement)
    }

    func searchItems(scope: String, query: String, kinds: Set<LibraryKind>, categoryIDs: [String], limit: Int = 300) -> [CatalogItem] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty, !kinds.isEmpty, !categoryIDs.isEmpty else { return [] }
        let kindMarks = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        let categoryMarks = Array(repeating: "?", count: categoryIDs.count).joined(separator: ",")
        guard let statement = statement("SELECT c.id,c.title,c.year,c.category_id,c.poster,c.ext,c.number,c.added,c.rating,c.provider_id,c.kind FROM catalog_fts f JOIN catalog_items c ON c.scope=f.scope AND c.kind=f.kind AND c.id=f.item_id WHERE catalog_fts MATCH ? AND f.scope=? AND f.kind IN (\(kindMarks)) AND c.category_id IN (\(categoryMarks)) ORDER BY CASE WHEN lower(c.title)=lower(?) THEN 0 WHEN lower(c.title) LIKE lower(?) THEN 1 ELSE 2 END, c.title LIMIT ?") else { return [] }
        defer { sqlite3_finalize(statement) }
        text(match, at: 1, in: statement); text(scope, at: 2, in: statement)
        for (offset, kind) in kinds.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() { text(kind.rawValue, at: Int32(offset + 3), in: statement) }
        let firstCategoryIndex = 3 + kinds.count
        for (offset, categoryID) in categoryIDs.enumerated() { text(categoryID, at: Int32(firstCategoryIndex + offset), in: statement) }
        let exactIndex = Int32(firstCategoryIndex + categoryIDs.count); text(query, at: exactIndex, in: statement); text(query + "%", at: exactIndex + 1, in: statement)
        sqlite3_bind_int(statement, exactIndex + 2, Int32(max(1, min(limit, 1000))))
        var results: [CatalogItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = LibraryKind(rawValue: string(statement, 10)) else { continue }
            let poster = URL(string: string(statement, 4))
            results.append(CatalogItem(id: string(statement, 0), name: string(statement, 1), kind: kind, fileExtension: string(statement, 5), poster: poster, categoryID: string(statement, 3), number: string(statement, 6), added: Int(sqlite3_column_int64(statement, 7)), rating: sqlite3_column_double(statement, 8), year: string(statement, 2), providerID: UUID(uuidString: string(statement, 9))))
        }
        return results
    }

    func loadSeries(scope: String, categoryID: String) -> [SeriesItem]? {
        guard let state = statement("SELECT updated FROM series_category_state WHERE scope=? AND category_id=?") else { return nil }
        text(scope, at: 1, in: state); text(categoryID, at: 2, in: state)
        let loaded = sqlite3_step(state) == SQLITE_ROW && isFresh(sqlite3_column_double(state, 0)); sqlite3_finalize(state)
        guard loaded, let query = statement("SELECT id,title,year,category_id,poster,added,rating,external_id,provider_id FROM series_items WHERE scope=? AND category_id=?") else { return nil }
        defer { sqlite3_finalize(query) }
        text(scope, at: 1, in: query); text(categoryID, at: 2, in: query)
        return readSeries(query)
    }

    func loadSeriesSnapshot(scope: String, categoryIDs: [String]) -> [SeriesItem]? {
        guard let state = statement("SELECT signature,updated FROM series_snapshots WHERE scope=?") else { return nil }
        text(scope, at: 1, in: state)
        let matches = sqlite3_step(state) == SQLITE_ROW && string(state, 0) == Self.signature(categoryIDs) && isFresh(sqlite3_column_double(state, 1))
        sqlite3_finalize(state)
        guard matches, !categoryIDs.isEmpty else { return matches ? [] : nil }
        let marks = Array(repeating: "?", count: categoryIDs.count).joined(separator: ",")
        guard let query = statement("SELECT id,title,year,category_id,poster,added,rating,external_id,provider_id FROM series_items WHERE scope=? AND category_id IN (\(marks))") else { return nil }
        defer { sqlite3_finalize(query) }
        text(scope, at: 1, in: query)
        for (offset, id) in categoryIDs.enumerated() { text(id, at: Int32(offset + 2), in: query) }
        return readSeries(query)
    }

    func hasSeriesSnapshot(scope: String, categoryIDs: [String]) -> Bool {
        guard let state = statement("SELECT signature,updated FROM series_snapshots WHERE scope=?") else { return false }
        defer { sqlite3_finalize(state) }
        text(scope, at: 1, in: state)
        return sqlite3_step(state) == SQLITE_ROW && string(state, 0) == Self.signature(categoryIDs) && isFresh(sqlite3_column_double(state, 1))
    }

    private func readSeries(_ query: OpaquePointer) -> [SeriesItem] {
        var values: [SeriesItem] = []
        while sqlite3_step(query) == SQLITE_ROW {
            values.append(SeriesItem(id: string(query, 0), name: string(query, 1),
                poster: URL(string: string(query, 4)), providerID: UUID(uuidString: string(query, 8)),
                categoryID: string(query, 3), added: Int(sqlite3_column_int64(query, 5)),
                rating: sqlite3_column_double(query, 6), year: string(query, 2),
                externalID: string(query, 7).isEmpty ? nil : string(query, 7)))
        }
        return values
    }

    func storeSeries(_ items: [SeriesItem], scope: String, categoryID: String?, provider: Provider) {
        if let categoryID, let rows = statement("SELECT id FROM series_items WHERE scope=? AND category_id=?") {
            text(scope, at: 1, in: rows); text(categoryID, at: 2, in: rows)
            var old: [String] = []; while sqlite3_step(rows) == SQLITE_ROW { old.append(string(rows, 0)) }
            sqlite3_finalize(rows)
            if let removeFTS = statement("DELETE FROM series_fts WHERE scope=? AND item_id=?") {
                defer { sqlite3_finalize(removeFTS) }
                for id in old {
                    sqlite3_reset(removeFTS); sqlite3_clear_bindings(removeFTS)
                    text(scope, at: 1, in: removeFTS); text(id, at: 2, in: removeFTS); _ = sqlite3_step(removeFTS)
                }
            }
            if let remove = statement("DELETE FROM series_items WHERE scope=? AND category_id=?") {
                text(scope, at: 1, in: remove); text(categoryID, at: 2, in: remove); _ = sqlite3_step(remove); sqlite3_finalize(remove)
            }
        }
        guard let insert = statement("INSERT OR REPLACE INTO series_items(scope,id,title,year,category_id,poster,added,rating,external_id,provider_id) VALUES(?,?,?,?,?,?,?,?,?,?)") else { return }
        guard let insertSearch = statement("INSERT INTO series_fts(scope,item_id,title,category) VALUES(?,?,?,?)") else { sqlite3_finalize(insert); return }
        guard run("BEGIN IMMEDIATE") else { sqlite3_finalize(insert); sqlite3_finalize(insertSearch); return }
        defer { sqlite3_finalize(insert); sqlite3_finalize(insertSearch); _ = run("COMMIT") }
        for item in items.prefix(SeriesSearchBudget.maximumItems) {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            text(scope, at: 1, in: insert); text(item.scopedID, at: 2, in: insert); text(item.name, at: 3, in: insert)
            text(item.year, at: 4, in: insert); text(item.categoryID, at: 5, in: insert)
            text(safePoster(item.poster, provider: provider), at: 6, in: insert)
            sqlite3_bind_int64(insert, 7, Int64(item.added)); sqlite3_bind_double(insert, 8, item.rating)
            text(item.externalID, at: 9, in: insert); text(item.providerID?.uuidString, at: 10, in: insert)
            _ = sqlite3_step(insert)
            sqlite3_reset(insertSearch); sqlite3_clear_bindings(insertSearch)
            text(scope, at: 1, in: insertSearch); text(item.scopedID, at: 2, in: insertSearch)
            text(item.name, at: 3, in: insertSearch); text("", at: 4, in: insertSearch); _ = sqlite3_step(insertSearch)
        }
        if let categoryID, let state = statement("INSERT OR REPLACE INTO series_category_state(scope,category_id,item_count,updated) VALUES(?,?,?,?)") {
            text(scope, at: 1, in: state); text(categoryID, at: 2, in: state); sqlite3_bind_int64(state, 3, Int64(items.count)); sqlite3_bind_double(state, 4, Date().timeIntervalSince1970); _ = sqlite3_step(state); sqlite3_finalize(state)
        }
    }

    func markSeriesSnapshot(_ items: [SeriesItem], scope: String, categoryIDs: [String], provider: Provider) {
        if let removeFTS = statement("DELETE FROM series_fts WHERE scope=?") { text(scope, at: 1, in: removeFTS); _ = sqlite3_step(removeFTS); sqlite3_finalize(removeFTS) }
        if let remove = statement("DELETE FROM series_items WHERE scope=?") { text(scope, at: 1, in: remove); _ = sqlite3_step(remove); sqlite3_finalize(remove) }
        if let remove = statement("DELETE FROM series_category_state WHERE scope=?") { text(scope, at: 1, in: remove); _ = sqlite3_step(remove); sqlite3_finalize(remove) }
        storeSeries(items, scope: scope, categoryID: nil, provider: provider)
        var counts: [String: Int] = [:]
        for item in items { counts[item.categoryID, default: 0] += 1 }
        if let categoryState = statement("INSERT OR REPLACE INTO series_category_state(scope,category_id,item_count,updated) VALUES(?,?,?,?)") {
            defer { sqlite3_finalize(categoryState) }
            for (categoryID, count) in counts {
                sqlite3_reset(categoryState); sqlite3_clear_bindings(categoryState)
                text(scope, at: 1, in: categoryState); text(categoryID, at: 2, in: categoryState)
                sqlite3_bind_int64(categoryState, 3, Int64(count)); sqlite3_bind_double(categoryState, 4, Date().timeIntervalSince1970); _ = sqlite3_step(categoryState)
            }
        }
        guard let state = statement("INSERT OR REPLACE INTO series_snapshots(scope,signature,updated) VALUES(?,?,?)") else { return }
        text(scope, at: 1, in: state); text(Self.signature(categoryIDs), at: 2, in: state); sqlite3_bind_double(state, 3, Date().timeIntervalSince1970); _ = sqlite3_step(state); sqlite3_finalize(state)
    }

    func searchSeries(scope: String, query: String, categoryIDs: [String], limit: Int = 300) -> [SeriesItem] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty, !categoryIDs.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: categoryIDs.count).joined(separator: ",")
        guard let statement = statement("SELECT s.id,s.title,s.year,s.category_id,s.poster,s.added,s.rating,s.external_id,s.provider_id FROM series_fts f JOIN series_items s ON s.scope=f.scope AND s.id=f.item_id WHERE series_fts MATCH ? AND f.scope=? AND s.category_id IN (\(marks)) ORDER BY CASE WHEN lower(s.title)=lower(?) THEN 0 WHEN lower(substr(s.title,1,length(?)))=lower(?) AND substr(s.title,length(?)+1,2)=' (' THEN 1 WHEN lower(substr(s.title,1,length(?)))=lower(?) THEN 2 ELSE 3 END,s.title LIMIT ?") else { return [] }
        defer { sqlite3_finalize(statement) }
        text(match, at: 1, in: statement); text(scope, at: 2, in: statement)
        for (offset, id) in categoryIDs.enumerated() { text(id, at: Int32(offset + 3), in: statement) }
        let rank = Int32(3 + categoryIDs.count)
        for offset in 0..<6 { text(query, at: rank + Int32(offset), in: statement) }
        sqlite3_bind_int(statement, rank + 6, Int32(max(1, min(limit, 1000))))
        return readSeries(statement)
    }

    private func deleteFTS(table: String, scope: String, kind: String, id: String) {
        let sql = table == "catalog_fts"
            ? "DELETE FROM catalog_fts WHERE scope=? AND kind=? AND item_id=?"
            : "DELETE FROM series_fts WHERE scope=? AND item_id=?"
        guard let statement = statement(sql) else { return }
        text(scope, at: 1, in: statement)
        if table == "catalog_fts" { text(kind, at: 2, in: statement); text(id, at: 3, in: statement) }
        else { text(id, at: 2, in: statement) }
        _ = sqlite3_step(statement); sqlite3_finalize(statement)
    }

    private func insertFTS(table: String, scope: String, kind: String, id: String, title: String, category: String) {
        guard let statement = statement(table == "catalog_fts" ? "INSERT INTO catalog_fts(scope,kind,item_id,title,category) VALUES(?,?,?,?,?)" : "INSERT INTO series_fts(scope,item_id,title,category) VALUES(?,?,?,?)") else { return }
        text(scope, at: 1, in: statement)
        if table == "catalog_fts" {
            text(kind, at: 2, in: statement); text(id, at: 3, in: statement); text(title, at: 4, in: statement); text(category, at: 5, in: statement)
        } else { text(id, at: 2, in: statement); text(title, at: 3, in: statement); text(category, at: 4, in: statement) }
        _ = sqlite3_step(statement); sqlite3_finalize(statement)
    }

    private func safePoster(_ url: URL?, provider: Provider) -> String? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil,
              !parts.queryItems.orEmpty.contains(where: { ["user", "username", "password", "token", "auth", "key"].contains($0.name.lowercased()) }),
              (provider.username.isEmpty || !url.absoluteString.localizedCaseInsensitiveContains(provider.username)),
              (provider.password.isEmpty || !url.absoluteString.localizedCaseInsensitiveContains(provider.password)) else { return nil }
        return url.absoluteString
    }

    private static func ftsQuery(_ input: String) -> String {
        let tokens = input.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "_-")).inverted).filter { !$0.isEmpty }.prefix(8)
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
    }
}

private extension Optional where Wrapped == [URLQueryItem] {
    var orEmpty: [URLQueryItem] { self ?? [] }
}

extension AppModel {
    /// Stable opaque key for the local catalog cache. A password never enters
    /// the key or database; account changes on the same host still get a new scope.
    var catalogCacheScope: String {
        let identities: [String]
        if libraryMode == .combined {
            identities = combinedProfiles.compactMap { profile in
                guard let host = try? profile.provider.baseURL().host else { return nil }
                return "\(host.lowercased())|\(profile.provider.username)|\(profile.provider.kind.rawValue)"
            }.sorted()
        } else if let host = try? provider.baseURL().host {
            identities = ["\(host.lowercased())|\(provider.username)|\(provider.kind.rawValue)"]
        } else { identities = [] }
        let raw = (preferenceKey ?? "device") + "|" + identities.joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// Ephemeral, bounded in-memory requests prevent provider responses or URLs entering disk caches.
final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var finalURL: URL?
    private var requestedURL: URL?
    private var chosenUserAgent = ProviderHTTP.userAgent
    var resolvedURL: URL? { lock.lock(); defer { lock.unlock() }; return finalURL }
    init(limit: Int, timeout: TimeInterval = 30) { self.limit = limit; self.timeout = timeout }
    func fetch(_ url: URL, headers: [String: String] = [:], method: String = "GET") async throws -> Data {
        guard TransportPolicy.permits(url) else { throw AppFailure("This provider URL is blocked by this app build's network settings. Rebuild with direct HTTP IPTV support enabled.") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { next in
                lock.lock()
                if finished { lock.unlock(); next.resume(throwing: CancellationError()); return }
                continuation = next
                requestedURL = url
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout * 2
                // Redirects inherit this agent. The per-request header below
                // covers the first hop, including a non-standard port.
                config.httpAdditionalHeaders = ["User-Agent": ProviderHTTP.userAgent]
                let connection = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                session = connection
                let request = ProviderHTTP.request(url: url, headers: headers, method: method)
                chosenUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ProviderHTTP.userAgent
                let nextTask = connection.dataTask(with: request); task = nextTask
                lock.unlock(); nextTask.resume()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let next = continuation; continuation = nil
        let connection = session; session = nil; task = nil
        lock.unlock()
        next?.resume(with: result); connection?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, TransportPolicy.permits(url) else {
            let whereTo = request.url.map(ProviderHTTP.endpoint) ?? "another host"
            finish(.failure(AppFailure("The provider redirected to \(whereTo), which this app build cannot open. Check the provider URL and port. No gateway was used.")))
            completionHandler(nil); return
        }
        lock.lock(); let agent = chosenUserAgent; lock.unlock()
        var next = ProviderHTTP.redirected(request, userAgent: agent)
        if response.url?.host != request.url?.host || response.url?.scheme != request.url?.scheme || response.url?.port != request.url?.port {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(AppFailure("The server returned an unsupported response."))); return
        }
        guard (200..<300).contains(response.statusCode) else {
            lock.lock(); let fallback = requestedURL; lock.unlock()
            let url = response.url ?? dataTask.originalRequest?.url ?? fallback
            let message = url.map { ProviderHTTP.httpFailure(status: response.statusCode, url: $0) }
                ?? "Provider request failed (HTTP \(response.statusCode)). Ant Streams connected directly; no gateway was used."
            // Record the status before cancelling. A synchronous completion
            // callback would otherwise replace it with a generic -999.
            finish(.failure(AppFailure(message))); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(AppFailure("Provider response is too large. Try a smaller category."))); return
        }
        lock.lock(); finalURL = response.url; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if buffer.count + data.count > limit { lock.unlock(); finish(.failure(AppFailure("This provider category is too large. Try a smaller category."))); return }
        buffer.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                lock.lock(); let fallback = requestedURL; lock.unlock()
                if let url = task.originalRequest?.url ?? fallback {
                    finish(.failure(AppFailure(ProviderHTTP.transportFailure(error, url: url))))
                } else {
                    finish(.failure(AppFailure("Provider unreachable. Ant Streams connects directly; no gateway was used.")))
                }
            }
        } else { lock.lock(); let data = buffer; lock.unlock(); finish(.success(data)) }
    }
}

@MainActor
final class PosterMemory {
    static let shared = NSCache<NSURL, UIImage>()
    static func configure() { shared.totalCostLimit = 48 * 1024 * 1024; shared.countLimit = 100 }
}

struct ProviderPoster: View {
    let url: URL?
    let kind: LibraryKind
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.06)
                if let image {
                    Image(uiImage: image).resizable()
                        .aspectRatio(contentMode: kind == .movies ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else { Image(systemName: kind.symbol).font(.largeTitle).foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            PosterMemory.configure()
            if let cached = PosterMemory.shared.object(forKey: url as NSURL) { image = cached; return }
            guard let data = try? await PosterImageLoader.shared.data(for: url), !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1000
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: thumbnail)
            }
            let decoded = await worker.value
            guard !Task.isCancelled, let decoded else { return }
            PosterMemory.shared.setObject(decoded, forKey: url as NSURL, cost: (decoded.cgImage?.bytesPerRow ?? 0) * (decoded.cgImage?.height ?? 0))
            image = decoded
        }
    }
}

/// Reuses connections and coalesces duplicate artwork requests while keeping
/// both the HTTP response cache and decoded images in memory only.
actor PosterImageLoader {
    static let shared = PosterImageLoader()

    private let dataCache = NSCache<NSURL, NSData>()
    private var inFlight: [URL: Task<Data, Error>] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 24
        return URLSession(configuration: configuration)
    }()

    private init() {
        dataCache.totalCostLimit = 24 * 1024 * 1024
        dataCache.countLimit = 240
    }

    func data(for url: URL) async throws -> Data {
        guard TransportPolicy.permits(url) else { throw AppFailure("Artwork URL is blocked by this app build's network settings.") }
        if let cached = dataCache.object(forKey: url as NSURL) { return cached as Data }
        if let task = inFlight[url] { return try await task.value }

        let task = Task<Data, Error> {
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
            request.setValue(ProviderHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw AppFailure("Artwork server returned an error.")
            }
            guard data.count <= 2 * 1024 * 1024 else { throw AppFailure("Artwork image is too large.") }
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data = try await task.value
        dataCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}

enum CatalogSearchScope: String, CaseIterable {
    case category = "This category", all = "All categories"
}

/// Capsule option picker with explicit selected styling: the selected option
/// always pairs an accent fill with `StreamTheme.onAccent` text, so it stays
/// readable in every theme (Ghost's white accent would wash out a default
/// segmented control or a prominent button with light text).
struct StreamOptionPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected ? StreamTheme.onAccent : StreamTheme.text)
                        .background(selected ? AnyShapeStyle(StreamTheme.accentFill) : AnyShapeStyle(StreamTheme.panel), in: Capsule())
                }
                .buttonStyle(StreamOptionButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct StreamOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StreamOptionBody(configuration: configuration)
    }
    private struct StreamOptionBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.8 : 1)
                .overlay {
                    #if os(tvOS)
                    Capsule().stroke(focused ? TVTheme.focusRing : Color.clear, lineWidth: 3)
                    #endif
                }
        }
    }
}

struct CatalogIndex {
    static let maximumItems = 100000
    private(set) var items: [CatalogItem] = []
    private var seen = Set<String>()
    mutating func append(_ batch: [CatalogItem]) throws {
        for item in batch where !seen.contains(item.id) {
            guard items.count < Self.maximumItems else { throw AppFailure("The catalog reached the app's search limit. Search a specific category for additional titles.") }
            seen.insert(item.id); items.append(item)
        }
    }
    static func matches(_ items: [CatalogItem], query: String) -> [CatalogItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? items : items.filter { !Task.isCancelled && $0.name.localizedCaseInsensitiveContains(term) }
    }
}

struct CatalogLoadResult {
    let items: [CatalogItem]
    let notice: String
}

/// An unscoped provider response is the whole library only when it is not
/// confined to a single category while the provider lists more than one.
/// Items that omit category ids stay on the fast path; a one-category payload
/// falls back to category requests so search is not stuck on the category
/// the provider last returned.
enum CatalogCoverage {
    static func isComplete(categoryIDs: [String], categoryCount: Int) -> Bool {
        if categoryCount <= 1 { return true }
        let ids = Set(categoryIDs.filter { !$0.isEmpty })
        if ids.isEmpty { return true }
        return ids.count > 1
    }
}

// Prefer one full-catalog request. When a provider only returns one category at a time,
// use a small bounded fan-out so a large playlist does not take one network round-trip
// per category while keeping provider load and memory use controlled.
@MainActor
enum CatalogLoader {
    static func load(categoryIDs: [String], preferFullCatalog: Bool,
                     fetch: @escaping (String?) async throws -> [CatalogItem],
                     progress: ([CatalogItem], String) -> Void) async throws -> CatalogLoadResult {
        try Task.checkCancellation()
        if preferFullCatalog {
            progress([], "Loading full catalog…")
            do {
                let batch = try await fetch(nil)
                try Task.checkCancellation()
                if !batch.isEmpty && CatalogCoverage.isComplete(categoryIDs: batch.map(\.categoryID), categoryCount: categoryIDs.count) {
                    var index = CatalogIndex()
                    try index.append(batch)
                    return CatalogLoadResult(items: index.items, notice: "")
                }
                if batch.isEmpty && categoryIDs.isEmpty {
                    return CatalogLoadResult(items: [], notice: "")
                }
                // Empty or single-category payload. Fall back to per-category requests.
            } catch {
                try Task.checkCancellation()
                // Some providers reject the unfiltered API or exceed the memory bounds.
            }
        }
        var index = CatalogIndex()
        var failed = 0
        let concurrency = min(4, categoryIDs.count)
        var next = 0
        var completed = 0
        var limitNotice: String?
        await withTaskGroup(of: (Int, Result<[CatalogItem], Error>).self) { group in
            func enqueue(_ offset: Int) {
                let category = categoryIDs[offset]
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (offset, .success(try await fetch(category)))
                    } catch {
                        return (offset, .failure(error))
                    }
                }
            }

            while next < concurrency {
                enqueue(next)
                next += 1
            }
            while let (_, outcome) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                switch outcome {
                case .success(let batch):
                    do { try index.append(batch) }
                    catch {
                        limitNotice = error.localizedDescription
                        group.cancelAll()
                        break
                    }
                case .failure(let error):
                    if error is CancellationError {
                        if Task.isCancelled { group.cancelAll(); break }
                    } else {
                        failed += 1
                    }
                }
                if limitNotice != nil || Task.isCancelled { break }
                completed += 1
                progress(index.items, "Loading category \(completed) of \(categoryIDs.count)…")
                if next < categoryIDs.count {
                    enqueue(next)
                    next += 1
                }
            }
        }
        try Task.checkCancellation()
        if let limitNotice { return CatalogLoadResult(items: index.items, notice: limitNotice) }
        return CatalogLoadResult(items: index.items, notice: failed == 0 ? "" : "\(failed) categories could not be loaded. Showing available results; Retry will refresh the catalog.")
    }
}


enum CategoryPins {
    static func key(accountID: String, host: String) -> String {
        let digest = SHA256.hash(data: Data("\(accountID)|\(host.lowercased())".utf8))
        return "rigatoni-pinned-categories-" + digest.map { String(format: "%02x", $0) }.joined()
    }
    static func toggled(_ id: String, in pins: [String]) -> [String] {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return pins }
        if pins.contains(id) { return pins.filter { $0 != id } }
        return Array((pins + [id]).suffix(100))
    }
    static func ordered(_ categories: [CatalogCategory], pins: [String]) -> [CatalogCategory] {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = pins.compactMap { byID[$0] }
        let ids = Set(pins)
        return pinned + categories.filter { !ids.contains($0.id) }
    }
}

// Shared native visual language; playback and credential handling stay separate.
enum StreamTheme {
    static var appearance: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: "rigatoni-appearance") ?? "dark") ?? .dark }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
    static func background(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(242, 242, 247)
        case .dark: return rgb(8, 7, 6)
        case .ghost: return rgb(10, 10, 11)
        case .nebula: return rgb(6, 6, 9)
        }
    }
    static func panel(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(255, 255, 255)
        case .dark: return rgb(24, 20, 16)
        case .ghost: return rgb(20, 20, 22)
        case .nebula: return rgb(14, 14, 20)
        }
    }
    static func card(for appearance: AppAppearance) -> Color { panel(for: appearance) }
    static func text(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(28, 28, 30)
        case .dark: return rgb(247, 244, 239)
        case .ghost: return .white
        case .nebula: return rgb(237, 235, 245)
        }
    }
    static func muted(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(107, 114, 128)
        case .dark: return rgb(176, 164, 148)
        case .ghost: return rgb(161, 161, 170)
        case .nebula: return rgb(143, 141, 163)
        }
    }
    static func accent(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .ghost: return .white
        case .nebula: return rgb(167, 139, 250)
        case .dark: return rgb(232, 148, 74)
        case .light: return rgb(229, 9, 20)
        }
    }
    static func accentFill(for appearance: AppAppearance) -> LinearGradient {
        let colors: [Color]
        switch appearance {
        case .nebula: colors = [rgb(167, 139, 250), rgb(34, 211, 238)]
        case .dark: colors = [rgb(242, 166, 90), rgb(214, 92, 70)]
        default: colors = [accent(for: appearance), accent(for: appearance)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
    // White/aurora fills need dark labels, including selected chips and badges.
    static func onAccent(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .ghost, .nebula: return rgb(6, 6, 9)
        default: return .white
        }
    }
    static var accentFill: LinearGradient { accentFill(for: appearance) }
    static var onAccent: Color { onAccent(for: appearance) }
    static var text: Color { text(for: appearance) }
    static var background: Color { background(for: appearance) }
    static var panel: Color { panel(for: appearance) }
    static var card: Color { card(for: appearance) }
    static var muted: Color { muted(for: appearance) }
    static var accent: Color { accent(for: appearance) }
    static let corner: CGFloat = 18
}

struct StreamBackdrop: View {
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    var body: some View {
        let theme = AppAppearance(rawValue: appearance) ?? .dark
        ZStack {
            StreamTheme.background(for: theme)
            if theme != .light {
                RadialGradient(colors: [Color(red: 0.78, green: 0.42, blue: 0.14).opacity(theme == .dark ? 0.55 : 0.22), .clear],
                               center: UnitPoint(x: 0.5, y: -0.08), startRadius: 10, endRadius: 560)
                RadialGradient(colors: [Color(red: 0.55, green: 0.16, blue: 0.14).opacity(theme == .dark ? 0.28 : 0.12), .clear],
                               center: UnitPoint(x: 0.92, y: 0.02), startRadius: 8, endRadius: 420)
            } else {
                LinearGradient(colors: [StreamTheme.panel(for: theme), StreamTheme.background(for: theme)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea()
    }
}

struct StreamHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANT STREAMS").font(.caption.weight(.bold)).tracking(3).foregroundStyle(StreamTheme.accent)
            Text(title).font(.system(size: 34, weight: .bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
/// X1-styled live channel row: logo, channel name with a LIVE badge, and
/// now/next program info when the provider supplies short-EPG data.
/// Without EPG (gateway providers, or providers without listings) it falls
/// back to the plain channel row with the LIVE badge.
struct LiveChannelRow: View {
    @ObservedObject private var epgCache = EPGCache.shared
    let item: CatalogItem
    let provider: Provider
    let epgEnabled: Bool
    let scope: String
    var refreshToken: Int = 0
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @State private var guide: EPGNowNext?
    private var theme: AppAppearance { AppAppearance(rawValue: appearance) ?? .dark }
    var body: some View {
        HStack(spacing: 16) {
            ProviderPoster(url: item.poster, kind: .live)
                .frame(width: 86, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.preferences.itemTitle(item)).font(.headline).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("LIVE").font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(StreamTheme.onAccent(for: theme))
                        .background(StreamTheme.accentFill(for: theme), in: Capsule())
                        .accessibilityHidden(true)
                }
                if let now = guide?.now {
                    Text("Now · \(now.title)").font(.subheadline).lineLimit(1)
                        .foregroundStyle(StreamTheme.muted(for: theme))
                    HStack(spacing: 4) {
                        Text(now.timeRange).font(.caption).monospacedDigit()
                        if let next = guide?.next, !next.title.isEmpty {
                            Text("· Next: \(next.title)").font(.caption).lineLimit(1)
                        }
                    }.foregroundStyle(StreamTheme.muted(for: theme).opacity(0.85))
                }
            }
            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.secondary)
        }.padding(12).foregroundStyle(.primary)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: StreamTheme.corner))
            .contextMenu { MobileSaveButton(record: MobileRecords.record(item)) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.name), live" + (guide?.now.map { ", now playing \($0.title)" } ?? ""))
            .task(id: scope + ":" + item.id + "-\(refreshToken):\(epgCache.revision)") {
                guide = nil
                guard epgEnabled else { return }
                while !Task.isCancelled {
                    let value = await EPGCache.shared.nowNext(streamID: item.id, provider: provider, scope: scope, categoryID: item.categoryID)
                    guard !Task.isCancelled else { return }; guide = value
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
    }
}

struct LibraryView: View {
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    let kind: LibraryKind
    var initialCategoryID: String? = nil
    var embedded = false
    @State private var pinnedIDs: [String] = []
    @State private var categories: [CatalogCategory] = []
    @State private var selected = ""
    @State private var items: [CatalogItem] = []
    @State private var query = ""
    @State private var filtered: [CatalogItem] = []
    @State private var searchRevision = 0
    @State private var categoryCache: [String: [CatalogItem]] = [:]
    @State private var allCache: CatalogLoadResult?
    @State private var loading = false
    @State private var scope = CatalogSearchScope.category
    @State private var progress = ""
    @State private var error = ""
    @State private var page = 0
    @State private var playing: CatalogItem?
    @State private var retry = 0
    @State private var multiViewShown = false
    @State private var epgReload = 0
    @State private var epgReloading = false
    private var orderedCategories: [CatalogCategory] {
        let shown = model.preferences.browseCategories(categories, section: CatalogSection(kind))
        return kind == .live ? CategoryPins.ordered(shown, pins: pinnedIDs) : shown
    }
    private var pinKey: String? { model.pinKey }
    private var visible: [CatalogItem] { Array(filtered.dropFirst(page * 120).prefix(120)) }
    var body: some View {
        if embedded { libraryContent }
        else { NavigationStack { libraryContent } }
    }
    private var libraryContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StreamHeading(title: kind.title, subtitle: kind == .movies ? "Find your next movie night." : "Your channels. Your front row seat.")
                        .padding(.vertical, 12)
                    if !model.providerReady {
                        Text("Add or restore your provider settings to browse.")
                        Button("Provider settings") { model.settingsVisible = true }.buttonStyle(.borderedProminent).foregroundStyle(StreamTheme.onAccent)
                    } else {
                        if kind == .live {
                            Button { multiViewShown = true } label: {
                                Label("Multi View — watch 2 channels at once", systemImage: "square.split.2x2")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Multi View: watch two channels at once")
                            .fullScreenCover(isPresented: $multiViewShown) { MultiPlayerView() }
                        }
                        if kind == .movies {
                            StreamOptionPicker(options: [(CatalogSearchScope.all, "All titles"), (.category, "Categories")], selection: $scope)
                        }
                        if kind == .movies && scope == .category {
                            GuideCategoryPicker(categories: orderedCategories, selected: $selected)
                        }
                        if kind == .live && !categories.isEmpty {
                            HStack {
                                Text("Categories").font(.headline)
                                Spacer()
                                Button {
                                    pinnedIDs = PinnedCategories.toggled(selected, in: pinnedIDs)
                                    PinnedCategories.write(pinnedIDs, key: pinKey)
                                } label: { Image(systemName: pinnedIDs.contains(selected) ? "pin.fill" : "pin").frame(width: 44, height: 44) }
                                .accessibilityLabel(pinnedIDs.contains(selected) ? "Unpin category" : "Pin category")
                                .disabled(selected.isEmpty)
                                .buttonStyle(.plain)
                                Button { reloadEPG() } label: {
                                    if epgReloading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                                }
                                .buttonStyle(.plain)
                                .disabled(epgReloading)
                                .accessibilityLabel("Reload program guide")
                            }
                            LazyVStack(spacing: 8) {
                                Button { scope = .all } label: {
                                    liveCategoryRow(name: "All Channels", selected: scope == .all, pinned: false)
                                }.buttonStyle(.plain)
                                ForEach(orderedCategories) { category in
                                    Button { scope = .category; selected = category.id } label: {
                                        liveCategoryRow(name: category.name, selected: scope == .category && selected == category.id, pinned: pinnedIDs.contains(category.id))
                                    }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button(pinnedIDs.contains(category.id) ? "Unpin category" : "Pin category") {
                                            pinnedIDs = PinnedCategories.toggled(category.id, in: pinnedIDs)
                                            PinnedCategories.write(pinnedIDs, key: pinKey)
                                        }
                                    }
                                }
                            }
                        }
                        if loading { ProgressView(progress.isEmpty ? "Loading \(kind.title.lowercased())…" : progress).frame(maxWidth: .infinity) }
                        if !error.isEmpty {
                            Text(error).foregroundStyle(.secondary)
                            Button("Retry") { model.refreshProvider(); retry += 1 }.buttonStyle(.bordered)
                        } else if !loading && filtered.isEmpty { Text(query.isEmpty ? "No titles available." : "No matching titles.").foregroundStyle(.secondary) }
                        if kind == .live {
                            LazyVStack(spacing: 10) {
                                ForEach(visible, id: \.scopedID) { item in
                                    Button { playing = item } label: {
                                        LiveChannelRow(item: item, provider: model.provider(for: item), epgEnabled: true, scope: model.epgScope(for: item), refreshToken: epgReload)
                                    }.buttonStyle(.plain)
                                }
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 22) {
                                ForEach(visible, id: \.scopedID) { item in
                                    Button { playing = item } label: { MovieCard(item: item) }.buttonStyle(.plain)
                                }
                            }
                        }
                        if filtered.count > 120 {
                            HStack {
                                Button("Previous") { page -= 1 }.disabled(page == 0)
                                Spacer(); Text("Page \(page + 1)").foregroundStyle(.secondary); Spacer()
                                Button("Next") { page += 1 }.disabled((page + 1) * 120 >= filtered.count)
                            }
                        }
                        Text("\(filtered.count) titles · \(scope.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .background { StreamBackdrop() }
            .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
            .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search \(kind.title)")
            .toolbar { Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account and provider settings") }
            .task(id: "\(model.libraryRevision)-\(retry)") { await loadCategories() }
            .task(id: "\(scope.rawValue)-\(selected)-\(model.libraryRevision)-\(retry)") { await loadItems() }
            .task(id: "\(query)-\(searchRevision)") { await filterItems() }
            .onChange(of: catalog.revision) { _, _ in
                if scope == .all && loading {
                    replaceItems(catalog.searchable[kind] ?? [])
                    progress = catalog.progress[kind] ?? ""
                }
            }
            .fullScreenCover(item: $playing) { CatalogDestination(item: $0, channels: kind == .live ? items : []) }
    }

    private func liveCategoryRow(name: String, selected: Bool, pinned: Bool) -> some View {
        HStack {
            Text((pinned ? "★ " : "") + name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(StreamTheme.text)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(selected ? StreamTheme.accent.opacity(0.18) : StreamTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? StreamTheme.accent : .clear, lineWidth: 2))
    }

    // Manual EPG reload: clear the cache so stale programs can't stick,
    // then restart every visible row's EPG task so it refetches fresh.
    private func reloadEPG() {
        guard !epgReloading else { return }
        Task { @MainActor in
            epgReloading = true
            EPGCache.shared.reset()
            epgReload += 1
            try? await Task.sleep(for: .seconds(1))
            epgReloading = false
        }
    }

    private func loadCategories() async {
        categories = []; selected = ""; replaceItems([]); error = ""; query = ""; page = 0; progress = ""; categoryCache = [:]; allCache = nil
        var pins = PinnedCategories.read(key: pinKey)
        if pins.isEmpty, let legacy = pinKey.flatMap({ UserDefaults.standard.stringArray(forKey: $0) }), !legacy.isEmpty {
            // Adopt pins saved by the older inline pin button (same scope, no suffix).
            pins = legacy
            PinnedCategories.write(pins, key: pinKey)
        }
        pinnedIDs = pins
        guard model.providerReady else { return }
        loading = true
        do {
            let loaded = try await model.catalog.categories(kind: kind, model: model)
            try Task.checkCancellation()
            categories = loaded
            selected = orderedCategories.first { $0.id == initialCategoryID }?.id ?? orderedCategories.first?.id ?? ""
            if initialCategoryID == "all" { scope = .all }
            if selected.isEmpty { loading = false }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
    }
    private func replaceItems(_ value: [CatalogItem]) {
        let allowed = categories
        items = value.filter { model.preferences.accepts($0, categories: allowed) }; searchRevision += 1; page = 0
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { filtered = items }
    }
    private func filterItems() async {
        let snapshot = items; let term = query
        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { filtered = snapshot; return }
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        guard !Task.isCancelled else { return }
        let worker = Task.detached(priority: .userInitiated) { CatalogIndex.matches(snapshot, query: term) }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { return }
        filtered = result
    }
    private func fetchItems(category: String?) async throws -> [CatalogItem] {
        try await model.catalog.items(kind: kind, category: category, model: model)
    }
    private func loadItems() async {
        guard !selected.isEmpty, !categories.isEmpty, model.providerReady else { return }
        error = ""; progress = ""; page = 0
        if scope == .all, let cached = allCache {
            replaceItems(cached.items); error = cached.notice; loading = false; return
        }
        replaceItems([]); loading = true
        do {
            if scope == .all {
                let result = try await catalog.loadAll(kind: kind, model: model)
                try Task.checkCancellation()
                replaceItems(result.items); error = result.notice
                if result.notice.isEmpty { allCache = result; categoryCache = [:] }
            } else {
                let result = try await fetchItems(category: selected)
                try Task.checkCancellation()
                replaceItems(result)
            }
            loading = false; progress = ""
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false; progress = ""
        }
    }
}

#endif
