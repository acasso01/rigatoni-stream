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
    private var finalURL: URL?
    var resolvedURL: URL? { lock.lock(); defer { lock.unlock() }; return finalURL }
    init(limit: Int, timeout: TimeInterval = 30) { self.limit = limit; self.timeout = timeout }
    func fetch(_ url: URL, headers: [String: String] = [:], method: String = "GET") async throws -> Data {
        guard TransportPolicy.permits(url) else { throw AppFailure("This URL is unsupported or this app build is missing its HTTP transport setting.") }
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
                headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }; request.setValue("*/*", forHTTPHeaderField: "Accept")
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
            completionHandler(nil); finish(.failure(AppFailure("The provider redirected to an unsupported URL."))); return
        }
        var next = request
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
            let message = [401,403].contains(response.statusCode) ? "Provider access was denied. Check your credentials or subscription." :
                response.statusCode == 429 ? "The provider is rate limiting requests. Wait before retrying." : "Provider request failed (HTTP \(response.statusCode))."
            completionHandler(.cancel); finish(.failure(AppFailure(message))); return
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
    static var appearance: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: "rigatoni-appearance") ?? "dark") ?? .dark }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
    static func background(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(242, 242, 247)
        case .dark: return rgb(9, 9, 11)
        case .ghost: return rgb(10, 10, 11)
        case .nebula: return rgb(6, 6, 9)
        }
    }
    static func panel(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(255, 255, 255)
        case .dark: return rgb(23, 23, 27)
        case .ghost: return rgb(20, 20, 22)
        case .nebula: return rgb(14, 14, 20)
        }
    }
    static func card(for appearance: AppAppearance) -> Color { panel(for: appearance) }
    static func text(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(28, 28, 30)
        case .dark: return rgb(250, 250, 250)
        case .ghost: return .white
        case .nebula: return rgb(237, 235, 245)
        }
    }
    static func muted(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .light: return rgb(107, 114, 128)
        case .dark: return rgb(161, 161, 170)
        case .ghost: return rgb(161, 161, 170)
        case .nebula: return rgb(143, 141, 163)
        }
    }
    static func accent(for appearance: AppAppearance) -> Color {
        switch appearance {
        case .ghost: return .white
        case .nebula: return rgb(167, 139, 250)
        default: return rgb(229, 9, 20)
        }
    }
    static func accentFill(for appearance: AppAppearance) -> LinearGradient {
        let colors = appearance == .nebula
            ? [rgb(167, 139, 250), rgb(34, 211, 238)]
            : [accent(for: appearance), accent(for: appearance)]
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
        LinearGradient(colors: [StreamTheme.panel(for: AppAppearance(rawValue: appearance) ?? .dark), StreamTheme.background(for: AppAppearance(rawValue: appearance) ?? .dark)],
                       startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
    }
}

struct StreamHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANT STREAMS").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.secondary)
            Text(title).font(.largeTitle.weight(.bold))
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
    let item: CatalogItem
    let provider: Provider
    let epgEnabled: Bool
    let scope: String
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
                    Text(item.name).font(.headline).lineLimit(1)
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
            .task(id: scope + ":" + item.id) {
                guide = nil
                guard epgEnabled else { return }
                while !Task.isCancelled {
                    let value = await EPGCache.shared.nowNext(streamID: item.id, provider: provider, scope: scope)
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
    private var orderedCategories: [CatalogCategory] {
        let shown = categories.filter { model.preferences.categoryVisible($0.id, kind: kind) }
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
                        if kind == .movies {
                            StreamOptionPicker(options: [(CatalogSearchScope.all, "All titles"), (.category, "Categories")], selection: $scope)
                        }
                        if kind == .movies && scope == .category {
                            ScrollView(.horizontal, showsIndicators: true) {
                                LazyHStack(spacing: 10) {
                                    ForEach(orderedCategories) { category in
                                        Button { selected = category.id } label: {
                                            Text(category.name).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                                                .padding(.horizontal, 16).padding(.vertical, 12)
                                                .foregroundStyle(StreamTheme.text)
                                                .background(selected == category.id ? StreamTheme.accent.opacity(0.18) : StreamTheme.panel, in: Capsule())
                                                .overlay(Capsule().stroke(selected == category.id ? StreamTheme.accent : .clear, lineWidth: 2))
                                        }.buttonStyle(.plain).accessibilityAddTraits(selected == category.id ? .isSelected : [])
                                    }
                                }.padding(.horizontal, 2).padding(.vertical, 4)
                            }.frame(height: 62).scrollClipDisabled()
                        }
                        if kind == .live && !categories.isEmpty && scope == .category {
                            HStack {
                                Picker("Category", selection: $selected) {
                                    ForEach(orderedCategories) { category in
                                        Text((pinnedIDs.contains(category.id) && kind == .live ? "★ " : "") + category.name).tag(category.id)
                                    }
                                }.pickerStyle(.menu)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                                if kind == .live {
                                    Button {
                                        pinnedIDs = PinnedCategories.toggled(selected, in: pinnedIDs)
                                        PinnedCategories.write(pinnedIDs, key: pinKey)
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
                                        }.buttonStyle(.bordered)
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
                                        LiveChannelRow(item: item, provider: model.provider(for: item), epgEnabled: true, scope: model.epgScope(for: item))
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
        items = value.filter(model.preferences.visible); searchRevision += 1; page = 0
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
