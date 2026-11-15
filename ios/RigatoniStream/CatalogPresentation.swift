import Foundation
import SwiftUI

// Shared presentation for iPhone and Apple TV: region filtering, display names,
// category order, and home-shelf ranking. Playback and credentials stay elsewhere.
// A missing TMDB key is the normal case — shelves still fill from the provider.

enum CatalogSection: String, Codable, CaseIterable, Identifiable {
    case live, movies, series
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "TV Shows"
        }
    }
    init(_ kind: LibraryKind) { self = kind == .live ? .live : .movies }
}

enum ProviderFields {
    static func text(_ value: Any?) -> String {
        switch value {
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as Int: return String(number)
        case let number as Double: return number.rounded() == number ? String(Int(number)) : String(number)
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }
    static func integer(_ value: Any?) -> Int {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let number as NSNumber: return number.intValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(trimmed) { return number }
            if let number = Double(trimmed) { return Int(number) }
            return 0
        default: return 0
        }
    }
    static func number(_ value: Any?) -> Double {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default: return 0
        }
    }
    static func added(from row: [String: Any]) -> Int {
        let primary = integer(row["added"])
        return primary > 0 ? primary : integer(row["last_modified"])
    }
    static func rating(from row: [String: Any]) -> Double {
        let five = number(row["rating_5based"])
        if five > 0 { return min(five * 2, 10) }
        let score = number(row["rating"])
        return score > 0 ? min(score, 10) : 0
    }
    static func year(from row: [String: Any]) -> String {
        for key in ["year", "release_date", "releasedate", "releaseDate"] {
            let text = text(row[key])
            if let range = text.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression) {
                return String(text[range])
            }
        }
        return ""
    }
}

enum PosterCaption {
    static func film(year: String) -> String { year.isEmpty ? "Film" : "\(year), Film" }
    static func series(year: String) -> String { year.isEmpty ? "Series" : "\(year), Series" }
}

enum CategoryOrder {
    static func apply(_ categories: [CatalogCategory], saved: [String]) -> [CatalogCategory] {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [CatalogCategory] = []
        for id in saved {
            if let category = byID[id], seen.insert(id).inserted { result.append(category) }
        }
        for category in categories where seen.insert(category.id).inserted { result.append(category) }
        return result
    }
}

/// United States versus explicitly foreign category tags.
/// Two-letter codes count only with a separator (`US|`, `UK:`, `(MX)`).
/// Longer words such as `USA`, `ENGLISH`, `SPANISH`, and `CANADA` also count
/// as a leading word. Untagged names are not foreign.
enum CategoryRegion {
    static let usWords: Set<String> = ["USA"]
    static let englishWords: Set<String> = ["ENGLISH", "ENG"]
    static let foreignWords: Set<String> = [
        "CANADA", "MEXICO", "BRAZIL", "ARGENTINA", "COLOMBIA", "CHILE", "PERU",
        "LATINO", "LATINA", "LATAM", "SPANISH", "FRENCH", "GERMAN", "ITALIAN",
        "PORTUGUESE", "ARABIC", "ARAB", "HINDI", "DESI", "PUNJABI", "TURKISH",
        "RUSSIAN", "POLISH", "KOREAN", "JAPANESE", "CHINESE", "AUSTRALIA",
        "GERMANY", "FRANCE", "ITALY", "SPAIN", "INDIA", "PAKISTAN", "TURKEY",
        "IRELAND", "SCOTLAND", "ENGLAND", "BRITAIN", "BRITISH", "EUROPE",
        "AFRICA", "ASIA", "PORTUGAL", "GREECE", "POLAND", "SWEDEN", "NORWAY",
        "NETHERLANDS", "BELGIUM", "SWITZERLAND", "AUSTRIA", "UKRAINE", "ISRAEL",
        "QUEBEC", "BRASIL"
    ]
    static let separatedCodes: [String] = [
        "ENGLISH", "CANADA", "MEXICO", "BRAZIL", "BRASIL", "ARGENTINA", "LATINO", "LATINA", "LATAM",
        "SPANISH", "FRENCH", "GERMAN", "ITALIAN", "PORTUGUESE", "ARABIC", "U.S.A.", "U.S.",
        "USA", "ENG", "UK", "GB", "CA", "CAN", "MX", "AR", "BR", "DE", "FR", "ES", "IT", "PT",
        "NL", "AU", "NZ", "IN", "PK", "TR", "RU", "PL", "RO", "SE", "NO", "DK", "FI", "JP",
        "KR", "CN", "ZA", "IE", "BE", "CH", "AT", "HU", "CZ", "SK", "UA", "IL", "SA", "AE",
        "PH", "VN", "TH", "MY", "SG", "HK", "TW", "CO", "CL", "PE", "QC", "GR", "EN", "US"
    ]

    static func included(_ name: String, unitedStatesOnly: Bool) -> Bool {
        guard unitedStatesOnly else { return true }
        let folded = NameCleaner.fold(name)
        if hasTag(folded, words: usWords, codes: ["U.S.A.", "U.S.", "USA", "US"]) { return true }
        if hasTag(folded, words: foreignWords, codes: separatedCodes.filter { !["U.S.A.", "U.S.", "USA", "US", "ENGLISH", "ENG", "EN"].contains($0) }) { return false }
        if hasTag(folded, words: englishWords, codes: ["ENGLISH", "ENG", "EN"]) { return true }
        return true
    }

    static func isUnitedStates(_ name: String) -> Bool {
        let folded = NameCleaner.fold(name)
        return hasTag(folded, words: usWords.union(englishWords), codes: ["U.S.A.", "U.S.", "USA", "US", "ENGLISH", "ENG", "EN"])
    }

    static func isForeign(_ name: String) -> Bool {
        !included(name, unitedStatesOnly: true) 
    }

    private static func hasTag(_ name: String, words: Set<String>, codes: [String]) -> Bool {
        if leadingWords(name).contains(where: { words.contains($0) }) { return true }
        return NameCleaner.hasSeparatedTag(name, codes: codes)
    }

    private static func leadingWords(_ name: String) -> [String] {
        var words: [String] = []
        for segment in name.components(separatedBy: "|") {
            for piece in segment.components(separatedBy: "·") {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first else { continue }
                let letters = String(first).uppercased().filter(\.isLetter)
                if letters.count >= 3 { words.append(letters) }
            }
        }
        return words
    }
}

enum NameCleaner {
    private static let quality: Set<String> = [
        "RAW", "HD", "FHD", "UHD", "SD", "HQ", "HDR", "HDR10", "HEVC", "H265", "H264",
        "X265", "X264", "AVC", "4K", "8K", "2160P", "1080P", "720P", "480P",
        "60FPS", "50FPS", "30FPS", "25FPS", "24FPS", "120FPS", "SHD", "FPS"
    ]
    private static let groups = ["AT&T", "SPECTRUM", "XFINITY", "DIRECTV", "DISH", "VERIZON", "FIOS", "COX", "OPTIMUM", "FRONTIER", "MEDIACOM"]
    private static let brands: [String: String] = [
        "AT&T": "AT&T", "A&E": "A&E", "ESPN": "ESPN", "HBO": "HBO", "BBC": "BBC",
        "CNN": "CNN", "NBC": "NBC", "CBS": "CBS", "ABC": "ABC", "AMC": "AMC",
        "TNT": "TNT", "TBS": "TBS", "FX": "FX", "MTV": "MTV", "VH1": "VH1",
        "NFL": "NFL", "NBA": "NBA", "MLB": "MLB", "NHL": "NHL", "TLC": "TLC",
        "HGTV": "HGTV", "SYFY": "Syfy", "STARZ": "Starz", "PBS": "PBS", "BET": "BET",
        "IFC": "IFC", "TCM": "TCM", "FS1": "FS1", "FS2": "FS2", "CNBC": "CNBC",
        "MSNBC": "MSNBC", "HLN": "HLN", "USA": "USA", "CW": "CW", "QVC": "QVC",
        "HSN": "HSN", "TV": "TV", "US": "US", "E!": "E!", "HBOMAX": "HBO Max", "NETFLIX": "Netflix",
        "TUBI": "Tubi", "PEACOCK": "Peacock", "DISNEY": "Disney", "HULU": "Hulu",
        "PRIME": "Prime", "SPECTRUM": "Spectrum", "XFINITY": "Xfinity", "ROKU": "Roku",
        "PLUTO": "Pluto", "YOUTUBE": "YouTube", "PARAMOUNT": "Paramount", "SHOWTIME": "Showtime",
        "FREEFORM": "Freeform", "HALLMARK": "Hallmark", "LIFETIME": "Lifetime",
        "HISTORY": "History", "NATGEO": "Nat Geo", "DAZN": "DAZN", "PPV": "PPV",
        "SKY": "Sky", "ITV": "ITV", "SUNDANCE": "Sundance", "BRAVO": "Bravo",
        "OXYGEN": "Oxygen", "CARTOON": "Cartoon", "NICK": "Nick", "NICKELODEON": "Nickelodeon",
        "COMEDY": "Comedy", "FOOD": "Food", "DISCOVERY": "Discovery", "ANIMAL": "Animal",
        "SCIENCE": "Science", "APPLE": "Apple", "MAX": "Max", "DIRECTV": "DirecTV",
        "FIOS": "Fios", "COX": "Cox", "OPTIMUM": "Optimum", "FRONTIER": "Frontier",
        "365BLK": "365BLK"
    ]

    static func clean(_ raw: String) -> String {
        let folded = fold(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = unwrapBanner(folded)
        text = stripRegionPrefixes(text)
        text = stripGroupPrefix(text)
        text = stripQuality(text)
        text = collapse(text)
        if text.rangeOfCharacter(from: .alphanumerics) == nil {
            let fallback = titleCase(collapse(unwrapBanner(folded)))
            return fallback.isEmpty ? folded : fallback
        }
        return titleCase(text)
    }

    static func fold(_ raw: String) -> String {
        var result = ""
        for character in raw {
            if let mapped = foldedLetters[character] { result.append(mapped) }
            else { result.append(character) }
        }
        let half = result.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? result
        return half.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    static func hasSeparatedTag(_ name: String, codes: [String]) -> Bool {
        guard let regex = separatedRegex(codes) else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, options: [], range: range) != nil
    }

    static func stripRegionPrefixes(_ text: String) -> String {
        guard let regex = separatedRegex(CategoryRegion.separatedCodes) else { return text }
        var value = text
        for _ in 0..<4 {
            let range = NSRange(value.startIndex..., in: value)
            let next = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            if next == value { break }
            value = next.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static let regexLock = NSLock()
    private static var separatedCache: [String: NSRegularExpression] = [:]
    private static func separatedRegex(_ codes: [String]) -> NSRegularExpression? {
        let key = codes.joined(separator: "\n")
        regexLock.lock()
        if let cached = separatedCache[key] { regexLock.unlock(); return cached }
        regexLock.unlock()
        let alt = codes.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        guard !alt.isEmpty else { return nil }
        let pattern = "(?:^|(?<=[|·]))\\s*(?:[\\[\\(]\\s*(?:\(alt))\\s*[\\]\\)]\\s*|(?:\(alt))\\s*[:|/\\\\\\-]+\\s*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        regexLock.lock()
        separatedCache[key] = regex
        regexLock.unlock()
        return regex
    }

    private static func unwrapBanner(_ text: String) -> String {
        let pattern = #"^[\s#*=\-_~·.•|]+(.+?)[\s#*=\-_~·.•|]+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return text }
        let core = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, core.rangeOfCharacter(from: CharacterSet(charactersIn: "#*=")) == nil else { return text }
        return core
    }

    private static func stripGroupPrefix(_ text: String) -> String {
        let alt = groups.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "^(?:\(alt))\\s*[:|]\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return text }
        let remainder = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? text : remainder
    }

    static func stripQuality(_ text: String) -> String {
        var value = text
        if let regex = try? NSRegularExpression(pattern: #"\(([^)]*)\)"#) {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let outer = Range(match.range, in: value), let inner = Range(match.range(at: 1), in: value) else { continue }
                let parts = value[inner].split { $0 == " " || $0 == "/" }
                if !parts.isEmpty, parts.allSatisfy({ isQuality(String($0)) }) {
                    value.replaceSubrange(outer, with: " ")
                }
            }
        }
        let tokens = value.split(separator: " ").map(String.init)
        var kept: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.uppercased() == "FULL", index + 1 < tokens.count, isQuality(tokens[index + 1]) {
                index += 2
                continue
            }
            if isFrameRate(token), index + 1 < tokens.count, tokens[index + 1].uppercased() == "FPS" {
                index += 2
                continue
            }
            let parts = token.split(separator: "/").map(String.init)
            if parts.count > 1 {
                let remain = parts.filter { !isQuality($0) }
                if remain.isEmpty { index += 1; continue }
                if remain.count != parts.count {
                    kept.append(remain.joined(separator: " "))
                    index += 1
                    continue
                }
            }
            if isQuality(token) { index += 1; continue }
            kept.append(token)
            index += 1
        }
        return kept.joined(separator: " ")
    }

    private static func isQuality(_ token: String) -> Bool {
        let compact = token.uppercased().filter { $0.isLetter || $0.isNumber }
        return quality.contains(compact)
    }
    private static func isFrameRate(_ token: String) -> Bool {
        ["24", "25", "30", "50", "60", "120"].contains(token)
    }
    private static func collapse(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "·", with: " · ")
        let trimmed = spaced.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|:-")))
        return trimmed.split(separator: " ").joined(separator: " ")
    }
    private static func titleCase(_ text: String) -> String {
        text.split(separator: " ").map { token -> String in
            let word = String(token)
            let key = word.uppercased()
            if let brand = brands[key] { return brand }
            if word.contains(where: \.isNumber), !word.contains("-"), !word.contains(" ") { return key }
            return word.split(separator: "-").map { part -> String in
                let piece = String(part)
                if piece.allSatisfy(\.isNumber) { return piece }
                if let brand = brands[piece.uppercased()] { return brand }
                return piece.split(separator: "'").map { atom -> String in
                    guard let first = atom.first else { return "" }
                    return String(first).uppercased() + atom.dropFirst().lowercased()
                }.joined(separator: "'")
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    private static let foldedLetters: [Character: String] = {
        var map: [Character: String] = [:]
        let pairs: [(String, String)] = [
            ("ᴬ", "A"), ("ᴮ", "B"), ("ᴰ", "D"), ("ᴱ", "E"), ("ᴳ", "G"), ("ᴴ", "H"), ("ᴵ", "I"),
            ("ᴶ", "J"), ("ᴷ", "K"), ("ᴸ", "L"), ("ᴹ", "M"), ("ᴺ", "N"), ("ᴼ", "O"), ("ᴾ", "P"),
            ("ᴿ", "R"), ("ᵀ", "T"), ("ᵁ", "U"), ("ᵂ", "W"),
            ("ᴀ", "A"), ("ʙ", "B"), ("ᴄ", "C"), ("ᴅ", "D"), ("ᴇ", "E"), ("ꜰ", "F"), ("ɢ", "G"),
            ("ʜ", "H"), ("ɪ", "I"), ("ᴊ", "J"), ("ᴋ", "K"), ("ʟ", "L"), ("ᴍ", "M"), ("ɴ", "N"),
            ("ᴏ", "O"), ("ᴘ", "P"), ("ʀ", "R"), ("ꜱ", "S"), ("ᴛ", "T"), ("ᴜ", "U"), ("ᴠ", "V"),
            ("ᴡ", "W"), ("ʏ", "Y"), ("ᴢ", "Z"),
            ("⁰", "0"), ("¹", "1"), ("²", "2"), ("³", "3"), ("⁴", "4"), ("⁵", "5"), ("⁶", "6"),
            ("⁷", "7"), ("⁸", "8"), ("⁹", "9")
        ]
        for (source, dest) in pairs { if let character = source.first { map[character] = dest } }
        return map
    }()
}

enum ShelfRanking {
    struct Candidate {
        var index: Int
        var name: String
        var added: Int
        var rating: Double
        var hasPoster: Bool
    }

    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let spaced = folded.map { character -> Character in
            (character.isLetter || character.isNumber) ? character : " "
        }
        var text = String(spaced).split(separator: " ").joined(separator: " ")
        if let range = text.range(of: #" (?:19|20)\d{2}$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func recentlyAdded(_ items: [Candidate], limit: Int = 18) -> [Int] {
        var seen = Set<String>()
        return items.filter { $0.added > 0 }
            .sorted { lhs, rhs in lhs.added == rhs.added ? lhs.name < rhs.name : lhs.added > rhs.added }
            .filter { seen.insert(normalize($0.name)).inserted }
            .prefix(limit)
            .map(\.index)
    }

    static func trending(_ items: [Candidate], tmdbTitles: [String], limit: Int = 18) -> [Int] {
        if !tmdbTitles.isEmpty {
            let matched = match(items, titles: tmdbTitles)
            if !matched.isEmpty { return Array(matched.prefix(limit)) }
        }
        var seen = Set<String>()
        return items.sorted { lhs, rhs in
            if lhs.hasPoster != rhs.hasPoster { return lhs.hasPoster && !rhs.hasPoster }
            if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
            if lhs.added != rhs.added { return lhs.added > rhs.added }
            return lhs.name < rhs.name
        }
        .filter { seen.insert(normalize($0.name)).inserted }
        .prefix(limit)
        .map(\.index)
    }

    static func match(_ items: [Candidate], titles: [String]) -> [Int] {
        let grouped = Dictionary(grouping: items, by: { normalize($0.name) })
        var used = Set<Int>()
        var result: [Int] = []
        for title in titles {
            let key = normalize(title)
            guard key.count >= 2 else { continue }
            var choices = grouped[key] ?? []
            if choices.isEmpty, key.count >= 4 {
                choices = items.filter { candidate in
                    let name = normalize(candidate.name)
                    return name == key || name.hasPrefix(key + " ") || (name.count >= 4 && key.hasPrefix(name + " "))
                }
            }
            guard let best = choices.filter({ !used.contains($0.index) }).max(by: { lhs, rhs in
                (lhs.hasPoster ? 1 : 0, lhs.rating) < (rhs.hasPoster ? 1 : 0, rhs.rating)
            }) else { continue }
            used.insert(best.index)
            result.append(best.index)
        }
        return result
    }
}

enum TMDBClient {
    static func trendingNames(apiKey: String, media: String) async -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, media == "movie" || media == "tv",
              let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.themoviedb.org/3/trending/\(media)/week?api_key=\(encoded)") else { return [] }
        guard let data = try? await BoundedTransfer(limit: 1_000_000, timeout: 12).fetch(url) else { return [] }
        return titles(in: data)
    }
    static func titles(in data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { row in
            let name = (row["title"] as? String) ?? (row["name"] as? String) ?? ""
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

enum ResumeList {
    static func progressKey(kind: String, itemID: String) -> String? {
        switch kind {
        case "movie": return itemID
        case "episode", "series": return "series-" + itemID
        default: return nil
        }
    }
    static func isInProgress(kind: String, itemID: String, progress: [String: MovieProgress]) -> Bool {
        guard let key = progressKey(kind: kind, itemID: itemID) else { return false }
        return progress[key] != nil
    }
}

extension LibraryPreferences {
    func categoryVisible(_ id: String, section: CatalogSection) -> Bool {
        switch section {
        case .live: return !hiddenLiveCategories.contains(id)
        case .movies: return !hiddenMovieCategories.contains(id)
        case .series: return !hiddenSeriesCategories.contains(id)
        }
    }
    func allows(_ category: CatalogCategory, section: CatalogSection) -> Bool {
        categoryVisible(category.id, section: section) && CategoryRegion.included(category.name, unitedStatesOnly: unitedStatesOnly)
    }
    func presented(_ categories: [CatalogCategory], section: CatalogSection) -> [CatalogCategory] {
        CategoryOrder.apply(categories.filter { allows($0, section: section) }, saved: categoryOrder[section.rawValue] ?? [])
    }
    func managedOrder(_ categories: [CatalogCategory], section: CatalogSection) -> [CatalogCategory] {
        CategoryOrder.apply(categories, saved: categoryOrder[section.rawValue] ?? [])
    }
    /// Visible categories in the saved order, with display names applied.
    func browseCategories(_ categories: [CatalogCategory], section: CatalogSection) -> [CatalogCategory] {
        presented(categories, section: section).map {
            CatalogCategory(id: $0.id, name: categoryTitle($0, section: section))
        }
    }
    func accepts(_ item: CatalogItem, categories: [CatalogCategory]) -> Bool {
        guard visible(item) else { return false }
        let section = CatalogSection(item.kind)
        guard !item.categoryID.isEmpty else { return true }
        guard let category = categories.first(where: { $0.id == item.categoryID }) else { return true }
        return allows(category, section: section)
    }
    func acceptsSeries(_ item: SeriesItem, categories: [CatalogCategory]) -> Bool {
        guard !item.categoryID.isEmpty else { return true }
        guard let category = categories.first(where: { $0.id == item.categoryID }) else { return true }
        return allows(category, section: .series)
    }
    static func renameKey(section: CatalogSection, role: String, id: String) -> String {
        "\(section.rawValue).\(role).\(id)"
    }
    func displayName(raw: String, key: String) -> String {
        if let custom = renames[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        if cleanNames {
            let cleaned = NameCleaner.clean(raw)
            return cleaned.isEmpty ? raw : cleaned
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }
    func categoryTitle(_ category: CatalogCategory, section: CatalogSection) -> String {
        displayName(raw: category.name, key: Self.renameKey(section: section, role: "category", id: category.id))
    }
    func itemTitle(_ item: CatalogItem) -> String {
        displayName(raw: item.name, key: Self.renameKey(section: CatalogSection(item.kind), role: "item", id: item.scopedID))
    }
    func seriesTitle(_ item: SeriesItem) -> String {
        displayName(raw: item.name, key: Self.renameKey(section: .series, role: "item", id: item.scopedID))
    }
    mutating func setSection(_ id: String, section: CatalogSection, visible: Bool) {
        switch section {
        case .live: setCategory(id, kind: .live, visible: visible)
        case .movies: setCategory(id, kind: .movies, visible: visible)
        case .series:
            if visible { hiddenSeriesCategories.remove(id) } else { hiddenSeriesCategories.insert(id) }
        }
    }
    mutating func moveCategory(_ id: String, section: CatalogSection, direction: Int, among categories: [CatalogCategory]) {
        var ids = CategoryOrder.apply(categories, saved: categoryOrder[section.rawValue] ?? []).map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let next = index + direction
        guard ids.indices.contains(next) else { return }
        ids.swapAt(index, next)
        categoryOrder[section.rawValue] = ids
    }
    mutating func setRename(_ name: String?, key: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { renames.removeValue(forKey: key) }
        else { renames[key] = String(trimmed.prefix(80)) }
    }
}

struct ShelfPoster: Identifiable {
    enum Media { case movie(CatalogItem), show(SeriesItem) }
    let id: String
    let title: String
    let caption: String
    let poster: URL?
    let added: Int
    let media: Media
}

@MainActor
final class HomeShelfLoader: ObservableObject {
    @Published var trendingMovies: [ShelfPoster] = []
    @Published var trendingShows: [ShelfPoster] = []
    @Published var recent: [ShelfPoster] = []
    @Published var loading = false

    func load(model: AppModel, tmdbKey: String) async {
        guard model.providerReady else {
            trendingMovies = []; trendingShows = []; recent = []; loading = false
            return
        }
        loading = true
        defer { loading = false }
        async let movieTask = loadMovies(model)
        async let showTask = loadShows(model)
        let (movies, shows) = await (movieTask, showTask)
        if Task.isCancelled { return }
        async let tmdbMovies = TMDBClient.trendingNames(apiKey: tmdbKey, media: "movie")
        async let tmdbShows = TMDBClient.trendingNames(apiKey: tmdbKey, media: "tv")
        let (movieNames, showNames) = await (tmdbMovies, tmdbShows)
        if Task.isCancelled { return }
        trendingMovies = rankMovies(movies, tmdb: movieNames, recent: false, model: model)
        trendingShows = rankShows(shows, tmdb: showNames, recent: false, model: model)
        let recentMovies = rankMovies(movies, tmdb: [], recent: true, model: model)
        let recentShows = rankShows(shows, tmdb: [], recent: true, model: model)
        recent = (recentMovies + recentShows).sorted { $0.added > $1.added }.prefix(18).map { $0 }
    }

    private func loadMovies(_ model: AppModel) async -> [CatalogItem] {
        let categories: [CatalogCategory]
        do { categories = try await model.catalog.categories(kind: .movies, model: model) }
        catch { return [] }
        let allowed = model.preferences.presented(categories, section: .movies)
        var items: [CatalogItem] = []
        if let full = try? await model.catalog.items(kind: .movies, category: nil, model: model), !full.isEmpty {
            items = full
        }
        if items.isEmpty {
            for category in allowed.prefix(4) {
                if Task.isCancelled { return [] }
                if let batch = try? await model.catalog.items(kind: .movies, category: category.id, model: model) {
                    items.append(contentsOf: batch)
                }
                if items.count > 500 { break }
            }
        }
        return items.filter { model.preferences.accepts($0, categories: categories) }
    }

    private func loadShows(_ model: AppModel) async -> [SeriesItem] {
        let store = SeriesStore(model: model)
        guard store.unavailableReason == nil else { return [] }
        await store.loadCategories()
        if Task.isCancelled { return [] }
        let items = await store.loadAllSeries()
        return items.filter { model.preferences.acceptsSeries($0, categories: store.categories) }
    }

    private func rankMovies(_ items: [CatalogItem], tmdb: [String], recent: Bool, model: AppModel) -> [ShelfPoster] {
        let candidates = items.enumerated().map {
            ShelfRanking.Candidate(index: $0.offset, name: $0.element.name, added: $0.element.added, rating: $0.element.rating, hasPoster: $0.element.poster != nil)
        }
        let indexes = recent ? ShelfRanking.recentlyAdded(candidates) : ShelfRanking.trending(candidates, tmdbTitles: tmdb)
        return indexes.map { index in
            let item = items[index]
            return ShelfPoster(id: "movie-" + item.scopedID, title: model.preferences.itemTitle(item), caption: PosterCaption.film(year: item.year), poster: item.poster, added: item.added, media: .movie(item))
        }
    }
    private func rankShows(_ items: [SeriesItem], tmdb: [String], recent: Bool, model: AppModel) -> [ShelfPoster] {
        let candidates = items.enumerated().map {
            ShelfRanking.Candidate(index: $0.offset, name: $0.element.name, added: $0.element.added, rating: $0.element.rating, hasPoster: $0.element.poster != nil)
        }
        let indexes = recent ? ShelfRanking.recentlyAdded(candidates) : ShelfRanking.trending(candidates, tmdbTitles: tmdb)
        return indexes.map { index in
            let item = items[index]
            return ShelfPoster(id: "show-" + item.scopedID, title: model.preferences.seriesTitle(item), caption: PosterCaption.series(year: item.year), poster: item.poster, added: item.added, media: .show(item))
        }
    }
}

struct PosterTile: View {
    let title: String
    let caption: String
    let poster: URL?
    var width: CGFloat = 148
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderPoster(url: poster, kind: .movies)
                .frame(width: width, height: width * 1.48)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
            Text(caption)
                .font(.caption)
                .foregroundStyle(StreamTheme.muted)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(caption)")
    }
}

struct PosterShelf: View {
    let title: String
    let posters: [ShelfPoster]
    var width: CGFloat = 148
    let select: (ShelfPoster) -> Void
    var body: some View {
        if !posters.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(posters) { poster in
                            Button { select(poster) } label: {
                                PosterTile(title: poster.title, caption: poster.caption, poster: poster.poster, width: width)
                            }
                            #if os(tvOS)
                            .buttonStyle(TVCardButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

struct LibraryFilterToggles: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-tmdb-api-key") private var tmdbKey = ""
    var body: some View {
        Group {
        Toggle(model.preferences.unitedStatesOnly ? "U.S. only" : "Include foreign categories", isOn: Binding(
            get: { model.preferences.unitedStatesOnly },
            set: { model.preferences.unitedStatesOnly = $0; model.savePreferences() }
        ))
        Text("Hides categories tagged for other countries, such as UK| or Spanish. Categories with no country tag stay visible.")
            .font(.footnote).foregroundStyle(.secondary)
        Toggle("Clean names", isOn: Binding(
            get: { model.preferences.cleanNames },
            set: { model.preferences.cleanNames = $0; model.savePreferences() }
        ))
        Text("Display-only. Strips country prefixes and tags such as RAW, HD, 4K and 60fps. Provider names are not changed.")
            .font(.footnote).foregroundStyle(.secondary)
        SecureField("TMDB API key (optional)", text: $tmdbKey)
            .autocorrectionDisabled()
        Text("Leave blank to build Trending from your provider’s posters, ratings and added dates. A v3 key uses TMDB’s weekly list, matched to those titles. The key stays on this device.")
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
