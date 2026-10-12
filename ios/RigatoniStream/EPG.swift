import Foundation

/// A single EPG listing for a live channel, parsed from the Xtream short EPG.
/// Provider timestamps arrive as "yyyy-MM-dd HH:mm:ss" in the provider's
/// local time; they are displayed in the device's local time.
struct EPGProgram: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date?
    let end: Date?
    let details: String
    var timeRange: String {
        let f = EPGCache.timeFormatter
        switch (start, end) {
        case let (s?, e?): return "\(f.string(from: s)) – \(f.string(from: e))"
        case let (s?, nil): return f.string(from: s)
        default: return ""
        }
    }
}

struct EPGNowNext: Equatable {
    let now: EPGProgram?
    let next: EPGProgram?
}

/// Session-scoped, bounded short-EPG cache keyed by stream id.
/// Direct providers only — the gateway exposes no EPG endpoint, so callers
/// pass epgEnabled=false there and fall back to plain channel rows.
@MainActor
final class EPGCache {
    static let shared = EPGCache()
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private struct Entry { let value: EPGNowNext; let fetched: Date }
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<EPGNowNext, Never>] = [:]
    private let ttl: TimeInterval = 15 * 60

    func nowNext(streamID: String, provider: Provider) async -> EPGNowNext {
        if let entry = entries[streamID], Date().timeIntervalSince(entry.fetched) < ttl { return entry.value }
        if let job = inFlight[streamID] { return await job.value }
        let job = Task<EPGNowNext, Never> { await EPGCache.fetch(streamID: streamID, provider: provider) }
        inFlight[streamID] = job
        let value = await job.value
        entries[streamID] = Entry(value: value, fetched: Date())
        inFlight[streamID] = nil
        return value
    }

    private static func fetch(streamID: String, provider: Provider) async -> EPGNowNext {
        do {
            var parts = URLComponents(url: try provider.apiURL(action: "get_short_epg"), resolvingAgainstBaseURL: false)!
            var items = parts.queryItems ?? []
            items.append(URLQueryItem(name: "stream_id", value: streamID))
            items.append(URLQueryItem(name: "limit", value: "4"))
            parts.queryItems = items
            guard let url = parts.url else { return EPGNowNext(now: nil, next: nil) }
            let data = try await BoundedTransfer(limit: 512 * 1024, timeout: 15).fetch(url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return EPGNowNext(now: nil, next: nil) }
            let listings = root["epg_listings"] as? [[String: Any]] ?? []
            let programs = listings.compactMap(parse).sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            let now = Date()
            let current = programs.first { p in
                guard let s = p.start, let e = p.end else { return false }
                return s <= now && now < e
            } ?? programs.first { ($0.end ?? .distantPast) > now }
            let next = programs.first { p in
                guard let s = p.start, p.id != current?.id else { return false }
                return s > (current?.end ?? now)
            }
            return EPGNowNext(now: current, next: next)
        } catch {
            return EPGNowNext(now: nil, next: nil)
        }
    }

    private static func parse(_ row: [String: Any]) -> EPGProgram? {
        let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        func date(_ key: String) -> Date? {
            guard let raw = row[key] as? String else { return nil }
            return stampFormatter.date(from: raw)
        }
        return EPGProgram(
            id: row["id"].map { String(describing: $0) } ?? UUID().uuidString,
            title: title,
            start: date("start"),
            end: date("end"),
            details: (row["description"] as? String) ?? ""
        )
    }
}
