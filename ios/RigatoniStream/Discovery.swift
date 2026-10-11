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
            if let category { result = result.map { var item = $0; if item.categoryID.isEmpty { item.categoryID = category }; return item } }
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

#if os(iOS)
struct MovieCard: View {
    let item: CatalogItem
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderPoster(url: item.poster, kind: .movies)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: StreamTheme.corner))
            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading).padding(10)
        }.background(StreamTheme.panel(for: AppAppearance(rawValue: appearance) ?? .dark))
            .clipShape(RoundedRectangle(cornerRadius: StreamTheme.corner))
    }
}

struct MoviesHomeView: View {
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
                        ZStack(alignment: .bottomLeading) {
                            ProviderPoster(url: featured.poster, kind: .movies).frame(height: 260).clipped()
                            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.65), .black], startPoint: .top, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("IN THE SPOTLIGHT").font(.caption.weight(.bold)).tracking(3)
                                Text(featured.name).font(.title.weight(.bold)).lineLimit(2).shadow(color: .black, radius: 4, y: 2)
                                Button { playing = featured } label: { Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 24).padding(.vertical, 10) }
                                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                            }.padding(22).foregroundStyle(.white)
                        }.frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 24)).padding(.horizontal, 16)
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
            .navigationTitle("Movies").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("RS").font(.caption.weight(.black)).foregroundStyle(StreamTheme.accent) }
                ToolbarItem(placement: .topBarTrailing) { Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account settings") }
            }
            .task(id: "\(model.libraryRevision)-\(retry)") {
                featured = nil; categories = []; error = ""; categoryCount = 6
                featuredLoading = true
                defer { featuredLoading = false }
                guard model.signedIn, model.providerReady else { return }
                do {
                    let loaded = try await catalog.categories(kind: .movies, model: model)
                    try Task.checkCancellation()
                    categories = loaded.filter { model.preferences.categoryVisible($0.id, kind: .movies) }
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
    @State private var items: [CatalogItem] = []
    @State private var error = ""
    @State private var retry = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
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
    var id: String { "\(item.kind.rawValue):\(item.id)" }
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
                    if !hasQuery {
                        StreamHeading(title: "Find your next favorite", subtitle: "Search movies and live channels together. Enter at least two characters.").padding(.vertical, 20)
                        Label("Every category. One search.", systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: StreamTheme.corner))
                    }
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
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain)
                        }
                        if results.count > limit { Button("More results") { limit += 60 } }
                        if catalog.progress.isEmpty && results.isEmpty { Text("No matching titles in the loaded catalogs.").foregroundStyle(.secondary) }
                    }
                }.padding()
            }.background { StreamBackdrop() }
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
            .task(id: "\(query)-\(filter)-\(catalog.revision)-\(model.libraryRevision)") {
                limit = 60
                guard hasQuery else { results = []; return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let snapshot = LibraryKind.allCases.flatMap { catalog.searchable[$0] ?? [] }.filter(model.preferences.visible)
                let term = query; let choice = filter
                let worker = Task.detached(priority: .userInitiated) { UnifiedSearch.matches(snapshot, query: term, filter: choice) }
                let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; results = found
            }
            .fullScreenCover(item: $playing) { CatalogDestination(item: $0, channels: catalog.searchable[.live] ?? []) }
        }
    }
    private func load(_ kind: LibraryKind) async {
        do {
            let result = try await catalog.loadAll(kind: kind, model: model)
            if !Task.isCancelled && !result.notice.isEmpty { notices.append("\(kind.title): \(result.notice)") }
        } catch { if !Task.isCancelled { notices.append("\(kind.title): \(error.localizedDescription)") } }
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
    var hiddenChannels: Set<String> = []
    var progress: [String: MovieProgress] = [:]
    static func read(key: String?) -> Self {
        guard let key, let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func write(key: String?) {
        guard let key, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func categoryVisible(_ id: String, kind: LibraryKind) -> Bool {
        !(kind == .live ? hiddenLiveCategories : hiddenMovieCategories).contains(id)
    }
    func visible(_ item: CatalogItem) -> Bool {
        categoryVisible(item.categoryID, kind: item.kind) && (item.kind != .live || !hiddenChannels.contains(item.id))
    }
    mutating func setCategory(_ id: String, kind: LibraryKind, visible: Bool) {
        if kind == .live { if visible { hiddenLiveCategories.remove(id) } else { hiddenLiveCategories.insert(id) } }
        else { if visible { hiddenMovieCategories.remove(id) } else { hiddenMovieCategories.insert(id) } }
    }
}
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light, netflix
    var id: String { rawValue }
    var title: String { switch self { case .dark: return "iOS Dark"; case .light: return "iOS Light"; case .netflix: return "Netflix" } }
    var scheme: ColorScheme { self == .light ? .light : .dark }
    var accent: Color { self == .netflix ? .red : .blue }
}

struct LibraryCustomizationView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = AppAppearance.dark.rawValue
    @State private var categories: [CatalogCategory] = []
    @State private var channels: [CatalogItem] = []
    @State private var kind = LibraryKind.live
    @State private var selected = ""
    @State private var query = ""
    @State private var error = ""
    @State private var loading = false
    @State private var limit = 100
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Make it yours").font(.largeTitle.bold())
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Themes, hidden content and watch progress are saved on this device. Provider and gateway settings remain in your account.").font(.footnote).foregroundStyle(.secondary)
                Picker("Manage", selection: $kind) { ForEach(LibraryKind.allCases) { Text($0.title).tag($0) } }
                TextField("Find category or channel", text: $query)
                Text("Visible categories").font(.title2.bold())
                Text("Turn off categories you don’t watch. Hidden titles also disappear from search.").foregroundStyle(.secondary)
                Button("Show all categories & channels") {
                    model.preferences.hiddenLiveCategories = []; model.preferences.hiddenMovieCategories = []; model.preferences.hiddenChannels = []
                    model.savePreferences()
                }
                if kind == .live && !categories.isEmpty {
                    Button("Show only categories marked US / USA") {
                        for category in categories {
                            let isUS = category.name.range(of: #"^\s*\[?(US|USA)(\]|\s|\||:|-|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
                            model.preferences.setCategory(category.id, kind: .live, visible: isUS)
                        }
                        model.savePreferences()
                    }
                    Text("Uses the provider’s category names. Unmarked categories are hidden too; Show all restores them.").font(.footnote).foregroundStyle(.secondary)
                }
                if loading { ProgressView("Loading…") }
                if !error.isEmpty { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await load() } } }
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(categories.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { category in
                        Toggle(category.name, isOn: Binding(get: { model.preferences.categoryVisible(category.id, kind: kind) }, set: {
                            model.preferences.setCategory(category.id, kind: kind, visible: $0); model.savePreferences()
                        }))
                    }
                }
                if kind == .live && !categories.isEmpty {
                    Text("Visible channels").font(.title2.bold())
                    Picker("Channel category", selection: $selected) {
                        Text("Choose a category").tag("")
                        ForEach(categories) { Text($0.name).tag($0.id) }
                    }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(channels.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(limit))) { item in
                            Toggle(item.name, isOn: Binding(get: { !model.preferences.hiddenChannels.contains(item.id) }, set: {
                                if $0 { model.preferences.hiddenChannels.remove(item.id) } else { model.preferences.hiddenChannels.insert(item.id) }
                                model.savePreferences()
                            }))
                        }
                    }
                    if channels.count > limit { Button("More channels") { limit += 100 } }
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.background { StreamBackdrop() }.navigationTitle("Appearance & library")
        .task(id: "\(kind.rawValue)-\(model.provider.server)") { await load() }
        .task(id: selected) {
            channels = []; limit = 100; guard kind == .live, !selected.isEmpty else { return }
            do { channels = try await model.catalog.items(kind: .live, category: selected, model: model) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func load() async {
        categories = []; channels = []; selected = ""; error = ""; loading = true
        defer { loading = false }
        guard model.providerReady else { error = "Save a provider first."; return }
        do { categories = try await model.catalog.categories(kind: kind, model: model) }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                HStack(alignment: .top, spacing: 28) {
                    ProviderPoster(url: item.poster, kind: .movies).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(maxWidth: posterWidth).clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 18) {
                        Text(item.name).font(.largeTitle.bold())
                        if !info.release.isEmpty { Text("Released \(info.release)").foregroundStyle(.secondary) }
                        if !info.genre.isEmpty { Text(info.genre).foregroundStyle(.secondary) }
                        if let saved = model.preferences.progress[item.id] {
                            Button { resumeSeconds = saved.seconds; playing = true } label: { Label("Continue from \(saved.label)", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                            Button("Restart movie") { restart() }.buttonStyle(.bordered)
                        } else {
                            Button { resumeSeconds = 0; playing = true } label: { Label("Play movie", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Overview").font(.title2.bold())
                if loading { ProgressView("Loading movie details…") }
                else { Text(info.overview.isEmpty ? "No overview supplied by your provider." : info.overview).font(.body) }
                if !metadataNotice.isEmpty { Text(metadataNotice).font(.footnote).foregroundStyle(.secondary) }
            }.padding(28).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }.background { StreamBackdrop() }
        .task {
            defer { loading = false }
            do {
                guard !model.provider.requiresGateway else { throw AppFailure("Movie details require direct provider access in this build. Playback is still available through the gateway.") }
                var parts = URLComponents(url: try model.provider.apiURL(action: "get_vod_info"), resolvingAgainstBaseURL: false)!
                parts.queryItems?.append(URLQueryItem(name: "vod_id", value: item.id))
                let data = try await BoundedTransfer(limit: 2 * 1024 * 1024).fetch(parts.url!)
                let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                try Task.checkCancellation(); info = MovieInformation.parse(row)
            } catch { if !Task.isCancelled { metadataNotice = error.localizedDescription } }
        }
        .fullScreenCover(isPresented: $playing) {
            #if os(iOS)
            PlayerView(item: item, provider: model.provider, startSeconds: resumeSeconds)
            #else
            TVPlayerView(item: item, provider: model.provider, startSeconds: resumeSeconds)
            #endif
        }
    }
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
            #if os(iOS)
            PlayerView(item: item, provider: model.provider, channels: channels.filter(model.preferences.visible))
            #else
            TVPlayerView(item: item, provider: model.provider, channels: channels.filter(model.preferences.visible))
            #endif
        }
    }
}
