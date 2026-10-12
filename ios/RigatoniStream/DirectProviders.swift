import Foundation
import CryptoKit

enum ProviderAuthentication {
    static func validate(_ provider: Provider) async throws {
        if provider.kind == .m3u {
            _ = try await PlaylistStore.shared.load(provider)
        } else {
            let data = try await BoundedTransfer(limit: 2 * 1024 * 1024).fetch(provider.apiURL(action: ""))
            try validateXtream(data)
        }
    }
    static func validateXtream(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["user_info"] as? [String: Any] else {
            throw AppFailure("This server did not return an Xtream Codes login response. Check its address and port.")
        }
        let auth = String(describing: user["auth"] ?? "")
        guard auth == "1" || auth.lowercased() == "true" else { throw AppFailure("Incorrect provider username or password.") }
        if let status = user["status"] as? String, status.lowercased() != "active" {
            throw AppFailure("The provider account is inactive, expired or disabled. Contact your provider.")
        }
    }
}
enum DirectCatalog {
    static func rows(provider: Provider, action: String, category: String? = nil) async throws -> [[String: Any]] {
        let data = try await BoundedTransfer(limit: 32 * 1024 * 1024).fetch(provider.apiURL(action: action, category: category))
        return try await Task.detached(priority: .userInitiated) {
            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  rows.count <= CatalogIndex.maximumItems else {
                throw AppFailure("The provider returned an invalid or oversized catalog.")
            }
            return rows
        }.value
    }
}
struct PlaylistCatalog {
    let items: [CatalogItem]
    let categories: [LibraryKind: [CatalogCategory]]
    let epgIDs: [String: String]
    let epgURL: URL?
    let skipped: Int
}
enum M3UParser {
    static func identifier(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return String(digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }
    static func attributes(_ line: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))"#)
        let ns = line as NSString
        var values: [String: String] = [:]
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                values[key] = ns.substring(with: match.range(at: index)); break
            }
        }
        return values
    }
    static func parse(_ data: Data, baseURL: URL) throws -> PlaylistCatalog {
        guard data.count <= 32 * 1024 * 1024, let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw AppFailure("This playlist is too large or has an unsupported text encoding.")
        }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard text.hasPrefix("#EXTM3U") else { throw AppFailure("This URL is not an extended M3U playlist.") }
        if text.contains("#EXT-X-TARGETDURATION:") || text.contains("#EXT-X-STREAM-INF:") {
            throw AppFailure("This is a single HLS stream, not an IPTV channel playlist. Add your provider's M3U catalog URL.")
        }
        var entries: [CatalogItem] = []; var groups: [LibraryKind: [CatalogCategory]] = [:]
        var seen = Set<String>(); var epgIDs: [String: String] = [:]; var guide: URL?
        var attrs: [String: String] = [:]; var name = ""; var group = ""; var duration = -1.0; var pending = false; var skipped = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTM3U") {
                let header = attributes(line)
                if let value = header["url-tvg"] ?? header["x-tvg-url"] ?? header["tvg-url"],
                   let first = value.components(separatedBy: ",").first,
                   let url = URL(string: first, relativeTo: baseURL)?.absoluteURL,
                   (try? Provider.validURL(url.absoluteString)) != nil { guide = url }
            } else if line.hasPrefix("#EXTINF:") {
                pending = true; attrs = attributes(line); group = attrs["group-title"] ?? ""
                duration = Double(line.dropFirst(8).split(separator: " ").first?.split(separator: ",").first.map(String.init) ?? "-1") ?? -1
                var quote: Character?; var comma: String.Index?
                for index in line.indices {
                    let char = line[index]
                    if char == "\"" || char == "'" { if quote == char { quote = nil } else if quote == nil { quote = char } }
                    if char == ",", quote == nil { comma = index; break }
                }
                name = comma.map { String(line[line.index(after: $0)...]) } ?? attrs["tvg-name"] ?? "Untitled"
            } else if line.hasPrefix("#EXTGRP:") { group = String(line.dropFirst(8)) }
            else if !line.isEmpty, !line.hasPrefix("#") {
                guard pending else { continue }
                pending = false
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                      (try? Provider.validURL(url.absoluteString)) != nil else { skipped += 1; continue }
                let ext = url.pathExtension.lowercased()
                let declared = (attrs["type"] ?? attrs["media-type"] ?? "").lowercased()
                let kind: LibraryKind = declared == "movie" || declared == "vod" || duration > 0 || ["mp4","mkv","avi","mov","m4v","webm"].contains(ext) ? .movies : .live
                let groupName = group.isEmpty ? (kind == .movies ? "Movies" : "Live TV") : group
                let categoryID = identifier(kind.rawValue + ":" + groupName)
                let id = identifier(url.absoluteString)
                guard seen.insert(id).inserted else { continue }
                let poster = attrs["tvg-logo"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                let safePoster = poster.flatMap { (try? Provider.validURL($0.absoluteString)) != nil ? $0 : nil }
                entries.append(CatalogItem(id: id, name: String((name.isEmpty ? "Untitled" : name).prefix(512)), kind: kind,
                                           fileExtension: ext.isEmpty ? "ts" : ext, poster: safePoster, playbackURL: url, categoryID: categoryID))
                if let epg = attrs["tvg-id"], !epg.isEmpty { epgIDs[id] = epg }
                if !(groups[kind] ?? []).contains(where: { $0.id == categoryID }) {
                    groups[kind, default: []].append(CatalogCategory(id: categoryID, name: String(groupName.prefix(512))))
                }
                guard entries.count <= CatalogIndex.maximumItems else { throw AppFailure("This playlist exceeds the supported catalog size.") }
            }
        }
        guard !entries.isEmpty else { throw AppFailure("No supported HTTP/HTTPS channels or movies were found in this playlist.") }
        return PlaylistCatalog(items: entries, categories: groups, epgIDs: epgIDs, epgURL: guide, skipped: skipped)
    }
}

// XMLTV dates include numeric UTC offsets. Only bounded, current/recent programs are retained.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private var programs: [String: [EPGProgram]] = [:]
    private var channel = ""; private var start: Date?; private var end: Date?
    private var title = ""; private var details = ""; private var element = ""; private var text = ""
    private var count = 0; private var exceeded = false
    private let now: Date
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss Z"; f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }()
    init(now: Date) { self.now = now }
    static func parse(_ data: Data, now: Date = Date()) throws -> [String: [EPGProgram]] {
        guard data.count <= 32 * 1024 * 1024 else { throw AppFailure("The XMLTV guide is too large.") }
        let declaration = String(decoding: data, as: UTF8.self).uppercased()
        guard !declaration.contains("<!DOCTYPE"), !declaration.contains("<!ENTITY") else { throw AppFailure("XMLTV entity declarations are not supported.") }
        let delegate = XMLTVParser(now: now); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.exceeded else { throw AppFailure("Invalid or oversized XMLTV. Use an uncompressed XMLTV URL or HTTP gzip encoding.") }
        return delegate.programs.mapValues { $0.sorted { $0.start < $1.start } }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        element = elementName; text = ""
        if elementName == "programme" {
            count += 1
            if count > 500_000 { exceeded = true; parser.abortParsing(); return }
            channel = attributes["channel"] ?? ""
            func date(_ value: String?) -> Date? {
                guard let value else { return nil }
                return formatter.date(from: value.count == 14 ? value + " +0000" : value)
            }
            start = date(attributes["start"]); end = date(attributes["stop"]); title = ""; details = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if element == "title" || element == "desc" { text += String(string.prefix(max(0, 4000 - text.count))) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title", title.isEmpty { title = String(text.prefix(512)) }
        if elementName == "desc" { details = text }
        if elementName == "programme", let start, let end, end > start, end > now.addingTimeInterval(-3600),
           start < now.addingTimeInterval(172800), !channel.isEmpty, !title.isEmpty,
           programs.count < 10000 || programs[channel] != nil, (programs[channel]?.count ?? 0) < 64 {
            programs[channel, default: []].append(EPGProgram(id: channel + "-\(Int(start.timeIntervalSince1970))", title: title, start: start, end: end, details: details))
        }
        element = ""; text = ""
    }
}

@MainActor final class PlaylistStore {
    static let shared = PlaylistStore()
    private var cached: (String, PlaylistCatalog)?
    private var pending: (String, Task<PlaylistCatalog, Error>)?
    private var guide: (String, Date, [String: [EPGProgram]])?
    private var guideTask: (String, Task<[String: [EPGProgram]], Error>)?
    private var generation = 0
    func reset() {
        generation += 1; pending?.1.cancel(); guideTask?.1.cancel()
        cached = nil; pending = nil; guide = nil; guideTask = nil
    }
    func load(_ provider: Provider) async throws -> PlaylistCatalog {
        let url = try provider.baseURL(); let key = M3UParser.identifier(url.absoluteString)
        if let cached, cached.0 == key { return cached.1 }
        if let pending, pending.0 == key { return try await pending.1.value }
        let epoch = generation
        let task = Task {
            let transfer = BoundedTransfer(limit: 32 * 1024 * 1024)
            let data = try await transfer.fetch(url)
            let base = transfer.resolvedURL ?? url
            return try await Task.detached(priority: .userInitiated) { try M3UParser.parse(data, baseURL: base) }.value
        }
        pending = (key, task)
        do {
            let result = try await task.value
            guard generation == epoch else { throw CancellationError() }
            cached = (key, result); pending = nil; return result
        } catch { if generation == epoch { pending = nil }; throw error }
    }
    func programs(streamID: String, provider: Provider) async throws -> [EPGProgram] {
        let catalog = try await load(provider)
        let guideURL = try provider.epgURL.isEmpty ? catalog.epgURL : Provider.validURL(provider.epgURL)
        guard let id = catalog.epgIDs[streamID], let url = guideURL else { return [] }
        let key = M3UParser.identifier(url.absoluteString); let epoch = generation
        if let guide, guide.0 == key, Date().timeIntervalSince(guide.1) < 900 { return guide.2[id] ?? [] }
        let job: Task<[String: [EPGProgram]], Error>
        if let pending = guideTask, pending.0 == key { job = pending.1 }
        else {
            job = Task {
                let data = try await BoundedTransfer(limit: 32 * 1024 * 1024, timeout: 45).fetch(url)
                return try await Task.detached(priority: .utility) { try XMLTVParser.parse(data) }.value
            }
            guideTask = (key, job)
        }
        do {
            let result = try await job.value
            guard epoch == generation else { throw CancellationError() }
            guide = (key, Date(), result); guideTask = nil; return result[id] ?? []
        } catch { if epoch == generation { guideTask = nil }; throw error }
    }
}
