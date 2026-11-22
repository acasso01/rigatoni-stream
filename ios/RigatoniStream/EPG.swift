import Foundation
import SwiftUI

struct EPGProgram: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let details: String
    var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

struct EPGNowNext: Equatable {
    let now: EPGProgram?
    let next: EPGProgram?
}

enum EPGParser {
    static func text(_ value: Any?) -> String {
        guard let raw = value as? String else { return "" }
        if let data = Data(base64Encoded: raw), let decoded = String(data: data, encoding: .utf8),
           !decoded.isEmpty, !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }) {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func programs(_ root: [String: Any]) -> [EPGProgram] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func date(_ row: [String: Any], keys: [String], fallback: String) -> Date? {
            for key in keys {
                if let value = row[key], let stamp = Double(String(describing: value)), stamp.isFinite, stamp > 0, stamp < 6_000_000_000 {
                    return Date(timeIntervalSince1970: stamp)
                }
            }
            return (row[fallback] as? String).flatMap(formatter.date(from:))
        }
        var seen = Set<String>()
        return (root["epg_listings"] as? [[String: Any]] ?? []).prefix(32).compactMap { row in
            let title = String(text(row["title"]).prefix(512))
            guard !title.isEmpty,
                  let start = date(row, keys: ["start_timestamp"], fallback: "start"),
                  let end = date(row, keys: ["stop_timestamp", "end_timestamp"], fallback: "end"), end > start else { return nil }
            let id = (row["id"].map { String(describing: $0) } ?? "program") + "-\(Int(start.timeIntervalSince1970))"
            guard seen.insert(id).inserted else { return nil }
            return EPGProgram(id: id, title: title, start: start, end: end, details: String(text(row["description"]).prefix(4000)))
        }.sorted { $0.start < $1.start }
    }
    static func nowNext(_ programs: [EPGProgram], at now: Date = Date()) -> EPGNowNext {
        let current = programs.first { $0.start <= now && now < $0.end }
        let next = programs.first { $0.id != current?.id && $0.start >= (current?.end ?? now) }
        return EPGNowNext(now: current, next: next)
    }
}

// Program responses stay in memory. Refresh timestamps are device-local and
// keyed by the app's provider scope; neither stores credentials.
// Four requests at once; bounded entries and queued work prevent a guide from flooding a provider.
enum EPGRefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0, fourHours = 4, sixHours = 6, twelveHours = 12, twentyFourHours = 24
    var id: Int { rawValue }
    var title: String { rawValue == 0 ? "Off" : "Every \(rawValue) hours" }
}

@MainActor final class EPGCache: ObservableObject {
    static let shared = EPGCache()
    typealias Loader = (String, Provider) async throws -> [EPGProgram]
    private struct Entry { let programs: [EPGProgram]; let fetched: Date }
    private struct Flight { let token: UUID; let task: Task<[EPGProgram], Never> }
    private struct KnownChannel { let id: String; let categoryID: String; let provider: Provider; let scope: String }
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var active = 0
    private var generation = 0
    private let limit: Int
    private let concurrency: Int
    private let loader: Loader
    @Published private(set) var revision = 0
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var refreshError = ""
    private var failures: Set<String> = []
    private var known: [String: KnownChannel] = [:]
    var cachedCount: Int { entries.count }

    init(limit: Int = 128, concurrency: Int = 4, loader: Loader? = nil) {
        self.limit = max(1, limit); self.concurrency = max(1, concurrency)
        self.loader = loader ?? Self.fetch
    }
    func reset() {
        generation += 1; entries.removeAll(); known.removeAll(); failures.removeAll(); lastRefresh = nil; refreshError = ""; revision += 1
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }
    private func acquire() async {
        if active < concurrency { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }
    }
    func programs(streamID: String, provider: Provider, scope: String, categoryID: String = "", forceRefresh: Bool = false) async -> [EPGProgram] {
        guard !scope.isEmpty, streamID.allSatisfy(\.isNumber), !streamID.isEmpty else { return [] }
        let key = scope + ":" + streamID
        if known[key] != nil || known.count < limit {
            known[key] = KnownChannel(id: streamID, categoryID: categoryID, provider: provider, scope: scope)
        }
        if !forceRefresh, let entry = entries[key], Date().timeIntervalSince(entry.fetched) < 300 { return entry.programs }
        if forceRefresh { flights[key]?.task.cancel(); flights[key] = nil }
        if let flight = flights[key] { return await flight.task.value }
        guard flights.count < 64 else { return [] }
        let epoch = generation; let token = UUID()
        let job = Task<[EPGProgram], Never> {
            await acquire()
            defer { release() }
            guard !Task.isCancelled else { return [] }
            do {
                let value = try await loader(streamID, provider)
                if generation == epoch, flights[key]?.token == token { failures.remove(key) }
                return value
            } catch {
                if generation == epoch, flights[key]?.token == token { failures.insert(key) }
                return []
            }
        }
        flights[key] = Flight(token: token, task: job)
        let value = await job.value
        guard generation == epoch, !job.isCancelled, flights[key]?.token == token else { return [] }
        if flights[key]?.token == token { flights[key] = nil }
        guard !failures.contains(key) else { return entries[key]?.programs ?? [] }
        entries[key] = Entry(programs: Array(value.prefix(32)), fetched: Date())
        if entries.count > limit, let oldest = entries.min(by: { $0.value.fetched < $1.value.fetched })?.key { entries[oldest] = nil }
        return value
    }
    func nowNext(streamID: String, provider: Provider, scope: String, categoryID: String = "") async -> EPGNowNext {
        EPGParser.nowNext(await programs(streamID: streamID, provider: provider, scope: scope, categoryID: categoryID))
    }
    private func refreshTimestampKey(scope: String) -> String {
        CategoryPins.key(accountID: scope, host: "epg-last-success")
    }
    private func refreshAttemptKey(scope: String) -> String {
        CategoryPins.key(accountID: scope, host: "epg-last-attempt")
    }
    func lastSuccessfulRefresh(model: AppModel) -> Date? {
        guard let scope = model.preferenceKey else { return lastRefresh }
        let timestamp = UserDefaults.standard.double(forKey: refreshTimestampKey(scope: scope))
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : lastRefresh
    }
    func refreshIfDue(model: AppModel) async {
        let hours = UserDefaults.standard.integer(forKey: "ant-epg-auto-refresh-hours")
        guard let interval = EPGRefreshInterval(rawValue: hours), interval != .off,
              model.providerReady, let scope = model.preferenceKey else { return }
        let previous = UserDefaults.standard.double(forKey: refreshTimestampKey(scope: scope))
        let now = Date().timeIntervalSince1970
        let attempted = UserDefaults.standard.double(forKey: refreshAttemptKey(scope: scope))
        guard (previous == 0 || now - previous >= Double(hours * 3600)), now - attempted >= 900 else { return }
        await refresh(model: model, channels: [])
    }
    func refresh(model: AppModel, channels: [CatalogItem]) async {
        guard !refreshing, model.providerReady,
              let scope = model.preferenceKey else { return }
        refreshing = true; refreshError = ""
        defer { refreshing = false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: refreshAttemptKey(scope: scope))
        let activeScopePrefix = scope + "-"
        let epoch = generation
        do {
            var categories = model.catalog.knownCategories(kind: .live)
            if categories.isEmpty { categories = try await model.catalog.categories(kind: .live, model: model) }
            let enabledCategoryIDs = Set(categories.filter { model.preferences.allows($0, section: .live) }.map(\.id))
            var targets = known.filter {
                $0.value.scope.hasPrefix(activeScopePrefix)
                    && ($0.value.categoryID.isEmpty || enabledCategoryIDs.contains($0.value.categoryID))
            }
            for channel in channels {
                guard channel.categoryID.isEmpty || enabledCategoryIDs.contains(channel.categoryID) else { continue }
                let provider = model.provider(for: channel)
                let channelScope = model.epgScope(for: channel)
                targets[channelScope + ":" + channel.id] = KnownChannel(id: channel.id, categoryID: channel.categoryID, provider: provider, scope: channelScope)
            }
            if targets.isEmpty {
                if let category = model.preferences.browseCategories(categories, section: .live).first {
                    let items = try await model.catalog.items(kind: .live, category: category.id, model: model)
                    for item in items.filter(model.preferences.visible).prefix(40) {
                        let provider = model.provider(for: item)
                        let channelScope = model.epgScope(for: item)
                        targets[channelScope + ":" + item.id] = KnownChannel(id: item.id, categoryID: item.categoryID, provider: provider, scope: channelScope)
                    }
                }
            }
            guard generation == epoch, !Task.isCancelled else { return }
            guard !targets.isEmpty else { refreshError = "No selected Live TV channels available to refresh."; return }
            // Cancel older requests before starting a fresh provider fetch.
            generation += 1
            let refreshGeneration = generation
            for flight in flights.values { flight.task.cancel() }
            flights.removeAll(); failures.removeAll()
            // Sequential batches keep both the provider and the request queue bounded.
            let orderedTargets = targets.keys.sorted()
            for start in stride(from: 0, to: orderedTargets.count, by: concurrency) {
                await withTaskGroup(of: Void.self) { group in
                    for key in orderedTargets.dropFirst(start).prefix(concurrency) {
                        guard let target = targets[key] else { continue }
                        group.addTask { _ = await self.programs(streamID: target.id, provider: target.provider, scope: target.scope, categoryID: target.categoryID, forceRefresh: true) }
                    }
                }
                guard generation == refreshGeneration, !Task.isCancelled else { return }
            }
            if failures.isEmpty {
                lastRefresh = Date()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: refreshTimestampKey(scope: scope))
            }
            else { refreshError = "Could not refresh \(failures.count) channel(s). Check your provider and try again." }
            revision += 1
        } catch {
            if generation == epoch { refreshError = "Guide refresh failed. Check your provider and try again." }
        }
    }

    private static func fetch(streamID: String, provider: Provider) async throws -> [EPGProgram] {
        if provider.kind == .m3u { return try await PlaylistStore.shared.programs(streamID: streamID, provider: provider) }
        var components = URLComponents(url: try provider.apiURL(action: "get_short_epg"), resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "stream_id", value: streamID), URLQueryItem(name: "limit", value: "8")]
        guard let url = components.url else { throw AppFailure("Invalid guide URL.") }
        let data = try await BoundedTransfer(limit: 512 * 1024, timeout: 15).fetch(url, headers: ["Cache-Control": "no-cache", "Pragma": "no-cache"])
        return try await Task.detached(priority: .utility) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["epg_listings"] is [[String: Any]] else { throw AppFailure("Invalid guide response.") }
            return EPGParser.programs(root)
        }.value
    }
}

struct EPGRefreshControl: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var cache = EPGCache.shared
    @AppStorage("ant-epg-auto-refresh-hours") private var autoRefreshHours = 0
    var channels: [CatalogItem] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await cache.refresh(model: model, channels: channels) } } label: {
                Label(cache.refreshing ? "Refreshing guide…" : "Refresh EPG", systemImage: "arrow.clockwise")
            }.disabled(cache.refreshing || !model.providerReady)
            Picker("Automatic EPG refresh", selection: $autoRefreshHours) {
                ForEach(EPGRefreshInterval.allCases) { interval in Text(interval.title).tag(interval.rawValue) }
            }.pickerStyle(.menu)
            Text("Runs while Ant Streams is open. When you return after the interval, the guide refreshes automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if let date = cache.lastSuccessfulRefresh(model: model) {
                Text("Last successful refresh: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            } else { Text("Guide has not been refreshed yet.").font(.caption) }
            if !cache.refreshError.isEmpty { Text(cache.refreshError).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// Automatic EPG requests are checked while the app is active. iOS/tvOS may
/// suspend apps in the background, so a missed interval is handled on resume.
struct EPGAutoRefreshMonitor: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ant-epg-auto-refresh-hours") private var autoRefreshHours = 0

    func body(content: Content) -> some View {
        content.task(id: "\(scenePhase)-\(autoRefreshHours)") {
            guard scenePhase == .active, autoRefreshHours > 0 else { return }
            while model.starting && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            while !Task.isCancelled && scenePhase == .active {
                await EPGCache.shared.refreshIfDue(model: model)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

extension View {
    func monitorAutomaticEPGRefresh() -> some View { modifier(EPGAutoRefreshMonitor()) }
}
