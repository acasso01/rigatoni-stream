import Foundation
import SwiftUI
import CryptoKit

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
    init(limit: Int, timeout: TimeInterval = 30) { self.limit = limit; self.timeout = timeout }
    func fetch(_ url: URL, headers: [String: String] = [:], method: String = "GET") async throws -> Data {
        guard TransportPolicy.permits(url) else { throw AppFailure("This HTTP host is not enabled in your app build. Configure your provider hostname on your Mac or use the HTTPS gateway.") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { next in
                lock.lock()
                if finished { lock.unlock(); next.resume(throwing: CancellationError()); return }
                continuation = next
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.httpCookieStorage = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout * 2
                let connection = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                session = connection
                var request = URLRequest(url: url); request.httpMethod = method
                headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }; request.setValue("application/json,image/*", forHTTPHeaderField: "Accept")
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
            completionHandler(nil); finish(.failure(AppFailure("The provider redirected to an HTTP host that is not enabled. Use the HTTPS gateway for this provider."))); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(AppFailure("Provider response failed or is too large. Try another category."))); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if buffer.count + data.count > limit { lock.unlock(); finish(.failure(AppFailure("This provider category is too large. Try a smaller category."))); return }
        buffer.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(AppFailure("Provider unreachable. Check your settings or try again."))) }
        else { lock.lock(); let data = buffer; lock.unlock(); finish(.success(data)) }
    }
}

struct ProviderPoster: View {
    let url: URL?
    let kind: LibraryKind
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: kind.symbol).font(.largeTitle).foregroundStyle(.gray) }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            if let data = try? await BoundedTransfer(limit: 2 * 1024 * 1024).fetch(url), !Task.isCancelled { image = UIImage(data: data) }
        }
    }
}

enum CatalogSearchScope: String, CaseIterable {
    case category = "This category", all = "All categories"
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

// One bounded full-catalog request is the fast path. Category fallback remains cancellable
// and publishes results as each category arrives, without creating more concurrent requests.
@MainActor
enum CatalogLoader {
    static func load(categoryIDs: [String], preferFullCatalog: Bool,
                     fetch: (String?) async throws -> [CatalogItem],
                     progress: ([CatalogItem], String) -> Void) async throws -> CatalogLoadResult {
        try Task.checkCancellation()
        if preferFullCatalog {
            progress([], "Loading full catalog…")
            do {
                let batch = try await fetch(nil)
                try Task.checkCancellation()
                guard !batch.isEmpty || categoryIDs.isEmpty else { throw AppFailure("Full catalog unavailable.") }
                var index = CatalogIndex()
                try index.append(batch)
                return CatalogLoadResult(items: index.items, notice: "")
            } catch {
                try Task.checkCancellation()
                // Some providers reject the unfiltered API or exceed the memory bounds.
            }
        }
        var index = CatalogIndex()
        var failed = 0
        for (offset, category) in categoryIDs.enumerated() {
            try Task.checkCancellation()
            do {
                let batch = try await fetch(category)
                try Task.checkCancellation()
                do { try index.append(batch) }
                catch { return CatalogLoadResult(items: index.items, notice: error.localizedDescription) }
            } catch {
                try Task.checkCancellation()
                failed += 1
            }
            progress(index.items, "Loading category \(offset + 1) of \(categoryIDs.count)…")
        }
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

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    let kind: LibraryKind
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
    private var orderedCategories: [CatalogCategory] { kind == .live ? CategoryPins.ordered(categories, pins: pinnedIDs) : categories }
    private var pinKey: String? {
        guard let accountID = model.account.session?.user.id, let host = try? model.provider.baseURL().host else { return nil }
        return CategoryPins.key(accountID: accountID, host: host)
    }
    private var visible: [CatalogItem] { Array(filtered.dropFirst(page * 120).prefix(120)) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(kind == .movies ? "Movie night, made yours." : "Live TV, made yours.")
                        .font(.largeTitle.bold()).padding(.top, 10)
                    Text(kind == .movies ? "Your provider’s movies. Original quality, native playback." : "Your channels. Your sports. Straight from your provider.").foregroundStyle(.secondary)
                    if !model.providerReady {
                        Text("Add or restore your provider settings to browse.")
                        Button("Provider settings") { model.settingsVisible = true }.buttonStyle(.borderedProminent)
                    } else {
                        if !categories.isEmpty && scope == .category {
                            HStack {
                                Picker("Category", selection: $selected) {
                                    ForEach(orderedCategories) { category in
                                        Text((pinnedIDs.contains(category.id) && kind == .live ? "★ " : "") + category.name).tag(category.id)
                                    }
                                }.pickerStyle(.menu).tint(.white)
                                if kind == .live {
                                    Button {
                                        pinnedIDs = CategoryPins.toggled(selected, in: pinnedIDs)
                                        if let pinKey { UserDefaults.standard.set(pinnedIDs, forKey: pinKey) }
                                    } label: { Image(systemName: pinnedIDs.contains(selected) ? "pin.fill" : "pin").frame(width: 44, height: 44) }
                                    .accessibilityLabel(pinnedIDs.contains(selected) ? "Unpin category" : "Pin category")
                                    .disabled(selected.isEmpty)
                                }
                            }
                        }
                        if kind == .live && !pinnedIDs.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(orderedCategories.filter { pinnedIDs.contains($0.id) }) { category in
                                        Button { scope = .category; selected = category.id } label: {
                                            Label(category.name, systemImage: "pin.fill")
                                        }.buttonStyle(.bordered).tint(selected == category.id ? .red : .white)
                                    }
                                }
                            }
                        }
                        Picker("Search scope", selection: $scope) {
                            ForEach(CatalogSearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        TextField(kind == .movies ? "Search movies" : "Search channels", text: $query)
                            .textFieldStyle(.roundedBorder).onChange(of: query) { _, _ in page = 0 }
                        if loading { ProgressView(progress.isEmpty ? "Loading \(kind.title.lowercased())…" : progress).frame(maxWidth: .infinity) }
                        if !error.isEmpty {
                            Text(error).foregroundStyle(.secondary)
                            Button("Retry") { model.resetGateway(); retry += 1 }.buttonStyle(.bordered)
                        } else if !loading && filtered.isEmpty { Text(query.isEmpty ? "No titles available." : "No matching titles.").foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 16) {
                            ForEach(visible) { item in
                                Button { playing = item } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ProviderPoster(url: item.poster, kind: kind).frame(height: kind == .movies ? 190 : 100).clipShape(RoundedRectangle(cornerRadius: 10))
                                        Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    }.foregroundStyle(.white)
                                }.buttonStyle(.plain)
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
            .background(Color(red: 0.035, green: 0.035, blue: 0.045))
            .navigationTitle("🍝 Rigatoni Stream").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account and provider settings") }
            .task(id: "\(model.libraryRevision)-\(retry)") { await loadCategories() }
            .task(id: "\(scope.rawValue)-\(selected)-\(model.libraryRevision)-\(retry)") { await loadItems() }
            .task(id: "\(query)-\(searchRevision)") { await filterItems() }
            .fullScreenCover(item: $playing) { PlayerView(item: $0, provider: model.provider, channels: kind == .live ? items : []) }
        }
    }
    private func rows(action: String, category: String? = nil) async throws -> [[String: Any]] {
        if model.provider.requiresGateway { return try await model.gatewayRows(kind: kind, category: category) }
        let url = try model.provider.apiURL(action: action, category: category)
        let data = try await BoundedTransfer(limit: 32 * 1024 * 1024).fetch(url)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 50000 else { throw AppFailure("The provider returned an invalid or oversized category.") }
        return rows
    }
    private func loadCategories() async {
        categories = []; selected = ""; replaceItems([]); error = ""; query = ""; page = 0; progress = ""; categoryCache = [:]; allCache = nil
        pinnedIDs = pinKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []
        guard model.signedIn, model.providerReady else { return }
        loading = true
        do {
            let result = try await rows(action: kind.categoryAction)
            guard !Task.isCancelled else { return }
            categories = result.compactMap { row in
                let id = row["category_id"].map { String(describing: $0) } ?? ""
                guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
                return CatalogCategory(id: id, name: row["category_name"] as? String ?? "Category")
            }
            selected = orderedCategories.first?.id ?? ""
            if selected.isEmpty { loading = false }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
    }
    private func replaceItems(_ value: [CatalogItem]) {
        items = value; searchRevision += 1; page = 0
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { filtered = value }
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
        if !model.provider.requiresGateway, let category, let cached = categoryCache[category] { return cached }
        let raw: [[String: Any]]
        if model.provider.requiresGateway {
            raw = try await model.gatewayRows(kind: kind, category: category)
        } else {
            let url = try model.provider.apiURL(action: kind.streamAction, category: category)
            let data = try await BoundedTransfer(limit: 32 * 1024 * 1024, timeout: category == nil ? 10 : 30).fetch(url)
            let worker = Task.detached(priority: .userInitiated) {
                guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], result.count <= CatalogIndex.maximumItems else {
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
            // Category and full-catalog arrays share item values; retain only the full result
            // after a successful global load to keep memory bounded.
            categoryCache = [category: result]
        }
        return result
    }
    private func loadItems() async {
        guard !selected.isEmpty, !categories.isEmpty, model.signedIn, model.providerReady else { return }
        error = ""; progress = ""; page = 0
        if scope == .all, let cached = allCache, !model.provider.requiresGateway {
            replaceItems(cached.items); error = cached.notice; loading = false; return
        }
        replaceItems([]); loading = true
        do {
            if scope == .all {
                let result = try await CatalogLoader.load(categoryIDs: categories.map(\.id), preferFullCatalog: !model.provider.requiresGateway, fetch: { category in
                    try await fetchItems(category: category)
                }, progress: { partial, message in
                    guard !Task.isCancelled else { return }
                    replaceItems(partial); progress = message
                })
                try Task.checkCancellation()
                replaceItems(result.items); error = result.notice
                if !model.provider.requiresGateway { allCache = result; categoryCache = [:] }
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
