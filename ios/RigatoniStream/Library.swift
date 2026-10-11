import Foundation
import ImageIO
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
            guard let data = try? await BoundedTransfer(limit: 2 * 1024 * 1024).fetch(url), !Task.isCancelled else { return }
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

// Shared native visual language; playback and credential handling stay separate.
enum StreamTheme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let accent = Color(red: 0.9, green: 0.035, blue: 0.08)
    static let corner: CGFloat = 18
}

struct StreamBackdrop: View {
    var body: some View {
        LinearGradient(colors: [StreamTheme.panel, StreamTheme.background],
                       startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
    }
}

struct StreamHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RIGATONI STREAM").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.secondary)
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
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
    private var orderedCategories: [CatalogCategory] { kind == .live ? CategoryPins.ordered(categories, pins: pinnedIDs) : categories }
    private var pinKey: String? {
        guard let accountID = model.account.session?.user.id, let host = try? model.provider.baseURL().host else { return nil }
        return CategoryPins.key(accountID: accountID, host: host)
    }
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
                        Button("Provider settings") { model.settingsVisible = true }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    } else {
                        if !categories.isEmpty && scope == .category {
                            HStack {
                                Picker("Category", selection: $selected) {
                                    ForEach(orderedCategories) { category in
                                        Text((pinnedIDs.contains(category.id) && kind == .live ? "★ " : "") + category.name).tag(category.id)
                                    }
                                }.pickerStyle(.menu).tint(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
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
                                        }.buttonStyle(.bordered).tint(.white)
                                    }
                                }
                            }
                        }
                        if loading { ProgressView(progress.isEmpty ? "Loading \(kind.title.lowercased())…" : progress).frame(maxWidth: .infinity) }
                        if !error.isEmpty {
                            Text(error).foregroundStyle(.secondary)
                            Button("Retry") { model.resetGateway(); retry += 1 }.buttonStyle(.bordered)
                        } else if !loading && filtered.isEmpty { Text(query.isEmpty ? "No titles available." : "No matching titles.").foregroundStyle(.secondary) }
                        if kind == .live {
                            LazyVStack(spacing: 10) {
                                ForEach(visible) { item in
                                    Button { playing = item } label: {
                                        HStack(spacing: 16) {
                                            ProviderPoster(url: item.poster, kind: .live)
                                                .frame(width: 86, height: 56)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                            Text(item.name).font(.headline).lineLimit(2)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.secondary)
                                        }.padding(12).foregroundStyle(.white)
                                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: StreamTheme.corner))
                                    }.buttonStyle(.plain)
                                }
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 22) {
                                ForEach(visible) { item in
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
            .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account and provider settings") }
            .task(id: "\(model.libraryRevision)-\(retry)") { await loadCategories() }
            .task(id: "\(scope.rawValue)-\(selected)-\(model.libraryRevision)-\(retry)") { await loadItems() }
            .task(id: "\(query)-\(searchRevision)") { await filterItems() }
            .fullScreenCover(item: $playing) { PlayerView(item: $0, provider: model.provider, channels: kind == .live ? items : []) }
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
            selected = categories.first { $0.id == initialCategoryID }?.id ?? orderedCategories.first?.id ?? ""
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
        try await model.catalog.items(kind: kind, category: category, model: model)
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

#endif
