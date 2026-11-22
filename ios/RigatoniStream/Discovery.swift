import SwiftUI
import UniformTypeIdentifiers

// Memory-only catalogs shared by browsing and global search. Scoped to the account or the on-device provider.
@MainActor
final class SessionCatalog: ObservableObject {
    @Published private(set) var searchable: [LibraryKind: [CatalogItem]] = [:]
    @Published private(set) var revision = 0
    @Published private(set) var progress: [LibraryKind: String] = [:]
    private var categoryLists: [LibraryKind: [CatalogCategory]] = [:]
    private var batches: [String: [CatalogItem]] = [:]
    private var batchOrder: [String] = []
    private var completed: [LibraryKind: CatalogLoadResult] = [:]
    private var jobs: [String: Task<[CatalogItem], Error>] = [:]
    private var fullJobs: [LibraryKind: Task<CatalogLoadResult, Error>] = [:]
    private var generation = 0
    // Combined-library caches live apart from the single-provider caches so
    // switching modes (which resets the catalog) can never mix providers.
    private var combinedCategoryLists: [LibraryKind: [CatalogCategory]] = [:]
    private var combinedCompleted: [LibraryKind: CatalogLoadResult] = [:]
    private var combinedFullJobs: [LibraryKind: Task<CatalogLoadResult, Error>] = [:]
    /// Session memory for TV-show search. Raw provider rows, filtered when read.
    private var fullSeries: [SeriesItem]?
    private var seriesFullChecked = false
    private var seriesByCategory: [String: [SeriesItem]] = [:]
    private var seriesCategoryOrder: [String] = []
    private var cachedSeriesCount = 0
    private let maximumCachedSeriesItems = 60_000

    func knownCategories(kind: LibraryKind) -> [CatalogCategory] {
        if let combined = combinedCategoryLists[kind], !combined.isEmpty { return combined }
        return categoryLists[kind] ?? []
    }
    func reset() {
        generation += 1
        PosterMemory.shared.removeAllObjects()
        jobs.values.forEach { $0.cancel() }; fullJobs.values.forEach { $0.cancel() }
        combinedFullJobs.values.forEach { $0.cancel() }
        jobs = [:]; fullJobs = [:]; combinedFullJobs = [:]; batches = [:]; batchOrder = []
        completed = [:]; combinedCompleted = [:]; categoryLists = [:]; combinedCategoryLists = [:]
        fullSeries = nil; seriesFullChecked = false; clearSeriesCache()
        searchable = [:]; progress = [:]; revision += 1
    }
    /// Full-catalog search results depend on category visibility. Keep the
    /// reusable per-category catalog cache, but discard search aggregates so
    /// enabling a category later fetches it instead of reusing a stale subset.
    func invalidateVisibilitySearch() {
        fullJobs.values.forEach { $0.cancel() }
        combinedFullJobs.values.forEach { $0.cancel() }
        fullJobs = [:]; combinedFullJobs = [:]
        completed = [:]; combinedCompleted = [:]
        fullSeries = nil; seriesFullChecked = false; clearSeriesCache()
        searchable = [:]; progress = [:]; revision += 1
    }
    func cachedFullSeries() -> [SeriesItem]? { fullSeries }
    func cacheFullSeries(_ items: [SeriesItem]) {
        fullSeries = items
    }
    func seriesFullWasChecked() -> Bool { seriesFullChecked }
    func markSeriesFullChecked() { seriesFullChecked = true }
    func cachedSeries(categoryID: String) -> [SeriesItem]? {
        guard let items = seriesByCategory[categoryID] else { return nil }
        seriesCategoryOrder.removeAll { $0 == categoryID }
        seriesCategoryOrder.append(categoryID)
        return items
    }
    func cacheSeries(_ items: [SeriesItem], categoryID: String) {
        if let old = seriesByCategory.removeValue(forKey: categoryID) { cachedSeriesCount -= old.count }
        seriesCategoryOrder.removeAll { $0 == categoryID }
        guard items.count <= maximumCachedSeriesItems else { return }
        while cachedSeriesCount + items.count > maximumCachedSeriesItems, let oldest = seriesCategoryOrder.first {
            seriesCategoryOrder.removeFirst()
            if let removed = seriesByCategory.removeValue(forKey: oldest) { cachedSeriesCount -= removed.count }
        }
        seriesByCategory[categoryID] = items
        seriesCategoryOrder.append(categoryID)
        cachedSeriesCount += items.count
    }
    private func clearSeriesCache() {
        seriesByCategory.removeAll(keepingCapacity: false)
        seriesCategoryOrder.removeAll(keepingCapacity: false)
        cachedSeriesCount = 0
    }
    func categories(kind: LibraryKind, model: AppModel) async throws -> [CatalogCategory] {
        if model.libraryMode == .combined {
            let result = try await combinedCategories(kind: kind, model: model)
            if model.preferences.observeCategories(result, section: CatalogSection(kind)) { model.savePreferences() }
            return result
        }
        if let cached = categoryLists[kind] { return cached }
        let epoch = generation
        if model.provider.kind == .xtream,
           let cached = await PersistentCatalogIndex.shared.loadCategories(scope: model.catalogCacheScope, kind: kind.rawValue) {
            categoryLists[kind] = cached
            return cached
        }
        let result = try await fetchCategories(kind: kind, provider: model.provider)
        guard epoch == generation else { throw CancellationError() }
        if model.preferences.observeCategories(result, section: CatalogSection(kind)) { model.savePreferences() }
        categoryLists[kind] = result
        if model.provider.kind == .xtream {
            await PersistentCatalogIndex.shared.storeCategories(result, scope: model.catalogCacheScope, kind: kind.rawValue)
        }
        return result
    }
    /// Categories for every saved provider, merged. IDs are namespaced
    /// "<providerUUID>:<categoryID>" so identical IDs never collide. One
    /// failing provider is skipped; the others' categories are kept.
    private func combinedCategories(kind: LibraryKind, model: AppModel) async throws -> [CatalogCategory] {
        if let cached = combinedCategoryLists[kind] { return cached }
        let epoch = generation
        let profiles = model.combinedProfiles
        var merged: [CatalogCategory] = []
        var failed = 0
        for profile in profiles {
            try Task.checkCancellation()
            do {
                let cats = try await fetchCategories(kind: kind, provider: profile.provider)
                let prefix = profiles.count > 1 ? profile.provider.name + " · " : ""
                merged += cats.map {
                    CatalogCategory(id: CatalogItem.namespaced(providerID: profile.id, id: $0.id),
                                    name: prefix + $0.name)
                }
            } catch { failed += 1 }
        }
        guard epoch == generation else { throw CancellationError() }
        if merged.isEmpty && failed > 0 { throw AppFailure("Every provider failed to load categories.") }
        combinedCategoryLists[kind] = merged
        return merged
    }
    private func fetchCategories(kind: LibraryKind, provider: Provider) async throws -> [CatalogCategory] {
        if provider.kind == .m3u {
            let playlist = try await PlaylistStore.shared.load(provider)
            return playlist.categories[kind] ?? []
        }
        let rows = try await DirectCatalog.rows(provider: provider, action: kind.categoryAction)
        var seen = Set<String>()
        return rows.compactMap { row -> CatalogCategory? in
            let id = row["category_id"].map { String(describing: $0) } ?? ""
            guard !id.isEmpty, id.allSatisfy(\.isNumber), seen.insert(id).inserted else { return nil }
            return CatalogCategory(id: id, name: row["category_name"] as? String ?? "Category")
        }
    }
    func items(kind: LibraryKind, category: String?, model: AppModel) async throws -> [CatalogItem] {
        if model.libraryMode == .combined { return try await combinedItems(kind: kind, category: category, model: model) }
        let key = "\(kind.rawValue):\(category ?? "all")"
        if let cached = batches[key] { return cached }
        if category == nil, let cached = completed[kind] { return cached.items }
        if model.libraryMode == .separate, model.provider.kind == .xtream {
            if let category, let disk = await PersistentCatalogIndex.shared.loadItems(scope: model.catalogCacheScope, kind: kind, categoryID: category) {
                batches[key] = disk
                batchOrder.removeAll { $0 == key }; batchOrder.append(key)
                return disk
            }
            if category == nil {
                let categories = try await self.categories(kind: kind, model: model)
                let enabledIDs = categories.filter { model.preferences.allows($0, section: CatalogSection(kind)) }.map(\.id)
                if let disk = await PersistentCatalogIndex.shared.loadSnapshot(scope: model.catalogCacheScope, kind: kind, categoryIDs: enabledIDs) {
                    completed[kind] = CatalogLoadResult(items: disk, notice: "")
                    searchable[kind] = disk
                    revision += 1
                    return disk
                }
            }
        }
        if let job = jobs[key] { return try await job.value }
        let epoch = generation
        let task = Task { @MainActor in
            if category == nil {
                let categories = try await self.categories(kind: kind, model: model)
                let enabled = categories.filter { model.preferences.allows($0, section: CatalogSection(kind)) }
                guard !enabled.isEmpty else { return [CatalogItem]() }
                if enabled.count < categories.count {
                    var result: [CatalogItem] = []
                    var seen = Set<String>()
                    for entry in enabled {
                        try Task.checkCancellation()
                        for item in try await self.fetchItems(kind: kind, category: entry.id, provider: model.provider) where seen.insert(item.id).inserted {
                            result.append(item)
                        }
                    }
                    return result
                }
            }
            return try await self.fetchItems(kind: kind, category: category, provider: model.provider)
        }
        jobs[key] = task
        do {
            let result = try await task.value
            guard epoch == generation else { throw CancellationError() }
            jobs[key] = nil
            // Cache six categories; full results have their own bounded slot per media type.
            if category != nil {
                batches[key] = result; batchOrder.removeAll { $0 == key }; batchOrder.append(key)
                while batchOrder.count > 1 && (batchOrder.count > 6 || batches.values.reduce(0, { $0 + $1.count }) > CatalogIndex.maximumItems) { batches[batchOrder.removeFirst()] = nil }
                if model.libraryMode == .separate, model.provider.kind == .xtream, let category {
                    await PersistentCatalogIndex.shared.storeItems(result, scope: model.catalogCacheScope, kind: kind, categoryID: category, provider: model.provider)
                }
            }
            return result
        } catch { if epoch == generation { jobs[key] = nil }; throw error }
    }
    /// Items in combined mode. A namespaced category ("<uuid>:<catID>")
    /// loads from its owning provider only; nil loads every provider's full
    /// catalog (one request each), tagging items and skipping failures.
    private func combinedItems(kind: LibraryKind, category: String?, model: AppModel) async throws -> [CatalogItem] {
        if let category {
            guard let (pid, raw) = CatalogItem.splitNamespaced(category),
                  let profile = model.vault.profiles.first(where: { $0.id == pid }) else { return [] }
            let rawItems = try await fetchItems(kind: kind, category: raw, provider: profile.provider)
            return tagCombined(rawItems, providerID: pid)
        }
        var merged: [CatalogItem] = []
        var seen = Set<String>()
        var failed = 0
        for profile in model.combinedProfiles {
            try Task.checkCancellation()
            do {
                let batch = tagCombined(try await fetchProviderCatalog(kind: kind, provider: profile.provider,
                                                                       preferences: model.preferences, providerID: profile.id),
                                        providerID: profile.id)
                for item in batch where seen.insert(item.scopedID).inserted { merged.append(item) }
            } catch { failed += 1 }
        }
        if merged.isEmpty && failed > 0 { throw AppFailure("Every provider failed to load.") }
        return merged
    }
    /// Tags items with their owning provider and namespaces their category
    /// IDs to match the combined category list.
    private func tagCombined(_ items: [CatalogItem], providerID pid: UUID) -> [CatalogItem] {
        items.map { item in
            var tagged = item
            tagged.providerID = pid
            tagged.categoryID = CatalogItem.namespaced(providerID: pid, id: item.categoryID)
            return tagged
        }
    }
    /// One unscoped request when it actually spans the library. A payload that
    /// only contains the category the provider last served falls back to the
    /// same per-category requests browsing uses, including plain HTTP.
    private func fetchProviderCatalog(kind: LibraryKind, provider: Provider,
                                      preferences: LibraryPreferences? = nil, providerID: UUID? = nil) async throws -> [CatalogItem] {
        let listed: [CatalogCategory]
        var listedOK = true
        do { listed = try await fetchCategories(kind: kind, provider: provider) }
        catch is CancellationError { throw CancellationError() }
        catch { listed = []; listedOK = false }
        guard listedOK else { throw AppFailure("The provider catalog could not be loaded.") }
        let allowed = listed.filter { category in
            guard let preferences else { return true }
            let id = providerID.map { CatalogItem.namespaced(providerID: $0, id: category.id) } ?? category.id
            return preferences.allows(CatalogCategory(id: id, name: category.name), section: CatalogSection(kind))
        }
        guard !allowed.isEmpty else { return [] }
        let full: [CatalogItem]?
        do { full = allowed.count == listed.count ? try await fetchItems(kind: kind, category: nil, provider: provider) : nil }
        catch is CancellationError { throw CancellationError() }
        catch { full = nil }
        if let full, !listedOK || CatalogCoverage.isComplete(categoryIDs: full.map(\.categoryID), categoryCount: listed.count) {
            return full
        }
        guard listedOK else { throw AppFailure("The provider catalog could not be loaded.") }
        var items: [CatalogItem] = []
        var seen = Set<String>()
        var failed = 0
        for category in allowed {
            try Task.checkCancellation()
            do {
                let batch = try await fetchItems(kind: kind, category: category.id, provider: provider)
                for item in batch where seen.insert(item.id).inserted { items.append(item) }
            } catch {
                try Task.checkCancellation()
                failed += 1
            }
        }
        if items.isEmpty && (failed > 0 || full == nil) { throw AppFailure("The provider catalog could not be loaded.") }
        return items
    }
    private func fetchItems(kind: LibraryKind, category: String?, provider: Provider) async throws -> [CatalogItem] {
        if provider.kind == .m3u {
            let playlist = try await PlaylistStore.shared.load(provider)
            return playlist.items.filter { $0.kind == kind && (category == nil || $0.categoryID == category) }
        }
        let rows = try await DirectCatalog.rows(provider: provider, action: kind.streamAction, category: category)
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { rows.compactMap { CatalogItem.parse($0, kind: kind) } }
        var result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        if let category { result = result.map { var item = $0; if item.categoryID.isEmpty { item.categoryID = category }; return item } }
        return result
    }
    func loadAll(kind: LibraryKind, model: AppModel) async throws -> CatalogLoadResult {
        if model.libraryMode == .combined { return try await combinedLoadAll(kind: kind, model: model) }
        if let cached = completed[kind] { return cached }
        if model.provider.kind == .xtream {
            let categories = try await self.categories(kind: kind, model: model)
            let enabledIDs = categories.filter { model.preferences.allows($0, section: CatalogSection(kind)) }.map(\.id)
            if let disk = await PersistentCatalogIndex.shared.loadSnapshot(scope: model.catalogCacheScope, kind: kind, categoryIDs: enabledIDs) {
                let result = CatalogLoadResult(items: disk, notice: "")
                completed[kind] = result; searchable[kind] = disk; progress[kind] = nil; revision += 1
                return result
            }
        }
        if let job = fullJobs[kind] { return try await job.value }
        let epoch = generation
        let task = Task { @MainActor in
            let categories = try await self.categories(kind: kind, model: model)
            let enabled = categories.filter { model.preferences.allows($0, section: CatalogSection(kind)) }
            guard !enabled.isEmpty else { return CatalogLoadResult(items: [], notice: "") }
            return try await CatalogLoader.load(categoryIDs: enabled.map(\.id), preferFullCatalog: enabled.count == categories.count, fetch: { category in
                try await self.items(kind: kind, category: category, model: model)
            }, progress: { partial, message in
                guard epoch == self.generation else { return }
                self.searchable[kind] = partial; self.progress[kind] = message; self.revision += 1
            })
        }
        fullJobs[kind] = task
        do {
            let result = try await task.value
            guard epoch == generation else { throw CancellationError() }
            fullJobs[kind] = nil; searchable[kind] = result.items; progress[kind] = nil; revision += 1
            // Partial failures remain retryable; do not mislabel them as complete.
            if result.notice.isEmpty {
                completed[kind] = result
                if model.libraryMode == .separate, model.provider.kind == .xtream {
                    let categories = categoryLists[kind] ?? []
                    let enabledIDs = categories.filter { model.preferences.allows($0, section: CatalogSection(kind)) }.map(\.id)
                    await PersistentCatalogIndex.shared.markSnapshot(scope: model.catalogCacheScope, kind: kind, categoryIDs: enabledIDs, items: result.items, provider: model.provider)
                }
            }
            return result
        } catch { if epoch == generation { fullJobs[kind] = nil; progress[kind] = nil }; throw error }
    }
    /// Whole-catalog load across every saved provider for search: one bounded
    /// request per provider, partial results published as each arrives, and a
    /// failing provider never aborts the others.
    private func combinedLoadAll(kind: LibraryKind, model: AppModel) async throws -> CatalogLoadResult {
        if let cached = combinedCompleted[kind] { return cached }
        if let job = combinedFullJobs[kind] { return try await job.value }
        let epoch = generation
        let task = Task { @MainActor in
            var merged: [CatalogItem] = []
            var seen = Set<String>()
            var failed = 0
            let profiles = model.combinedProfiles
            for (offset, profile) in profiles.enumerated() {
                try Task.checkCancellation()
                do {
                let batch = self.tagCombined(try await self.fetchProviderCatalog(kind: kind, provider: profile.provider,
                                                                                 preferences: model.preferences, providerID: profile.id),
                                                 providerID: profile.id)
                    try Task.checkCancellation()
                    for item in batch where seen.insert(item.scopedID).inserted { merged.append(item) }
                } catch { failed += 1 }
                guard epoch == self.generation else { throw CancellationError() }
                self.searchable[kind] = merged
                self.progress[kind] = "Loading provider \(offset + 1) of \(profiles.count)…"
                self.revision += 1
            }
            let notice = failed == 0 ? "" : "\(failed) providers could not be loaded. Showing available results."
            return CatalogLoadResult(items: merged, notice: notice)
        }
        combinedFullJobs[kind] = task
        do {
            let result = try await task.value
            guard epoch == generation else { throw CancellationError() }
            combinedFullJobs[kind] = nil; searchable[kind] = result.items; progress[kind] = nil; revision += 1
            if result.notice.isEmpty { combinedCompleted[kind] = result }
            return result
        } catch { if epoch == generation { combinedFullJobs[kind] = nil; progress[kind] = nil }; throw error }
    }
}

#if os(iOS)
struct MovieCard: View {
    @EnvironmentObject private var model: AppModel
    let item: CatalogItem
    var body: some View {
        PosterTile(title: model.preferences.itemTitle(item), caption: PosterCaption.film(year: item.year), poster: item.poster)
            .contextMenu { MobileSaveButton(record: MobileRecords.record(item)) }
    }
}

struct MoviesHomeView: View {
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var categories: [CatalogCategory] = []
    @State private var featured: CatalogItem?
    @State private var featuredLoading = false
    @State private var playing: CatalogItem?
    @State private var error = ""
    @State private var categoryCount = 6
    @State private var retry = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    StreamHeading(title: "Movies", subtitle: "Something great to watch.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 20)
                    if !categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: true) {
                            LazyHStack(spacing: 10) {
                                NavigationLink { LibraryView(kind: .movies, initialCategoryID: "all", embedded: true) } label: {
                                    Text("All titles").font(.subheadline.weight(.semibold)).fixedSize()
                                        .padding(.horizontal, 18).padding(.vertical, 12)
                                        .foregroundStyle(StreamTheme.text).background(StreamTheme.panel, in: Capsule())
                                }.buttonStyle(.plain)
                                ForEach(categories) { category in
                                    NavigationLink { LibraryView(kind: .movies, initialCategoryID: category.id, embedded: true) } label: {
                                        Text(category.name).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                                            .padding(.horizontal, 18).padding(.vertical, 11)
                                            .foregroundStyle(StreamTheme.text).background(StreamTheme.panel, in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 22).padding(.vertical, 4)
                        }.frame(height: 62).scrollClipDisabled()
                    }
                    if let featured {
                        Button { playing = featured } label: {
                            MobileHero(title: model.preferences.itemTitle(featured), poster: featured.poster)
                        }.buttonStyle(.plain).padding(.horizontal, 16)
                    } else if featuredLoading && model.providerReady {
                        ProgressView("Loading movies…").frame(maxWidth: .infinity).padding(40)
                    }
                    if !model.providerReady {
                        Button("Add your provider to browse movies") { model.settingsVisible = true }.padding()
                    }
                    if !error.isEmpty {
                        VStack(alignment: .leading) { Text(error).foregroundStyle(.secondary); Button("Retry") { retry += 1 } }.padding(.horizontal)
                    }
                    ForEach(Array(categories.prefix(categoryCount))) { category in
                        MovieShelf(category: category) { playing = $0 }
                    }
                    if categoryCount < categories.count {
                        Button("More categories") { categoryCount += 6 }.padding()
                    }
                }.padding(.bottom, 24)
            }
            .background { StreamBackdrop() }
            .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
            .navigationTitle("Movies").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("AS").font(.caption.weight(.black)).foregroundStyle(StreamTheme.accent) }
                ToolbarItem(placement: .topBarTrailing) { Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account settings") }
            }
            .task(id: "\(model.libraryRevision)-\(retry)") {
                featured = nil; categories = []; error = ""; categoryCount = 6
                featuredLoading = true
                defer { featuredLoading = false }
                guard model.providerReady else { return }
                do {
                    let loaded = try await catalog.categories(kind: .movies, model: model)
                    try Task.checkCancellation()
                    categories = model.preferences.browseCategories(loaded, section: .movies)
                    if let first = categories.first {
                        let items = try await catalog.items(kind: .movies, category: first.id, model: model)
                        try Task.checkCancellation()
                        featured = items.first { $0.poster != nil } ?? items.first
                    }
                    if loaded.isEmpty { error = "No movie categories are available." }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .fullScreenCover(item: $playing) { CatalogDestination(item: $0) }
        }
    }
}

struct MovieShelf: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    let category: CatalogCategory
    let play: (CatalogItem) -> Void
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @State private var items: [CatalogItem] = []
    @State private var error = ""
    @State private var retry = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(StreamTheme.accentFill(for: AppAppearance(rawValue: appearance) ?? .dark))
                    .frame(width: 4, height: 22)
                Text(category.name).font(.title3.bold()).lineLimit(1)
                Spacer()
                NavigationLink("See all") { LibraryView(kind: .movies, initialCategoryID: category.id, embedded: true) }.font(.subheadline.weight(.semibold))
            }.padding(.horizontal)
            if !error.isEmpty {
                HStack { Text(error).font(.caption); Button("Retry") { retry += 1 } }.padding(.horizontal)
            } else if items.isEmpty { ProgressView().padding(.horizontal) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(items.prefix(20))) { item in
                        Button { play(item) } label: { MovieCard(item: item).frame(width: 156) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
        }
        .task(id: "\(category.id)-\(model.libraryRevision)-\(retry)") {
            do {
                error = ""
                let loaded = try await catalog.items(kind: .movies, category: category.id, model: model)
                try Task.checkCancellation(); items = Array(loaded.filter(model.preferences.visible).prefix(20))
                if loaded.isEmpty { error = "No movies in this category." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

#endif

struct SearchHit: Identifiable {
    let item: CatalogItem
    var id: String { "\(item.kind.rawValue):\(item.scopedID)" }
}

enum UnifiedSearch {
    static func matches(_ items: [CatalogItem], query: String, filter: String) -> [SearchHit] {
        CatalogIndex.matches(items, query: query).filter { filter == "all" || $0.kind.rawValue == filter }.map { SearchHit(item: $0) }
    }
}

#if os(iOS)
struct GlobalSearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var query = ""
    @State private var filter = "all"
    @State private var results: [SearchHit] = []
    @State private var notices: [String] = []
    @State private var playing: CatalogItem?
    @State private var seriesStore: SeriesStore?
    @State private var allSeries: [SeriesItem] = []
    @State private var seriesNotice = ""
    @State private var selectedSeries: SeriesItem?
    @State private var limit = 60
    @State private var retry = 0
    private var hasQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Movies, Live TV and TV Shows", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    StreamOptionPicker(options: [("all", "All"), (LibraryKind.movies.rawValue, "Movies"), (LibraryKind.live.rawValue, "Live TV"), ("series", "TV Shows")], selection: $filter)
                    if !hasQuery {
                        StreamHeading(title: "Find your next favorite", subtitle: "Search movies, live channels and TV shows together. Enter at least two characters.").padding(.vertical, 20)
                        Label("Every category. One search.", systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: StreamTheme.corner))
                    }
                    if hasQuery {
                        ForEach(LibraryKind.allCases.filter { filter == "all" || $0.rawValue == filter }) { kind in
                            if let progress = catalog.progress[kind] { ProgressView("\(kind.title): \(progress)").font(.caption) }
                        }
                        ForEach(notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        if !notices.isEmpty { Button("Retry unavailable catalogs") { retry += 1 } }
                        ForEach(Array(results.prefix(limit))) { hit in
                            Button { playing = hit.item } label: {
                                HStack(spacing: 14) {
                                    ProviderPoster(url: hit.item.poster, kind: hit.item.kind).frame(width: 64, height: 90).clipShape(RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(model.preferences.itemTitle(hit.item)).font(.headline).lineLimit(2)
                                        Label(hit.item.kind.title, systemImage: hit.item.kind.symbol).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "play.circle").font(.title2)
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain)
                        }
                        if results.count > limit { Button("More results") { limit += 60 } }
                        if filter == "all" || filter == "series" {
                            if !seriesNotice.isEmpty { Text(seriesNotice).font(.caption).foregroundStyle(.secondary) }
                            let seriesMatches = SeriesSearchScope.matching(allSeries, query: query, categories: seriesStore?.categories ?? [], preferences: model.preferences)
                            if !seriesMatches.isEmpty {
                                Text("TV Shows").font(.title3.bold()).padding(.top, 8)
                                ForEach(Array(seriesMatches.prefix(limit))) { series in
                                    Button { selectedSeries = series } label: {
                                        HStack(spacing: 14) {
                                            ProviderPoster(url: series.poster, kind: .movies).frame(width: 64, height: 90).clipShape(RoundedRectangle(cornerRadius: 7))
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(model.preferences.seriesTitle(series)).font(.headline).lineLimit(2)
                                                Label("TV Show", systemImage: "play.tv").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(); Image(systemName: "chevron.right").font(.title2).foregroundStyle(.secondary)
                                        }.foregroundStyle(.primary)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if catalog.progress.isEmpty && results.isEmpty { Text("No matching titles in the loaded catalogs.").foregroundStyle(.secondary) }
                    }
                }.padding()
            }.background { StreamBackdrop() }
            .navigationTitle("Search")
            .task(id: "\(hasQuery)-\(filter)-\(model.libraryRevision)-\(retry)") {
                guard hasQuery, model.providerReady else { return }
                notices = []
                // Only load the catalogs the selected filter needs — no more
                // "Movies: Loading full catalog…" when TV Shows is selected.
                let scope = filter
                if scope == "all" {
                    // Three media types at most, never one network request per keystroke.
                    async let movies: Void = load(.movies)
                    async let live: Void = load(.live)
                    async let series: Void = loadSeries()
                    _ = await (movies, live, series)
                } else if scope == LibraryKind.movies.rawValue {
                    await load(.movies)
                } else if scope == LibraryKind.live.rawValue {
                    await load(.live)
                } else if scope == "series" {
                    await loadSeries()
                }
            }
            .task(id: "\(query)-\(filter)-\(catalog.revision)-\(model.libraryRevision)") {
                limit = 60
                guard hasQuery else { results = []; return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let snapshot = LibraryKind.allCases.flatMap { kind in
                    (catalog.searchable[kind] ?? []).filter { model.preferences.accepts($0, categories: catalog.knownCategories(kind: kind)) }
                }
                let term = query; let choice = filter
                let worker = Task.detached(priority: .userInitiated) { UnifiedSearch.matches(snapshot, query: term, filter: choice) }
                let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; results = found
            }
            .fullScreenCover(item: $playing) { CatalogDestination(item: $0, channels: catalog.searchable[.live] ?? []) }
            .fullScreenCover(item: $selectedSeries) { series in
                if let store = seriesStore { ShowDetailView(series: series, store: store) }
            }
        }
    }
    private func load(_ kind: LibraryKind) async {
        do {
            let result = try await catalog.loadAll(kind: kind, model: model)
            if !Task.isCancelled && !result.notice.isEmpty { notices.append("\(kind.title): \(result.notice)") }
        } catch { if !Task.isCancelled { notices.append("\(kind.title): \(error.localizedDescription)") } }
    }
    private func loadSeries() async {
        if seriesStore == nil { seriesStore = SeriesStore(model: model) }
        guard let store = seriesStore else { return }
        let items = await store.loadAllSeries { items, _ in
            guard !Task.isCancelled else { return }
            allSeries = items
        }
        guard !Task.isCancelled else { return }
        allSeries = items
        seriesNotice = store.searchNotice
    }
}

#endif

// Device-local personalization stores only provider-scoped IDs and playback times.
struct MovieProgress: Codable, Equatable {
    let seconds: Double
    let duration: Double
    let updated: Double
    var label: String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
struct LibraryPreferences: Codable {
    var hiddenLiveCategories: Set<String> = []
    var hiddenMovieCategories: Set<String> = []
    var hiddenSeriesCategories: Set<String> = []
    /// Sections become opt-in for newly discovered IDs only after the user
    /// changes that section. Legacy hidden-ID preferences remain compatible.
    var customizedCategorySections: Set<String> = []
    var knownCategoryIDs: [String: Set<String>] = [:]
    var hiddenChannels: Set<String> = []
    var progress: [String: MovieProgress] = [:]
    var categoryOrder: [String: [String]] = [:]
    var renames: [String: String] = [:]
    /// On hides categories explicitly tagged for another country. Untagged categories stay.
    var unitedStatesOnly: Bool = true
    /// Automatically hide categories explicitly marked as non-English.
    var hideNonEnglishCategories: Bool = true
    /// Display-only cleanup of category and channel names.
    var cleanNames: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case hiddenLiveCategories, hiddenMovieCategories, hiddenSeriesCategories, customizedCategorySections, knownCategoryIDs, hiddenChannels, progress, categoryOrder, renames, unitedStatesOnly, hideNonEnglishCategories, cleanNames
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenLiveCategories = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenLiveCategories) ?? []
        hiddenMovieCategories = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenMovieCategories) ?? []
        hiddenSeriesCategories = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenSeriesCategories) ?? []
        customizedCategorySections = try container.decodeIfPresent(Set<String>.self, forKey: .customizedCategorySections) ?? []
        knownCategoryIDs = try container.decodeIfPresent([String: Set<String>].self, forKey: .knownCategoryIDs) ?? [:]
        hiddenChannels = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenChannels) ?? []
        progress = try container.decodeIfPresent([String: MovieProgress].self, forKey: .progress) ?? [:]
        categoryOrder = try container.decodeIfPresent([String: [String]].self, forKey: .categoryOrder) ?? [:]
        renames = try container.decodeIfPresent([String: String].self, forKey: .renames) ?? [:]
        unitedStatesOnly = try container.decodeIfPresent(Bool.self, forKey: .unitedStatesOnly) ?? true
        hideNonEnglishCategories = try container.decodeIfPresent(Bool.self, forKey: .hideNonEnglishCategories) ?? true
        cleanNames = try container.decodeIfPresent(Bool.self, forKey: .cleanNames) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hiddenLiveCategories, forKey: .hiddenLiveCategories)
        try container.encode(hiddenMovieCategories, forKey: .hiddenMovieCategories)
        try container.encode(hiddenSeriesCategories, forKey: .hiddenSeriesCategories)
        try container.encode(customizedCategorySections, forKey: .customizedCategorySections)
        try container.encode(knownCategoryIDs, forKey: .knownCategoryIDs)
        try container.encode(hiddenChannels, forKey: .hiddenChannels)
        try container.encode(progress, forKey: .progress)
        try container.encode(categoryOrder, forKey: .categoryOrder)
        try container.encode(renames, forKey: .renames)
        try container.encode(unitedStatesOnly, forKey: .unitedStatesOnly)
        try container.encode(hideNonEnglishCategories, forKey: .hideNonEnglishCategories)
        try container.encode(cleanNames, forKey: .cleanNames)
    }
    static func read(key: String?) -> Self {
        guard let key, let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func write(key: String?) {
        guard let key, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func categoryVisible(_ id: String, kind: LibraryKind) -> Bool {
        categoryVisible(id, section: CatalogSection(kind))
    }
    func visible(_ item: CatalogItem) -> Bool {
        categoryVisible(item.categoryID, kind: item.kind) && (item.kind != .live || !hiddenChannels.contains(item.scopedID))
    }
    mutating func setCategory(_ id: String, kind: LibraryKind, visible: Bool) {
        let section = CatalogSection(kind)
        customizedCategorySections.insert(section.rawValue)
        if kind == .live { if visible { hiddenLiveCategories.remove(id) } else { hiddenLiveCategories.insert(id) } }
        else { if visible { hiddenMovieCategories.remove(id) } else { hiddenMovieCategories.insert(id) } }
    }
    mutating func resetCategorySection(_ section: CatalogSection) {
        customizedCategorySections.remove(section.rawValue)
        switch section {
        case .live: hiddenLiveCategories = []
        case .movies: hiddenMovieCategories = []
        case .series: hiddenSeriesCategories = []
        }
    }
    mutating func setCategories(_ ids: Set<String>, section: CatalogSection, visible: Bool) {
        customizedCategorySections.insert(section.rawValue)
        switch section {
        case .live: if visible { hiddenLiveCategories.subtract(ids) } else { hiddenLiveCategories.formUnion(ids) }
        case .movies: if visible { hiddenMovieCategories.subtract(ids) } else { hiddenMovieCategories.formUnion(ids) }
        case .series: if visible { hiddenSeriesCategories.subtract(ids) } else { hiddenSeriesCategories.formUnion(ids) }
        }
    }
    @discardableResult mutating func observeCategories(_ categories: [CatalogCategory], section: CatalogSection) -> Bool {
        let current = Set(categories.map(\.id))
        let previous = knownCategoryIDs[section.rawValue] ?? []
        var changed = current != previous
        if customizedCategorySections.contains(section.rawValue) {
            let newlyDiscovered = current.subtracting(previous)
            changed = changed || !newlyDiscovered.isEmpty
            switch section {
            case .live: hiddenLiveCategories.formUnion(newlyDiscovered)
            case .movies: hiddenMovieCategories.formUnion(newlyDiscovered)
            case .series: hiddenSeriesCategories.formUnion(newlyDiscovered)
            }
        }
        knownCategoryIDs[section.rawValue] = current
        return changed
    }
}
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light, ghost, nebula
    var id: String { rawValue }
    var title: String { switch self { case .dark: return "Dark"; case .light: return "iOS Light"; case .ghost: return "Ghost"; case .nebula: return "Nebula" } }
    var scheme: ColorScheme { self == .light ? .light : .dark }
    var accent: Color { StreamTheme.accent(for: self) }

    static func migrateStoredSelection(in defaults: UserDefaults = .standard) {
        let key = "rigatoni-appearance"
        switch defaults.string(forKey: key) {
        case "netflix": defaults.set(AppAppearance.dark.rawValue, forKey: key)
        case "xfinity", "midnight": defaults.set(AppAppearance.nebula.rawValue, forKey: key)
        default: break
        }
    }
}

#if os(iOS)
/// Drag and drop delivers enter events as a long-press gesture crosses each
/// row, while the surrounding ScrollView retains native edge auto-scrolling.
private struct CategorySelectionDropDelegate: DropDelegate {
    let entered: () -> Void
    let dropped: () -> Bool
    func dropEntered(info: DropInfo) { entered() }
    func performDrop(info: DropInfo) -> Bool { dropped() }
    func validateDrop(info: DropInfo) -> Bool { true }
}
#endif

struct LibraryCustomizationView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = AppAppearance.dark.rawValue
    @State private var categories: [CatalogCategory] = []
    @State private var channels: [CatalogItem] = []
    @State private var section = CatalogSection.live
    @State private var selected = ""
    @State private var query = ""
    @State private var error = ""
    @State private var loading = false
    @State private var limit = 100
    @State private var drafts: [String: String] = [:]
    @State private var multiSelecting = false
    @State private var selectedCategoryIDs: Set<String> = []
    @State private var categoryDragActive = false
    @State private var dragSelectionVisible = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Make it yours").font(.largeTitle.bold())
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Themes, hidden categories, order and names are saved on this device for the current provider. Credentials stay in the Keychain.").font(.footnote).foregroundStyle(.secondary)
                LibraryFilterToggles()
                Picker("Manage", selection: $section) { ForEach(CatalogSection.allCases) { Text($0.title).tag($0) } }
                TextField("Find category or channel", text: $query)
                Text("Categories").font(.title2.bold())
                Text("Hide a category to remove it from browsing, the guide and Home. Move changes the order. A custom name replaces the automatic cleanup for that item only.").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Select All") { setCategories(categories, visible: true) }
                        Button("Deselect All") { setCategories(categories, visible: false) }
                        Button("Reset to Defaults") {
                            model.preferences.resetCategorySection(section)
                            if section == .live { model.preferences.hiddenChannels = [] }
                            model.savePreferences(invalidateVisibilitySearch: true)
                        }
                    }
                    HStack {
                        Button("Select Filtered") { setCategories(filteredCategories, visible: true) }
                        Button("Hide Filtered") { setCategories(filteredCategories, visible: false) }
                        Button(multiSelecting ? "Done Selecting" : "Multi-Select") {
                            multiSelecting.toggle(); selectedCategoryIDs = []
                        }
                        Button("Reset order") {
                            model.preferences.categoryOrder[section.rawValue] = nil
                            model.savePreferences()
                        }
                    }
                    if multiSelecting {
                        HStack {
                            Text("\(selectedCategoryIDs.count) selected")
                            Button("Show Selected") { setSelectedCategories(visible: true) }
                            Button("Hide Selected") { setSelectedCategories(visible: false) }
                            Button("Select Visible") { selectedCategoryIDs = Set(listedCategories.map(\.id)) }
                            Button("Clear Selection") { selectedCategoryIDs = [] }
                        }.buttonStyle(.bordered)
                    }
                }.buttonStyle(.bordered)
                if loading { ProgressView("Loading…") }
                if !error.isEmpty { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await load() } } }
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(listedCategories) { category in
                        categoryRow(category)
                    }
                }
                if section == .live && !categories.isEmpty {
                    Text("Channels").font(.title2.bold())
                    Picker("Channel category", selection: $selected) {
                        Text("Choose a category").tag("")
                        ForEach(categories) { Text(model.preferences.categoryTitle($0, section: .live)).tag($0.id) }
                    }
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(listedChannels.prefix(limit))) { item in channelRow(item) }
                    }
                    if listedChannels.count > limit { Button("More channels") { limit += 100 } }
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.background { StreamBackdrop() }.navigationTitle("Categories & names")
        .task(id: "\(section.rawValue)-\(model.provider.server)") { await load() }
        .task(id: selected) {
            channels = []; limit = 100; guard section == .live, !selected.isEmpty else { return }
            do { channels = try await model.catalog.items(kind: .live, category: selected, model: model) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private var listedCategories: [CatalogCategory] {
        model.preferences.managedOrder(categories, section: section).filter { category in
            query.isEmpty || searchText(for: category).localizedCaseInsensitiveContains(query)
        }
    }
    private var filteredCategories: [CatalogCategory] { listedCategories }
    private func searchText(for category: CatalogCategory) -> String {
        let providerNames = model.libraryMode == .combined ? model.combinedProfiles.map { $0.provider.name } : [model.provider.name]
        return ([category.name, model.preferences.categoryTitle(category, section: section)] + providerNames).joined(separator: " ")
    }
    private func setCategories(_ categories: [CatalogCategory], visible: Bool) {
        guard !categories.isEmpty else { return }
        model.preferences.setCategories(Set(categories.map(\.id)), section: section, visible: visible)
        model.savePreferences(invalidateVisibilitySearch: true)
    }
    private func setSelectedCategories(visible: Bool) {
        let ids = selectedCategoryIDs
        guard !ids.isEmpty else { return }
        model.preferences.setCategories(ids, section: section, visible: visible)
        model.savePreferences(invalidateVisibilitySearch: true); selectedCategoryIDs = []
    }
    private func finishCategoryDrag() {
        guard categoryDragActive else { return }
        let ids = selectedCategoryIDs
        if !ids.isEmpty {
            model.preferences.setCategories(ids, section: section, visible: dragSelectionVisible)
            model.savePreferences(invalidateVisibilitySearch: true)
        }
        categoryDragActive = false
    }
    private var listedChannels: [CatalogItem] {
        channels.filter { item in
            query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || model.preferences.itemTitle(item).localizedCaseInsensitiveContains(query)
        }
    }
    private func categoryRow(_ category: CatalogCategory) -> some View {
        let key = LibraryPreferences.renameKey(section: section, role: "category", id: category.id)
        let title = model.preferences.categoryTitle(category, section: section)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if multiSelecting {
                    Button {
                        if selectedCategoryIDs.contains(category.id) { selectedCategoryIDs.remove(category.id) }
                        else { selectedCategoryIDs.insert(category.id) }
                    } label: {
                        Image(systemName: selectedCategoryIDs.contains(category.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                    }.accessibilityLabel(selectedCategoryIDs.contains(category.id) ? "Deselect category" : "Select category")
                }
                Toggle(title, isOn: Binding(get: { model.preferences.categoryVisible(category.id, section: section) }, set: {
                model.preferences.setSection(category.id, section: section, visible: $0); model.savePreferences(invalidateVisibilitySearch: true)
                }))
            }
            if title != category.name { Text(category.name).font(.caption).foregroundStyle(.secondary) }
            if model.preferences.hideNonEnglishCategories && CategoryRegion.isNonEnglish(category.name) {
                Text("Hidden while Hide non-English categories is on").font(.caption).foregroundStyle(.secondary)
            } else if model.preferences.unitedStatesOnly && !CategoryRegion.included(category.name, unitedStatesOnly: true) {
                Text("Hidden while U.S. only is on").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Custom name", text: draft(key))
                Button("Save name") { commit(key) }
                if model.preferences.renames[key] != nil {
                    Button("Use automatic") { model.preferences.setRename(nil, key: key); drafts[key] = ""; model.savePreferences() }
                }
            }
            if query.isEmpty {
                HStack {
                    Button("Move up") { model.preferences.moveCategory(category.id, section: section, direction: -1, among: categories); model.savePreferences() }
                    Button("Move down") { model.preferences.moveCategory(category.id, section: section, direction: 1, among: categories); model.savePreferences() }
                }.buttonStyle(.bordered)
            }
        }
        #if os(iOS)
        .onLongPressGesture(minimumDuration: 0.45) {
            multiSelecting = true
            selectedCategoryIDs.insert(category.id)
        }
        .onDrag {
            multiSelecting = true
            categoryDragActive = true
            selectedCategoryIDs = [category.id]
            dragSelectionVisible = !model.preferences.categoryVisible(category.id, section: section)
            return NSItemProvider(object: category.id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: CategorySelectionDropDelegate(
            entered: {
                if categoryDragActive { selectedCategoryIDs.insert(category.id) }
            },
            dropped: {
                guard categoryDragActive else { return false }
                selectedCategoryIDs.insert(category.id)
                finishCategoryDrag()
                return true
            }
        ))
        #endif
    }
    private func channelRow(_ item: CatalogItem) -> some View {
        let key = LibraryPreferences.renameKey(section: .live, role: "item", id: item.scopedID)
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(model.preferences.itemTitle(item), isOn: Binding(get: { !model.preferences.hiddenChannels.contains(item.scopedID) }, set: {
                if $0 { model.preferences.hiddenChannels.remove(item.scopedID) } else { model.preferences.hiddenChannels.insert(item.scopedID) }
                model.savePreferences()
            }))
            if model.preferences.itemTitle(item) != item.name { Text(item.name).font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("Custom name", text: draft(key))
                Button("Save name") { commit(key) }
                if model.preferences.renames[key] != nil {
                    Button("Use automatic") { model.preferences.setRename(nil, key: key); drafts[key] = ""; model.savePreferences() }
                }
            }
        }
    }
    private func draft(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? model.preferences.renames[key] ?? "" }, set: { drafts[key] = $0 })
    }
    private func commit(_ key: String) {
        model.preferences.setRename(drafts[key] ?? model.preferences.renames[key], key: key)
        model.savePreferences()
    }
    private func load() async {
        categories = []; channels = []; selected = ""; error = ""; loading = true
        defer { loading = false }
        guard model.providerReady else { error = "Save a provider first."; return }
        do {
            switch section {
            case .series:
                let store = SeriesStore(model: model)
                await store.loadCategories()
                if let reason = store.unavailableReason { error = reason }
                else if !store.error.isEmpty { error = store.error }
                else { categories = store.categories }
            case .live:
                categories = try await model.catalog.categories(kind: .live, model: model)
            case .movies:
                categories = try await model.catalog.categories(kind: .movies, model: model)
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct MovieInformation: Equatable {
    var overview = ""
    var release = ""
    var genre = ""
    static func parse(_ row: [String: Any]) -> Self {
        let info = row["info"] as? [String: Any] ?? [:]
        let movie = row["movie_data"] as? [String: Any] ?? [:]
        func value(_ names: [String]) -> String {
            for name in names {
                for source in [info, movie] {
                    if let value = source[name] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
                }
            }
            return ""
        }
        return Self(overview: value(["plot", "description"]), release: value(["releasedate", "releaseDate", "release_date"]), genre: value(["genre"]))
    }
}

// A detail page is used by every movie entry point on both platforms.
struct MovieDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    @State private var info = MovieInformation()
    @State private var loading = true
    @State private var metadataNotice = ""
    @State private var playing = false
    @State private var resumeSeconds = 0.0
#if os(tvOS)
    @State private var movieSources: [CatalogItem] = []
    @State private var selectedMovieSource: CatalogItem?
    @State private var movieSourcesLoading = false
    @State private var movieSourcesProgress = ""
    @State private var movieSourcesNotice = ""
#endif
    // Shared bindings identify the detail actions; tvOS also needs a directional
    // focus section because the poster separates Back from the action column.
    @FocusState private var detailFocus: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                        .focused($detailFocus, equals: "back")
                    Spacer(minLength: 0)
                }
                #if os(tvOS)
                // Match the detail row's width so Up from Play/Continue can
                // reach Back even though the button is above the poster.
                .focusSection()
                #endif
                HStack(alignment: .top, spacing: 28) {
                    ProviderPoster(url: item.poster, kind: .movies).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(maxWidth: posterWidth).clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 18) {
                        Text(model.preferences.itemTitle(item)).font(.largeTitle.bold())
                        if !info.release.isEmpty { Text("Released \(info.release)").foregroundStyle(.secondary) }
                        if !info.genre.isEmpty { Text(info.genre).foregroundStyle(.secondary) }
                        if let saved = model.preferences.progress[item.id] {
                            Button { resumeSeconds = saved.seconds; playing = true } label: { Label("Continue from \(saved.label)", systemImage: "play.fill") }.buttonStyle(.borderedProminent).foregroundStyle(StreamTheme.onAccent)
                                .focused($detailFocus, equals: "play")
                            Button("Restart movie") { restart() }.buttonStyle(.bordered)
                                .focused($detailFocus, equals: "restart")
                        } else {
                            Button { resumeSeconds = 0; playing = true } label: { Label("Play movie", systemImage: "play.fill") }.buttonStyle(.borderedProminent).foregroundStyle(StreamTheme.onAccent)
                                .focused($detailFocus, equals: "play")
                        }
#if os(tvOS)
                        Button {
                            Task { await findMovieSources() }
                        } label: {
                            Label("Choose Stream", systemImage: "play.tv")
                        }
                        .buttonStyle(.bordered)
                        .focused($detailFocus, equals: "sources")
                        if movieSourcesLoading {
                            ProgressView(movieSourcesProgress.isEmpty ? "Finding enabled sources…" : movieSourcesProgress)
                        }
                        if !movieSourcesNotice.isEmpty {
                            Text(movieSourcesNotice).font(.footnote).foregroundStyle(.secondary)
                        }
                        if !movieSources.isEmpty {
                            Text("AVAILABLE STREAMS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                            ForEach(movieSources, id: \.scopedID) { source in
                                Button {
                                    selectedMovieSource = source
                                    resumeSeconds = model.preferences.progress[source.scopedID]?.seconds ?? 0
                                    playing = true
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.preferences.itemTitle(source)).font(.headline).lineLimit(1)
                                        Text(movieSourceLabel(source)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 18).padding(.vertical, 12)
                                    .background(StreamTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("movie-source-\(source.scopedID)")
                            }
                        }
#endif
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(tvOS)
                // Include the poster and metadata in the focus region so Down
                // from Back can reach the otherwise diagonal play controls.
                .focusSection()
                #endif
                #if os(iOS)
                MobileSaveButton(record: MobileRecords.record(item)).buttonStyle(.bordered)
                #endif
                Text("Overview").font(.title2.bold())
                if loading { ProgressView("Loading movie details…") }
                else { Text(info.overview.isEmpty ? "No overview supplied by your provider." : info.overview).font(.body) }
                if !metadataNotice.isEmpty { Text(metadataNotice).font(.footnote).foregroundStyle(.secondary) }
            }.padding(28).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }.background { StreamBackdrop() }
        #if os(tvOS)
        // Evaluate when the destination enters the focus hierarchy, rather than
        // making a one-shot request before the navigation transition completes.
        .defaultFocus($detailFocus, "play")
        #else
        .onAppear { detailFocus = "play" }
        #endif
        .task {
            defer { loading = false }
            do {
                let owner = model.provider(for: item)
                guard owner.kind == .xtream else { throw AppFailure("M3U playlists do not include a movie overview or release date.") }
                var parts = URLComponents(url: try owner.apiURL(action: "get_vod_info"), resolvingAgainstBaseURL: false)!
                parts.queryItems?.append(URLQueryItem(name: "vod_id", value: item.id))
                let data = try await BoundedTransfer(limit: 2 * 1024 * 1024).fetch(parts.url!)
                let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                try Task.checkCancellation(); info = MovieInformation.parse(row)
            } catch { if !Task.isCancelled { metadataNotice = error.localizedDescription } }
        }
        .fullScreenCover(isPresented: $playing) {
#if os(tvOS)
            let selected = selectedMovieSource ?? item
#else
            let selected = item
#endif
            DirectPlayerView(item: selected, provider: model.provider(for: selected), startSeconds: resumeSeconds)
        }
    }
#if os(tvOS)
    private func findMovieSources() async {
        guard !movieSourcesLoading else { return }
        movieSourcesLoading = true
        movieSourcesNotice = ""
        movieSourcesProgress = ""
        defer { if !Task.isCancelled { movieSourcesLoading = false; movieSourcesProgress = "" } }
        do {
            let categories = try await model.catalog.categories(kind: .movies, model: model)
            let enabled = model.preferences.browseCategories(categories, section: .movies)
            var matches: [CatalogItem] = [item]
            let target = normalizedMovieSourceTitle(item.name)
            let pending = enabled.filter { $0.id != item.categoryID }
            var completed = 0
            await withTaskGroup(of: (String, [CatalogItem]?).self) { group in
                var next = 0
                func enqueue(_ categoryID: String) {
                    group.addTask {
                        do { return (categoryID, try await model.catalog.items(kind: .movies, category: categoryID, model: model)) }
                        catch { return (categoryID, nil) }
                    }
                }
                for category in pending.prefix(4) { enqueue(category.id); next += 1 }
                while let (_, entries) = await group.next() {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    completed += 1
                    if let entries {
                        for candidate in entries where normalizedMovieSourceTitle(candidate.name) == target {
                            if !item.year.isEmpty, !candidate.year.isEmpty, item.year != candidate.year { continue }
                            if !matches.contains(where: { $0.scopedID == candidate.scopedID }) { matches.append(candidate) }
                        }
                        movieSources = matches
                    }
                    movieSourcesProgress = "Checked \(completed) of \(pending.count) categories…"
                    if next < pending.count { enqueue(pending[next].id); next += 1 }
                }
            }
            try Task.checkCancellation()
            movieSources = matches
            if matches.count == 1 { movieSourcesNotice = "No other matching streams were found in enabled categories." }
        } catch is CancellationError {
            return
        } catch {
            movieSourcesNotice = "Could not check other enabled categories. The selected stream is still available."
        }
    }

    private func movieSourceLabel(_ source: CatalogItem) -> String {
        let categories = model.catalog.knownCategories(kind: .movies)
        let categoryName = categories.first { $0.id == source.categoryID }?.name ?? "Category"
        let providerName = source.providerID.flatMap { id in model.vault.profiles.first { $0.id == id }?.provider.name }
            ?? model.provider.name
        return [source.year, categoryName, providerName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func normalizedMovieSourceTitle(_ raw: String) -> String {
        let cleaned = NameCleaner.clean(raw)
            .replacingOccurrences(of: #"\b(?:19|20)\d{2}\b"#, with: "", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return cleaned.filter { $0.isLetter || $0.isNumber }
    }
#endif
    private var posterWidth: CGFloat {
        #if os(tvOS)
        return 300
        #else
        return 130
        #endif
    }
    private func restart() {
        model.preferences.progress[item.id] = nil; model.preferences.write(key: model.preferenceKey)
        resumeSeconds = 0; playing = true
    }
}

struct CatalogDestination: View {
    @EnvironmentObject private var model: AppModel
    let item: CatalogItem
    var channels: [CatalogItem] = []
    var body: some View {
        if item.kind == .movies { MovieDetailView(item: item) }
        else {
            DirectPlayerView(item: item, provider: model.provider(for: item), channels: channels.filter(model.preferences.visible))
        }
    }
}
