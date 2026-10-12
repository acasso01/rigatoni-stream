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

    var pinKey: String? { model.pinKey }

    func pinnedIDs() -> [String] {
        pinKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []
    }

    func reset() {
        categories = []; items = []
        loading = false; progress = ""; error = ""
        categoryCache = [:]; allCache = nil
    }


    func loadCategories() async {
        reset()
        guard model.providerReady else { return }
        loading = true
        defer { loading = false }
        do {
            let loaded = try await model.catalog.categories(kind: kind, model: model)
            try Task.checkCancellation()
            categories = loaded
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func fetchItems(category: String?) async throws -> [CatalogItem] {
        try await model.catalog.items(kind: kind, category: category, model: model)
    }

    /// Load one category's items (grid browsing).
    func loadItems(categoryID: String) async {
        guard model.providerReady else { return }
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
        guard model.providerReady else { return }
        error = ""; items = []; loading = true
        defer { loading = false }
        do {
            if let cached = allCache {
                items = cached.items; error = cached.notice; return
            }
            let result = try await model.catalog.loadAll(kind: kind, model: model)
            try Task.checkCancellation()
            items = result.items; error = result.notice
            if result.notice.isEmpty { allCache = result; categoryCache = [:] }
            update(result.items, "")
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
