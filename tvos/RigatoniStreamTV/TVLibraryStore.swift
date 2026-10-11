import Foundation
import SwiftUI

// tvOS catalog store. Mirrors the loading semantics of the iPhone build's
// LibraryView (same shared types: Provider, LibraryKind, CatalogItem,
// CatalogCategory, CatalogLoader, CatalogIndex, BoundedTransfer), but drives
// tvOS grids instead of iOS pickers. Provider credentials and the encrypted
// vault flow through the shared AppModel/AccountAPI only.
@MainActor
final class TVLibraryStore: ObservableObject {
    let kind: LibraryKind
    private let model: AppModel

    @Published var categories: [CatalogCategory] = []
    @Published var items: [CatalogItem] = []
    @Published var loading = false
    @Published var progress = ""
    @Published var error = ""
    @Published var revision = 0
    private var categoryCache: [String: [CatalogItem]] = [:]
    private var allCache: CatalogLoadResult?

    init(kind: LibraryKind, model: AppModel) {
        self.kind = kind
        self.model = model
    }

    var pinKey: String? {
        guard let accountID = model.account.session?.user.id,
              let host = try? model.provider.baseURL().host else { return nil }
        return CategoryPins.key(accountID: accountID, host: host)
    }

    func pinnedIDs() -> [String] {
        pinKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []
    }

    func reset() {
        categories = []; items = []
        loading = false; progress = ""; error = ""
        categoryCache = [:]; allCache = nil
    }

    private func rows(action: String, category: String? = nil) async throws -> [[String: Any]] {
        if model.provider.requiresGateway { return try await model.gatewayRows(kind: kind, category: category) }
        let url = try model.provider.apiURL(action: action, category: category)
        let data = try await BoundedTransfer(limit: 32 * 1024 * 1024).fetch(url)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 50000 else {
            throw AppFailure("The provider returned an invalid or oversized category.")
        }
        return rows
    }

    func loadCategories() async {
        reset()
        guard model.signedIn, model.providerReady else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await rows(action: kind.categoryAction)
            guard !Task.isCancelled else { return }
            categories = result.compactMap { row in
                let id = row["category_id"].map { String(describing: $0) } ?? ""
                guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
                return CatalogCategory(id: id, name: row["category_name"] as? String ?? "Category")
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func fetchItems(category: String?) async throws -> [CatalogItem] {
        if !model.provider.requiresGateway, let category, let cached = categoryCache[category] { return cached }
        let raw: [[String: Any]]
        if model.provider.requiresGateway {
            raw = try await model.gatewayRows(kind: kind, category: category)
        } else {
            let url = try model.provider.apiURL(action: kind.streamAction, category: category)
            let data = try await BoundedTransfer(limit: 32 * 1024 * 1024, timeout: category == nil ? 10 : 30).fetch(url)
            let worker = Task.detached(priority: .userInitiated) {
                guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      result.count <= CatalogIndex.maximumItems else {
                    throw AppFailure("The provider returned an invalid or oversized catalog.")
                }
                return result
            }
            raw = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
        try Task.checkCancellation()
        let libraryKind = kind
        let worker = Task.detached(priority: .userInitiated) { raw.compactMap { CatalogItem.parse($0, kind: libraryKind) } }
        var result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        if model.provider.requiresGateway {
            result = result.map { item in
                var item = item
                item.playbackURL = try? model.gatewayPlaybackURL(id: item.id, kind: kind)
                return item
            }
        } else if let category {
            categoryCache = [category: result]
        }
        if let category { result = result.map { var item = $0; if item.categoryID.isEmpty { item.categoryID = category }; return item } }
        return result
    }

    /// Load one category's items (grid browsing).
    func loadItems(categoryID: String) async {
        guard model.signedIn, model.providerReady else { return }
        error = ""; progress = ""; items = []; loading = true
        defer { loading = false }
        do {
            let result = try await fetchItems(category: categoryID)
            try Task.checkCancellation()
            items = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Load the whole catalog for search (full-catalog fast path, then
    /// category fallback with progress), like the iPhone build.
    func loadAllForSearch(update: @escaping ([CatalogItem], String) -> Void) async {
        guard model.signedIn, model.providerReady else { return }
        error = ""; items = []; loading = true
        defer { loading = false }
        do {
            if let cached = allCache, !model.provider.requiresGateway {
                items = cached.items; error = cached.notice; return
            }
            let result = try await CatalogLoader.load(
                categoryIDs: categories.map(\.id),
                preferFullCatalog: !model.provider.requiresGateway,
                fetch: { try await self.fetchItems(category: $0) },
                progress: { partial, message in
                    guard !Task.isCancelled else { return }
                    update(partial, message)
                })
            try Task.checkCancellation()
            items = result.items; error = result.notice
            if !model.provider.requiresGateway { allCache = result; categoryCache = [:] }
            update(result.items, "")
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
