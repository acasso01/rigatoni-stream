import Foundation
import Combine
import Security

enum TransportPolicy {
    static func permits(_ url: URL, settings: [String: Any]? = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return settings?["NSAllowsArbitraryLoads"] as? Bool == true
    }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case xtream, m3u
    var id: String { rawValue }
    var title: String { self == .xtream ? "Xtream Codes" : "M3U Playlist" }
}
struct Provider: Codable, Equatable {
    var server = ""
    var username = ""
    var password = ""
    var name = ""
    var kind: ProviderKind = .xtream
    var epgURL = ""
    var usesHTTP: Bool { (try? baseURL().scheme?.lowercased()) == "http" }
    func baseURL() throws -> URL {
        let url = try Self.validURL(server)
        guard kind == .m3u || (url.query == nil && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty)
        else { throw AppFailure("Enter the server URL, username and password. Use the server address, not a player_api.php login link.") }
        return url
    }
    static func validURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw AppFailure("Enter a valid http:// or https:// URL, including the port if required.")
        }
        return url
    }
    func apiURL(action: String, category: String? = nil) throws -> URL {
        guard kind == .xtream else { throw AppFailure("This feature requires an Xtream Codes provider.") }
        var parts = URLComponents(url: try baseURL().appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if !action.isEmpty { parts.queryItems?.append(URLQueryItem(name: "action", value: action)) }
        if let category { parts.queryItems?.append(URLQueryItem(name: "category_id", value: category)) }
        guard let url = parts.url else { throw AppFailure("Invalid provider URL.") }
        return url
    }
    func streamURL(item: CatalogItem) throws -> URL {
        if let url = item.playbackURL { return url }
        guard kind == .xtream else { throw AppFailure("Refresh the playlist to reopen this stream.") }
        let folder = item.kind == .movies ? "movie" : "live"
        var parts = URLComponents(url: try baseURL(), resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let components = [folder, username, password, "\(item.id).\(item.fileExtension)"]
        parts.percentEncodedPath = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = "/" + ([parts.percentEncodedPath].filter { !$0.isEmpty } + components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }).joined(separator: "/")
        guard let url = parts.url else { throw AppFailure("Invalid stream URL.") }
        return url
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum LibraryKind: String, CaseIterable, Identifiable {
    case live, movies
    var id: String { rawValue }
    var title: String { self == .live ? "Live TV" : "Movies" }
    var symbol: String { self == .live ? "tv" : "film" }
    var categoryAction: String { self == .live ? "get_live_categories" : "get_vod_categories" }
    var streamAction: String { self == .live ? "get_live_streams" : "get_vod_streams" }
}

struct CatalogCategory: Identifiable, Equatable {
    let id: String
    let name: String
}
struct CatalogItem: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: LibraryKind
    let fileExtension: String
    let poster: URL?
    var playbackURL: URL? = nil
    var categoryID: String = ""
    var number: String = "" // Channel number (Xtream `num`); empty for M3U playlists.
    static func parse(_ row: [String: Any], kind: LibraryKind) -> CatalogItem? {
        let id = row["stream_id"].map { String(describing: $0) } ?? ""
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        let ext = (row["container_extension"] as? String ?? (kind == .movies ? "mp4" : "ts")).lowercased()
        let allowed = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "m3u8"]
        let image = (row["stream_icon"] as? String).flatMap(URL.init(string:))
        return CatalogItem(id: id, name: row["name"] as? String ?? "Untitled", kind: kind,
                           fileExtension: allowed.contains(ext) ? ext : "mp4",
                           poster: ["https", "http"].contains(image?.scheme ?? "") ? image : nil,
                           categoryID: row["category_id"].map { String(describing: $0) } ?? "",
                           number: row["num"].map { String(describing: $0) } ?? "")
    }
}

struct ProviderProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var provider: Provider
}
struct ProviderVault: Codable, Equatable {
    var profiles: [ProviderProfile] = []
    var selectedID: UUID?
}

// A single atomic Keychain record contains profiles and the selection. No cloud sync.
enum ProviderKeychain {
    static let service = "com.acasso01.antstreams.local-providers"
    static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "profiles"]
    }
    static func read(service: String = service) throws -> ProviderVault {
        var request = query(service: service)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &value)
        if code == errSecItemNotFound { return ProviderVault() }
        guard code == errSecSuccess, let data = value as? Data else { throw AppFailure("Unlock this device and retry loading your saved providers.") }
        do { return try JSONDecoder().decode(ProviderVault.self, from: data) }
        catch { throw AppFailure("Saved providers could not be read. Your Keychain data has not been overwritten.") }
    }
    static func write(_ vault: ProviderVault, service: String = service) throws {
        let data = try JSONEncoder().encode(vault)
        let query = query(service: service)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw AppFailure("Could not save providers securely in Keychain.") }
        } else if status != errSecSuccess { throw AppFailure("Could not update providers in Keychain.") }
    }
    static func clear(service: String = service) throws {
        let code = SecItemDelete(query(service: service) as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw AppFailure("Could not delete saved providers.") }
    }
    static func removeLegacySession() {
        // Only remove obsolete local account tokens. Never contact or alter the old vault/Pi.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "com.acasso01.rigatonistream.auth",
                       kSecAttrAccount as String: "supabase-session"] as CFDictionary)
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var starting = true
    @Published var busy = false
    @Published var notice = ""
    @Published private(set) var vault = ProviderVault()
    @Published private(set) var provider = Provider()
    @Published var settingsVisible = false
    @Published var libraryRevision = 0
    @Published var preferences = LibraryPreferences()
    let catalog = SessionCatalog()
    private var restored = false
    private var warmup: Task<Void, Never>?
    var providerReady: Bool { vault.selectedID != nil && (try? provider.baseURL()) != nil }
    var preferenceKey: String? { vault.selectedID.map { "ant-provider-" + $0.uuidString + "-library-v1" } }
    var pinKey: String? { vault.selectedID.map { "ant-provider-" + $0.uuidString + "-pins" } }
    func savePreferences() { preferences.write(key: preferenceKey); libraryRevision += 1 }
    func saveProgress(id: String, seconds: Double, duration: Double) {
        guard preferenceKey != nil, seconds.isFinite, duration.isFinite, seconds >= 10, duration > 0 else { return }
        if seconds >= duration - 20 { preferences.progress[id] = nil }
        else { preferences.progress[id] = MovieProgress(seconds: seconds, duration: duration, updated: Date().timeIntervalSince1970) }
        if preferences.progress.count > 500, let oldest = preferences.progress.min(by: { $0.value.updated < $1.value.updated })?.key { preferences.progress[oldest] = nil }
        preferences.write(key: preferenceKey)
    }
    func resetCatalog() {
        warmup?.cancel()
        EPGCache.shared.reset(); PlaylistStore.shared.reset()
        #if os(tvOS)
        TVFavorites.reset()
        #endif
        catalog.reset()
        preferences = LibraryPreferences.read(key: preferenceKey)
        libraryRevision += 1
    }
    func restore() async {
        guard !restored else { return }
        defer { starting = false }
        do {
            vault = try ProviderKeychain.read()
            restored = true
            ProviderKeychain.removeLegacySession()
            if let profile = vault.profiles.first(where: { $0.id == vault.selectedID }) ?? vault.profiles.first {
                vault.selectedID = profile.id; provider = profile.provider
                resetCatalog(); preload()
            }
        } catch { notice = error.localizedDescription }
    }
    func saveProvider(_ value: Provider, editing id: UUID?) async throws {
        guard restored else { throw AppFailure("Retry loading your saved providers before making changes.") }
        guard !busy else { throw AppFailure("Wait for the current provider operation to finish.") }
        busy = true; defer { busy = false }
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("Enter a provider name.") }
        _ = try value.baseURL()
        if !value.epgURL.isEmpty { _ = try Provider.validURL(value.epgURL) }
        try await ProviderAuthentication.validate(value)
        try Task.checkCancellation()
        var next = vault
        if let id, let index = next.profiles.firstIndex(where: { $0.id == id }) { next.profiles[index].provider = value; next.selectedID = id }
        else {
            guard next.profiles.count < 20 else { throw AppFailure("You can save up to 20 providers.") }
            let entry = ProviderProfile(provider: value); next.profiles.append(entry); next.selectedID = entry.id
        }
        try ProviderKeychain.write(next)
        vault = next; provider = value; restored = true
        resetCatalog(); preload(); notice = "Provider saved securely on this device."
    }
    func selectProvider(_ id: UUID) throws {
        guard !busy, let selected = vault.profiles.first(where: { $0.id == id }) else { return }
        var next = vault; next.selectedID = id
        try ProviderKeychain.write(next)
        vault = next; provider = selected.provider; resetCatalog(); preload(); notice = ""
    }
    func deleteProvider(_ id: UUID) throws {
        guard !busy else { return }
        var next = vault; next.profiles.removeAll { $0.id == id }
        if next.selectedID == id { next.selectedID = next.profiles.first?.id }
        if next.profiles.isEmpty { try ProviderKeychain.clear() } else { try ProviderKeychain.write(next) }
        let switched = next.selectedID != vault.selectedID
        vault = next
        let prefix = "ant-provider-" + id.uuidString
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) { UserDefaults.standard.removeObject(forKey: key) }
        if switched || next.profiles.isEmpty {
            provider = next.profiles.first(where: { $0.id == next.selectedID })?.provider ?? Provider()
            resetCatalog(); if providerReady { preload() }
        }
        notice = "Provider deleted from this device."
    }
    func refreshProvider() {
        resetCatalog(); if providerReady { preload() }
    }
    private func preload() {
        let source = provider; let revision = libraryRevision
        warmup = Task { @MainActor in
            // Load category indexes automatically, fetch large catalogs only when opened/searched.
            for kind in LibraryKind.allCases {
                guard !Task.isCancelled else { return }
                do {
                    let categories = try await catalog.categories(kind: kind, model: self)
                    if let first = categories.first { _ = try await catalog.items(kind: kind, category: first.id, model: self) }
                } catch { if !Task.isCancelled, revision == libraryRevision { notice = "Provider saved. Some catalogs could not be loaded; open the section to retry." } }
            }
            if source.kind == .xtream, !Task.isCancelled { _ = try? await DirectCatalog.rows(provider: source, action: "get_series_categories") }
        }
    }
    func resolve(_ item: CatalogItem) async throws -> CatalogItem {
        guard provider.kind == .m3u else { return item }
        let revision = libraryRevision
        let playlist = try await PlaylistStore.shared.load(provider)
        guard revision == libraryRevision else { throw CancellationError() }
        guard let fresh = playlist.items.first(where: { $0.id == item.id }) else { throw AppFailure("This title is no longer in the playlist.") }
        return fresh
    }
}
