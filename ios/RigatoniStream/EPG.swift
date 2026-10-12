import Foundation

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
@MainActor final class EPGCache {
    static let shared = EPGCache()
    typealias Loader = (String, Provider) async -> [EPGProgram]
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
    var cachedCount: Int { entries.count }

    init(limit: Int = 128, concurrency: Int = 4, loader: Loader? = nil) {
        self.limit = max(1, limit); self.concurrency = max(1, concurrency)
        self.loader = loader ?? Self.fetch
    }
    func reset() {
        generation += 1; entries.removeAll()
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
    func programs(streamID: String, provider: Provider, scope: String) async -> [EPGProgram] {
        guard !scope.isEmpty, streamID.allSatisfy(\.isNumber), !streamID.isEmpty else { return [] }
        let key = scope + ":" + streamID
        if let entry = entries[key], Date().timeIntervalSince(entry.fetched) < 300 { return entry.programs }
        if let flight = flights[key] { return await flight.task.value }
        guard flights.count < 64 else { return [] }
        let epoch = generation; let token = UUID()
        let job = Task<[EPGProgram], Never> {
            await acquire()
            defer { release() }
            guard !Task.isCancelled else { return [] }
            return await loader(streamID, provider)
        }
        flights[key] = Flight(token: token, task: job)
        let value = await job.value
        guard generation == epoch, !job.isCancelled else { return [] }
        if flights[key]?.token == token { flights[key] = nil }
        entries[key] = Entry(programs: Array(value.prefix(32)), fetched: Date())
        if entries.count > limit, let oldest = entries.min(by: { $0.value.fetched < $1.value.fetched })?.key { entries[oldest] = nil }
        return value
    }
    func nowNext(streamID: String, provider: Provider, scope: String) async -> EPGNowNext {
        EPGParser.nowNext(await programs(streamID: streamID, provider: provider, scope: scope))
    }
    private static func fetch(streamID: String, provider: Provider) async -> [EPGProgram] {
        do {
            if provider.kind == .m3u { return try await PlaylistStore.shared.programs(streamID: streamID, provider: provider) }
            var components = URLComponents(url: try provider.apiURL(action: "get_short_epg"), resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "stream_id", value: streamID), URLQueryItem(name: "limit", value: "8")]
            guard let url = components.url else { return [] }
            let data = try await BoundedTransfer(limit: 512 * 1024, timeout: 15).fetch(url)
            return await Task.detached(priority: .utility) {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
                return EPGParser.programs(root)
            }.value
        } catch { return [] }
    }
}
