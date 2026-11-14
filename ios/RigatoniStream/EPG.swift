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

// Memory-only cache. Keys contain account/provider scope and IDs, never credentials.
// Four requests at once; bounded entries and queued work prevent a guide from flooding a provider.
@MainActor final class EPGCache: ObservableObject {
    static let shared = EPGCache()
    typealias Loader = (String, Provider) async throws -> [EPGProgram]
    private struct Entry { let programs: [EPGProgram]; let fetched: Date }
    private struct Flight { let token: UUID; let task: Task<[EPGProgram], Never> }
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
    private var known: Set<String> = []
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
    func programs(streamID: String, provider: Provider, scope: String, forceRefresh: Bool = false) async -> [EPGProgram] {
        guard !scope.isEmpty, !provider.requiresGateway, streamID.allSatisfy(\.isNumber), !streamID.isEmpty else { return [] }
        if known.count < limit { known.insert(streamID) }
        let key = scope + ":" + streamID
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
                if generation == epoch, flights[key]?.token == token { failures.remove(streamID) }
                return value
            } catch {
                if generation == epoch, flights[key]?.token == token { failures.insert(streamID) }
                return []
            }
        }
        flights[key] = Flight(token: token, task: job)
        let value = await job.value
        guard generation == epoch, !job.isCancelled, flights[key]?.token == token else { return [] }
        if flights[key]?.token == token { flights[key] = nil }
        guard !failures.contains(streamID) else { return entries[key]?.programs ?? [] }
        entries[key] = Entry(programs: Array(value.prefix(32)), fetched: Date())
        if entries.count > limit, let oldest = entries.min(by: { $0.value.fetched < $1.value.fetched })?.key { entries[oldest] = nil }
        return value
    }
    func nowNext(streamID: String, provider: Provider, scope: String) async -> EPGNowNext {
        EPGParser.nowNext(await programs(streamID: streamID, provider: provider, scope: scope))
    }
    func refresh(model: AppModel, channels: [CatalogItem]) async {
        guard !refreshing, model.providerReady, !model.provider.requiresGateway,
              let scope = model.preferenceKey else { return }
        refreshing = true; refreshError = ""
        defer { refreshing = false }
        let provider = model.provider
        let namespace = scope + "-\(model.libraryRevision)"
        let epoch = generation
        do {
            var ids = Set(channels.map(\.id)).union(known)
            if ids.isEmpty {
                let categories = try await model.catalog.categories(kind: .live, model: model)
                if let category = categories.first(where: { model.preferences.categoryVisible($0.id, kind: .live) }) {
                    let items = try await model.catalog.items(kind: .live, category: category.id, model: model)
                    ids = Set(items.filter(model.preferences.visible).prefix(40).map(\.id))
                }
            }
            guard generation == epoch, !Task.isCancelled else { return }
            guard !ids.isEmpty else { refreshError = "No channels available to refresh."; return }
            // Cancel older requests before starting a fresh provider fetch.
            generation += 1
            let refreshGeneration = generation
            for flight in flights.values { flight.task.cancel() }
            flights.removeAll(); failures.removeAll()
            // Sequential batches keep both the provider and the request queue bounded.
            let targets = ids.sorted()
            for start in stride(from: 0, to: targets.count, by: concurrency) {
                await withTaskGroup(of: Void.self) { group in
                    for id in targets.dropFirst(start).prefix(concurrency) {
                        group.addTask { _ = await self.programs(streamID: id, provider: provider, scope: namespace, forceRefresh: true) }
                    }
                }
                guard generation == refreshGeneration, !Task.isCancelled else { return }
            }
            if failures.isEmpty { lastRefresh = Date() }
            else { refreshError = "Could not refresh \(failures.count) channel(s). Check your provider and try again." }
            revision += 1
        } catch {
            if generation == epoch { refreshError = "Guide refresh failed. Check your provider and try again." }
        }
    }

    private static func fetch(streamID: String, provider: Provider) async throws -> [EPGProgram] {
        var components = URLComponents(url: try provider.apiURL(action: "get_short_epg"), resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "stream_id", value: streamID), URLQueryItem(name: "limit", value: "8")]
        guard let url = components.url else { throw AppFailure("Invalid guide URL.") }
        let data = try await BoundedTransfer(limit: 512 * 1024, timeout: 15).fetch(url, headers: ["Cache-Control": "no-cache", "Pragma": "no-cache"])
        return try await Task.detached(priority: .utility) {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["epg_listings"] is [[String: Any]] else { throw AppFailure("Invalid guide response.") }
            return EPGParser.programs(root)
        }.value
    }
}

struct EPGRefreshControl: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var cache = EPGCache.shared
    var channels: [CatalogItem] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await cache.refresh(model: model, channels: channels) } } label: {
                Label(cache.refreshing ? "Refreshing guide…" : "Refresh EPG", systemImage: "arrow.clockwise")
            }.disabled(cache.refreshing || !model.providerReady || model.provider.requiresGateway)
            if model.provider.requiresGateway { Text("Guide refresh requires a direct provider.").font(.caption) }
            if let date = cache.lastRefresh {
                Text("Last successful refresh: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            } else { Text("Guide has not been manually refreshed.").font(.caption) }
            if !cache.refreshError.isEmpty { Text(cache.refreshError).font(.caption).foregroundStyle(.red) }
        }
    }
}
