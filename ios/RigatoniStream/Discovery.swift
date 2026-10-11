import SwiftUI

// Account-scoped, memory-only catalogs shared by browsing and global search.
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

    func reset() {
        generation += 1
        PosterMemory.shared.removeAllObjects()
        jobs.values.forEach { $0.cancel() }; fullJobs.values.forEach { $0.cancel() }
        jobs = [:]; fullJobs = [:]; batches = [:]; batchOrder = []
        completed = [:]; categoryLists = [:]; searchable = [:]; progress = [:]; revision += 1
    }
    func categories(kind: LibraryKind, model: AppModel) async throws -> [CatalogCategory] {
        if let cached = categoryLists[kind] { return cached }
        let epoch = generation
        let rows: [[String: Any]]
        if model.provider.requiresGateway { rows = try await model.gatewayRows(kind: kind, category: nil) }
        else {
            let url = try model.provider.apiURL(action: kind.categoryAction)
            let data = try await BoundedTransfer(limit: 4 * 1024 * 1024).fetch(url)
            guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], result.count <= 50000 else { throw AppFailure("The category list is too large or invalid.") }
            rows = result
        }
        guard epoch == generation else { throw CancellationError() }
        var seen = Set<String>()
        let result = rows.compactMap { row -> CatalogCategory? in
            let id = row["category_id"].map { String(describing: $0) } ?? ""
            guard !id.isEmpty, id.allSatisfy(\.isNumber), seen.insert(id).inserted else { return nil }
            return CatalogCategory(id: id, name: row["category_name"] as? String ?? "Category")
        }
        categoryLists[kind] = result
        return result
    }
    func items(kind: LibraryKind, category: String?, model: AppModel) async throws -> [CatalogItem] {
        let key = "\(kind.rawValue):\(category ?? "all")"
        if let cached = batches[key] { return cached }
        if category == nil, let cached = completed[kind] { return cached.items }
        if let job = jobs[key] { return try await job.value }
        let epoch = generation
        let task = Task { @MainActor in
            let rows: [[String: Any]]
            if model.provider.requiresGateway {
                guard let category else { throw AppFailure("Load gateway categories individually.") }
                rows = try await model.gatewayRows(kind: kind, category: category)
            } else {
                let url = try model.provider.apiURL(action: kind.streamAction, category: category)
                let data = try await BoundedTransfer(limit: 32 * 1024 * 1024, timeout: category == nil ? 10 : 30).fetch(url)
                let worker = Task.detached(priority: .userInitiated) {
                    guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], result.count <= CatalogIndex.maximumItems else { throw AppFailure("The catalog is too large or invalid.") }
                    return result
                }
                rows = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            }
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) { rows.compactMap { CatalogItem.parse($0, kind: kind) } }
            var result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            if model.provider.requiresGateway {
                result = result.map { item in
                    var item = item
                    item.playbackURL = try? model.gatewayPlaybackURL(id: item.id, kind: kind)
                    return item
                }
            }
            return result
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
            }
            return result
        } catch { if epoch == generation { jobs[key] = nil }; throw error }
    }
    func loadAll(kind: LibraryKind, model: AppModel) async throws -> CatalogLoadResult {
        if let cached = completed[kind] { return cached }
        if let job = fullJobs[kind] { return try await job.value }
        let epoch = generation
        let task = Task { @MainActor in
            let categories = try await self.categories(kind: kind, model: model)
            return try await CatalogLoader.load(categoryIDs: categories.map(\.id), preferFullCatalog: !model.provider.requiresGateway, fetch: { category in
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
            if result.notice.isEmpty { completed[kind] = result }
            return result
        } catch { if epoch == generation { fullJobs[kind] = nil; progress[kind] = nil }; throw error }
    }
}

struct MovieCard: View {
    let item: CatalogItem
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProviderPoster(url: item.poster, kind: .movies)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.name).font(.caption.weight(.semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(.white)
    }
}

struct MoviesHomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var categories: [CatalogCategory] = []
    @State private var featured: CatalogItem?
    @State private var playing: CatalogItem?
    @State private var error = ""
    @State private var categoryCount = 6
    @State private var retry = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let featured {
                        ZStack(alignment: .bottomLeading) {
                            ProviderPoster(url: featured.poster, kind: .movies).frame(height: 470).clipped()
                            LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("FEATURED MOVIE").font(.caption.weight(.bold)).tracking(3)
                                Text(featured.name).font(.largeTitle.weight(.heavy)).lineLimit(3)
                                Button { playing = featured } label: { Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 24).padding(.vertical, 10) }
                                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                            }.padding(22)
                        }.frame(height: 470)
                    } else if error.isEmpty && model.providerReady {
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
            .background(Color.black)
            .navigationTitle("Movies").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("RIGATONI").font(.caption.weight(.black)).foregroundStyle(.red) }
                ToolbarItem(placement: .topBarTrailing) { Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account settings") }
            }
            .task(id: "\(model.libraryRevision)-\(retry)") {
                featured = nil; categories = []; error = ""; categoryCount = 6
                guard model.signedIn, model.providerReady else { return }
                do {
                    let loaded = try await catalog.categories(kind: .movies, model: model)
                    try Task.checkCancellation()
                    categories = loaded
                    if let first = loaded.first {
                        let items = try await catalog.items(kind: .movies, category: first.id, model: model)
                        try Task.checkCancellation()
                        featured = items.first { $0.poster != nil } ?? items.first
                    }
                    if loaded.isEmpty { error = "No movie categories are available." }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .fullScreenCover(item: $playing) { PlayerView(item: $0, provider: model.provider) }
        }
    }
}

struct MovieShelf: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    let category: CatalogCategory
    let play: (CatalogItem) -> Void
    @State private var items: [CatalogItem] = []
    @State private var error = ""
    @State private var retry = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category.name).font(.title3.bold()).lineLimit(1)
                Spacer()
                NavigationLink("See all") { LibraryView(kind: .movies, initialCategoryID: category.id) }.font(.subheadline.weight(.semibold))
            }.padding(.horizontal)
            if !error.isEmpty {
                HStack { Text(error).font(.caption); Button("Retry") { retry += 1 } }.padding(.horizontal)
            } else if items.isEmpty { ProgressView().padding(.horizontal) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.prefix(20))) { item in
                        Button { play(item) } label: { MovieCard(item: item).frame(width: 140) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
        }
        .task(id: "\(category.id)-\(model.libraryRevision)-\(retry)") {
            do {
                error = ""
                let loaded = try await catalog.items(kind: .movies, category: category.id, model: model)
                try Task.checkCancellation(); items = Array(loaded.prefix(20))
                if loaded.isEmpty { error = "No movies in this category." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct SearchHit: Identifiable {
    let item: CatalogItem
    var id: String { "\(item.kind.rawValue):\(item.id)" }
}

enum UnifiedSearch {
    static func matches(_ items: [CatalogItem], query: String, filter: String) -> [SearchHit] {
        CatalogIndex.matches(items, query: query).filter { filter == "all" || $0.kind.rawValue == filter }.map { SearchHit(item: $0) }
    }
}

struct GlobalSearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var query = ""
    @State private var filter = "all"
    @State private var results: [SearchHit] = []
    @State private var notices: [String] = []
    @State private var playing: CatalogItem?
    @State private var limit = 60
    @State private var retry = 0
    private var hasQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Picker("Search in", selection: $filter) {
                        Text("All").tag("all"); Text("Movies").tag(LibraryKind.movies.rawValue); Text("Live TV").tag(LibraryKind.live.rawValue)
                    }.pickerStyle(.segmented)
                    if !hasQuery { Text("Find movies and channels across every category. Enter at least two characters.").foregroundStyle(.secondary) }
                    if hasQuery {
                        ForEach(LibraryKind.allCases) { kind in
                            if let progress = catalog.progress[kind] { ProgressView("\(kind.title): \(progress)").font(.caption) }
                        }
                        ForEach(notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        if !notices.isEmpty { Button("Retry unavailable catalogs") { retry += 1 } }
                        ForEach(Array(results.prefix(limit))) { hit in
                            Button { playing = hit.item } label: {
                                HStack(spacing: 14) {
                                    ProviderPoster(url: hit.item.poster, kind: hit.item.kind).frame(width: 64, height: 90).clipShape(RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(hit.item.name).font(.headline).lineLimit(2)
                                        Label(hit.item.kind.title, systemImage: hit.item.kind.symbol).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "play.circle").font(.title2)
                                }.foregroundStyle(.white)
                            }.buttonStyle(.plain)
                        }
                        if results.count > limit { Button("More results") { limit += 60 } }
                        if catalog.progress.isEmpty && results.isEmpty { Text("No matching titles in the loaded catalogs.").foregroundStyle(.secondary) }
                    }
                }.padding()
            }.background(Color.black)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies and Live TV")
            .task(id: "\(hasQuery)-\(model.libraryRevision)-\(retry)") {
                guard hasQuery, model.signedIn, model.providerReady else { return }
                notices = []
                // Two media types at most, never one network request per keystroke.
                async let movies: Void = load(.movies)
                async let live: Void = load(.live)
                _ = await (movies, live)
            }
            .task(id: "\(query)-\(filter)-\(catalog.revision)") {
                limit = 60
                guard hasQuery else { results = []; return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let snapshot = LibraryKind.allCases.flatMap { catalog.searchable[$0] ?? [] }
                let term = query; let choice = filter
                let worker = Task.detached(priority: .userInitiated) { UnifiedSearch.matches(snapshot, query: term, filter: choice) }
                let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; results = found
            }
            .fullScreenCover(item: $playing) { PlayerView(item: $0, provider: model.provider, channels: catalog.searchable[.live] ?? []) }
        }
    }
    private func load(_ kind: LibraryKind) async {
        do {
            let result = try await catalog.loadAll(kind: kind, model: model)
            if !Task.isCancelled && !result.notice.isEmpty { notices.append("\(kind.title): \(result.notice)") }
        } catch { if !Task.isCancelled { notices.append("\(kind.title): \(error.localizedDescription)") } }
    }
}
