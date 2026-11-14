import Foundation
import Combine
import Security

enum TransportPolicy {
    static func permits(_ url: URL, settings: [String: Any]? = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http" else { return false }
        // User-entered provider hosts cannot be enumerated at build time.
        if settings?["NSAllowsArbitraryLoads"] as? Bool == true { return true }
        guard let host = url.host?.lowercased(),
              let exceptions = settings?["NSExceptionDomains"] as? [String: Any],
              let rule = exceptions[host] as? [String: Any] else { return false }
        return rule["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true && rule["NSIncludesSubdomains"] as? Bool != true
    }
}

struct Provider: Equatable {
    var server = ""
    var username = ""
    var password = ""

    var requiresGateway: Bool {
        guard let url = try? baseURL() else { return false }
        return usesHTTP && !TransportPolicy.permits(url)
    }
    var usesHTTP: Bool { (try? baseURL().scheme?.lowercased()) == "http" }
    func baseURL() throws -> URL {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else { throw AppFailure("Enter a server URL, username and password.") }
        return url
    }
    func apiURL(action: String, category: String? = nil) throws -> URL {
        var parts = URLComponents(url: try baseURL().appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password), URLQueryItem(name: "action", value: action)]
        if let category { parts.queryItems?.append(URLQueryItem(name: "category_id", value: category)) }
        guard let url = parts.url else { throw AppFailure("Invalid provider URL.") }
        return url
    }
    func streamURL(item: CatalogItem) throws -> URL {
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
    static func parse(_ row: [String: Any], kind: LibraryKind) -> CatalogItem? {
        let id = row["stream_id"].map { String(describing: $0) } ?? ""
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        let ext = (row["container_extension"] as? String ?? (kind == .movies ? "mp4" : "ts")).lowercased()
        let allowed = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "m3u8"]
        let image = (row["stream_icon"] as? String).flatMap(URL.init(string:))
        return CatalogItem(id: id, name: row["name"] as? String ?? "Untitled", kind: kind,
                           fileExtension: allowed.contains(ext) ? ext : "mp4",
                           poster: ["https", "http"].contains(image?.scheme ?? "") ? image : nil,
                           categoryID: row["category_id"].map { String(describing: $0) } ?? "")
    }
}

struct AccountUser: Codable {
    let id: String
    let email: String?
    let user_metadata: Metadata?
    struct Metadata: Codable { let rigatoni_gateway_url: String? }
}
struct AuthSession: Codable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double?
    var expires_at: Double?
    let user: AccountUser
    var needsRefresh: Bool { (expires_at ?? 0) < Date().timeIntervalSince1970 + 90 }
}

// Account tokens only. Provider logins use ProviderKeychain (or the account vault when signed in).
enum SessionKeychain {
    private static let service = "com.acasso01.rigatonistream.auth"
    private static let account = "supabase-session"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read() throws -> AuthSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw AppFailure("Your saved sign-in could not be read. Sign in again.") }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }
    static func write(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        // Tokens include user metadata; no provider login is present in this payload.
        let code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw AppFailure("Could not save your sign-in securely.") }
        } else if code != errSecSuccess { throw AppFailure("Could not update your saved sign-in.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

@MainActor
final class AccountAPI {
    private let root = URL(string: "https://edjejdftwjiasfhpffmc.supabase.co")!
    private let publicKey = "sb_publishable_w3-KHDqTcBEsLTRNwdRpgg_U9xugdH2"
    private(set) var session: AuthSession?
    private let http: URLSession
    init(http: URLSession? = nil) {
        if let http { self.http = http; return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.http = URLSession(configuration: config)
    }
    private func send(path: String, method: String = "GET", body: [String: Any]? = nil, authenticated: Bool = true) async throws -> Data {
        if authenticated { try await refreshIfNeeded() }
        var request = URLRequest(url: root.appendingPathComponent(path.components(separatedBy: "?")[0]))
        if let query = path.split(separator: "?", maxSplits: 1).last, path.contains("?") {
            var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            parts.percentEncodedQuery = String(query); request.url = parts.url
        }
        request.httpMethod = method
        request.setValue(publicKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let session else { throw AppFailure("Sign in to sync provider settings with your Ant Streams account. Direct providers work without an account.") }
            request.setValue("Bearer \(session.access_token)", forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data, response: URLResponse
        do { (data, response) = try await http.data(for: request) }
        catch { throw AppFailure("Could not reach your account. Check your connection and retry.") }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 401 { throw AppFailure("Your sign-in was rejected or expired. Sign in again.") }
            throw AppFailure("Account request failed. Check your sign-in details or retry shortly.")
        }
        return data
    }
    private func accept(_ data: Data) throws {
        var next = try JSONDecoder().decode(AuthSession.self, from: data)
        if next.expires_at == nil { next.expires_at = Date().timeIntervalSince1970 + (next.expires_in ?? 3600) }
        try SessionKeychain.write(next); session = next
    }
    func restore() async throws -> Bool {
        session = try SessionKeychain.read()
        guard session != nil else { return false }
        try await refreshIfNeeded()
        return true
    }
    private func refreshIfNeeded() async throws {
        guard let current = session, current.needsRefresh else { return }
        let data = try await send(path: "auth/v1/token?grant_type=refresh_token", method: "POST", body: ["refresh_token": current.refresh_token], authenticated: false)
        try accept(data)
    }
    func signIn(email: String, password: String) async throws {
        try accept(await send(path: "auth/v1/token?grant_type=password", method: "POST", body: ["email": email, "password": password], authenticated: false))
    }
    func signUp(email: String, password: String) async throws -> Bool {
        let data = try await send(path: "auth/v1/signup", method: "POST", body: ["email": email, "password": password], authenticated: false)
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] != nil { try accept(data); return true }
        return false
    }
    func recover(email: String) async throws {
        _ = try await send(path: "auth/v1/recover", method: "POST", body: ["email": email], authenticated: false)
    }
    func accessToken() async throws -> String {
        try await refreshIfNeeded()
        guard let session else { throw AppFailure(GatewayAccess.signInMessage) }
        return session.access_token
    }
    func signOut() async {
        _ = try? await send(path: "auth/v1/logout", method: "POST")
        session = nil; SessionKeychain.clear()
    }
    func loadSettings() async throws -> (provider: Provider, gateway: String, name: String) {
        let user = try JSONDecoder().decode(AccountUser.self, from: await send(path: "auth/v1/user"))
        let data = try await send(path: "functions/v1/provider-vault")
        let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let provider = Provider(server: row["server_url"] as? String ?? "", username: row["username"] as? String ?? "", password: row["password"] as? String ?? "")
        return (provider, user.user_metadata?.rigatoni_gateway_url ?? "", row["label"] as? String ?? "")
    }
    func save(provider: Provider, gateway: String, name: String = "") async throws {
        let url = try provider.baseURL()
        let origin = try Self.gatewayOrigin(gateway)
        var body: [String: Any] = ["server_url": url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "username": provider.username, "password": provider.password]
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { body["label"] = String(label.prefix(60)) }
        let data = try await send(path: "functions/v1/provider-vault", method: "POST", body: body)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard result?["saved"] as? Bool == true else { throw AppFailure("The vault did not confirm saving your provider.") }
        do { _ = try await send(path: "auth/v1/user", method: "PUT", body: ["data": ["rigatoni_gateway_url": origin.isEmpty ? NSNull() : origin as Any]]) }
        catch { throw AppFailure("Provider saved, but the gateway preference could not be saved. Retry Save settings.") }
    }
    nonisolated static func gatewayOrigin(_ value: String) throws -> String {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.host?.hasSuffix(".ts.net") == true,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path) else { throw AppFailure("Enter an HTTPS Tailscale gateway URL, or leave it blank. Native playback connects directly to your provider.") }
        var origin = parts; origin.path = ""
        return origin.string ?? ""
    }
    func deleteSettings() async throws {
        let data = try await send(path: "functions/v1/provider-vault", method: "DELETE")
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard result?["deleted"] as? Bool == true else { throw AppFailure("The vault did not confirm deletion.") }
        do { _ = try await send(path: "auth/v1/user", method: "PUT", body: ["data": ["rigatoni_gateway_url": NSNull()]]) }
        catch { throw AppFailure("Provider deleted. The gateway preference could not be cleared; retry deletion.") }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var signedIn = false
    @Published var starting = true
    @Published var busy = false
    @Published var notice = ""
    @Published var provider = Provider()
    @Published var providerName = ""
    @Published var gateway = ""
    @Published var settingsVisible = false
    @Published var libraryRevision = 0
    @Published var localProviders: [LocalProvider] = []
    @Published var activeLocalID: String?
    let account = AccountAPI()
    let catalog = SessionCatalog()
    @Published var preferences = LibraryPreferences()
    /// True until a provider is saved on device or an account session exists.
    var needsProviderSetup: Bool { !signedIn && !providerReady }
    /// Signed-in favorites stay on the account id. Otherwise each device provider has its own scope.
    var libraryAccountID: String? {
        if let id = account.session?.user.id { return id }
        if let activeLocalID { return "device-\(activeLocalID)" }
        if providerReady { return "device" }
        return nil
    }
    var preferenceKey: String? {
        guard let id = libraryAccountID, let host = try? provider.baseURL().host else { return nil }
        return CategoryPins.key(accountID: id, host: host) + "-library-v1"
    }
    func savePreferences() {
        preferences.write(key: preferenceKey); libraryRevision += 1
    }
    func saveProgress(id: String, seconds: Double, duration: Double) {
        guard preferenceKey != nil, seconds.isFinite, duration.isFinite, seconds >= 10, duration > 0 else { return }
        if seconds >= duration - 20 { preferences.progress[id] = nil }
        else { preferences.progress[id] = MovieProgress(seconds: seconds, duration: duration, updated: Date().timeIntervalSince1970) }
        // Bound preferences without saving any provider URLs or login details.
        if preferences.progress.count > 500 {
            let oldest = preferences.progress.min { $0.value.updated < $1.value.updated }?.key
            if let oldest { preferences.progress[oldest] = nil }
        }
        preferences.write(key: preferenceKey)
    }
    var gatewayConnection: [String: Any]?
    var gatewayConnectTask: Task<[String: Any], Error>?
    var gatewayMovieCatalog: [String: Any]?
    var gatewayMedia: [LibraryKind: [String: String]] = [:]
    func resetGateway() {
        EPGCache.shared.reset()
        #if os(tvOS)
        TVFavorites.reset()
        #endif
        catalog.reset()
        preferences = LibraryPreferences.read(key: preferenceKey)
        gatewayConnectTask?.cancel(); gatewayConnectTask = nil; gatewayConnection = nil
        gatewayMovieCatalog = nil; gatewayMedia = [:]
    }
    var providerReady: Bool { (try? provider.baseURL()) != nil }
    func restore() async {
        defer { starting = false }
        do {
            let store = try ProviderKeychain.read()
            localProviders = store.providers
        } catch { notice = error.localizedDescription }
        do {
            signedIn = try await account.restore()
            if signedIn { try await reloadSettings() }
            else { activateLocalProvider(); resetGateway() }
        } catch {
            notice = error.localizedDescription
            if !providerReady { activateLocalProvider() }
            resetGateway()
            settingsVisible = signedIn && !providerReady
        }
    }
    func reloadSettings() async throws {
        if account.session != nil {
            let result = try await account.loadSettings()
            let vaultReady = (try? result.provider.baseURL()) != nil
            if vaultReady {
                provider = result.provider
                gateway = result.gateway
                providerName = result.name
                activeLocalID = nil
            } else if !providerReady {
                activateLocalProvider()
            }
            resetGateway(); libraryRevision += 1
            if vaultReady { notice = "Provider and gateway loaded from your account." }
            else if providerReady { notice = "No provider in your account. Using the provider saved on this device." }
            else { notice = "Save your provider to start watching." }
            settingsVisible = !providerReady
        } else {
            activateLocalProvider()
            resetGateway(); libraryRevision += 1
            notice = providerReady ? "Provider loaded from this device." : "Save your provider to start watching."
            settingsVisible = !providerReady
        }
    }
    func saveSettings() async {
        busy = true; defer { busy = false }
        do {
            if account.session != nil {
                try await account.save(provider: provider, gateway: gateway, name: providerName)
                gateway = try AccountAPI.gatewayOrigin(gateway)
                if let id = activeLocalID {
                    let record = try LocalProvider.make(id: id, name: providerName, provider: provider, gateway: gateway)
                    try storeLocal(record, makeActive: true)
                    applyLocal(record)
                }
                resetGateway(); libraryRevision += 1
                notice = "Settings saved securely. No provider connection required."
            } else {
                let record = try LocalProvider.make(id: activeLocalID ?? UUID().uuidString, name: providerName, provider: provider, gateway: gateway)
                try storeLocal(record, makeActive: true)
                applyLocal(record)
                resetGateway(); libraryRevision += 1
                notice = localSaveNotice(for: provider)
            }
        } catch { notice = error.localizedDescription }
    }
    func deleteSettings() async {
        busy = true; defer { busy = false }
        do {
            if account.session != nil {
                try await account.deleteSettings()
                provider = Provider(); providerName = ""; gateway = ""
                activeLocalID = nil
                resetGateway(); libraryRevision += 1
                notice = "Saved provider and gateway deleted."
            } else if let id = activeLocalID {
                await removeLocalProvider(id)
            } else {
                notice = "No provider is saved on this device."
            }
        } catch { notice = error.localizedDescription }
    }
    func signOut() async {
        busy = true; defer { busy = false }
        // Drop the in-memory account provider first. A provider saved only on
        // this device is restored afterwards and is not deleted.
        signedIn = false
        provider = Provider(); providerName = ""; gateway = ""; activeLocalID = nil
        await account.signOut()
        activateLocalProvider()
        resetGateway(); libraryRevision += 1; settingsVisible = false
        notice = providerReady ? "Signed out. Using the provider saved on this device." : "Signed out."
    }

    @discardableResult
    func addLocalProvider(name: String, provider: Provider, gateway: String) async -> Bool {
        busy = true; defer { busy = false }
        do {
            let record = try LocalProvider.make(id: UUID().uuidString, name: name, provider: provider, gateway: gateway)
            let becomesActive = account.session == nil
            try storeLocal(record, makeActive: becomesActive)
            if becomesActive {
                applyLocal(record)
                resetGateway(); libraryRevision += 1
                notice = localSaveNotice(for: provider)
            } else {
                notice = "Provider saved on this device. It is used after you sign out."
            }
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func useLocalProvider(_ id: String) {
        guard account.session == nil else {
            notice = "Sign out to switch to a provider saved only on this device."
            return
        }
        guard let record = localProviders.first(where: { $0.id == id }) else { return }
        do {
            try storeLocal(record, makeActive: true)
            applyLocal(record)
            resetGateway(); libraryRevision += 1
            notice = "Using \(record.displayName)."
        } catch { notice = error.localizedDescription }
    }

    func removeLocalProvider(_ id: String) async {
        let wasBusy = busy
        if !wasBusy { busy = true }
        defer { if !wasBusy { busy = false } }
        do {
            var store = try ProviderKeychain.read()
            store.providers.removeAll { $0.id == id }
            if store.activeID == id { store.activeID = store.providers.first?.id }
            if store.providers.isEmpty {
                ProviderKeychain.clear()
                localProviders = []
            } else {
                try ProviderKeychain.write(store)
                localProviders = store.providers
            }
            if account.session == nil, activeLocalID == id {
                if let nextID = store.activeID, let next = store.providers.first(where: { $0.id == nextID }) {
                    applyLocal(next)
                } else {
                    provider = Provider(); providerName = ""; gateway = ""; activeLocalID = nil
                }
                resetGateway(); libraryRevision += 1
            }
            notice = "Provider removed from this device."
        } catch { notice = error.localizedDescription }
    }

    private func localSaveNotice(for provider: Provider) -> String {
        provider.requiresGateway
            ? "Provider saved on this device. \(GatewayAccess.signInMessage)"
            : "Provider saved on this device. No account required."
    }

    private func activateLocalProvider() {
        let store = (try? ProviderKeychain.read()) ?? LocalProviderVault()
        localProviders = store.providers
        guard let record = store.providers.first(where: { $0.id == store.activeID }) ?? store.providers.first else {
            activeLocalID = nil
            return
        }
        if store.activeID != record.id {
            var fixed = store
            fixed.activeID = record.id
            try? ProviderKeychain.write(fixed)
        }
        applyLocal(record)
    }

    private func applyLocal(_ record: LocalProvider) {
        provider = Provider(server: record.server, username: record.username, password: record.password)
        providerName = record.name
        gateway = record.gateway
        activeLocalID = record.id
    }

    private func storeLocal(_ record: LocalProvider, makeActive: Bool) throws {
        var store = try ProviderKeychain.read()
        if let index = store.providers.firstIndex(where: { $0.id == record.id }) {
            store.providers[index] = record
        } else {
            guard store.providers.count < LocalProviderVault.limit else {
                throw AppFailure("You can save up to \(LocalProviderVault.limit) providers on this device.")
            }
            store.providers.append(record)
        }
        if makeActive || store.activeID == nil { store.activeID = record.id }
        try ProviderKeychain.write(store)
        localProviders = store.providers
        if makeActive { activeLocalID = record.id }
    }
}


extension AppModel {
    private func gatewayRequest(_ url: URL, method: String = "GET") async throws -> [String: Any] {
        let token = try await account.accessToken()
        let data = try await BoundedTransfer(limit: 32 * 1024 * 1024).fetch(url, headers: ["Authorization": "Bearer \(token)"], method: method)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["error"] == nil else { throw AppFailure("The gateway request failed. Check Tailscale, save provider settings and retry.") }
        return result
    }
    private func connectGateway() async throws -> [String: Any] {
        guard account.session != nil else { throw AppFailure(GatewayAccess.signInMessage) }
        if let gatewayConnection { return gatewayConnection }
        if let gatewayConnectTask { return try await gatewayConnectTask.value }
        guard let origin = URL(string: try AccountAPI.gatewayOrigin(gateway)), !gateway.isEmpty else { throw AppFailure("This HTTP provider needs your saved HTTPS gateway. Open settings and save the gateway URL.") }
        let next = Task { try await self.gatewayRequest(origin.appendingPathComponent("api/connect"), method: "POST") }
        gatewayConnectTask = next
        defer { gatewayConnectTask = nil }
        let result = try await next.value
        gatewayConnection = result
        gatewayMedia[.live] = result["streams"] as? [String: String] ?? [:]
        return result
    }
    private func movieURL(_ connection: [String: Any]) throws -> URL {
        guard let path = connection["movies_path"] as? String,
              path.range(of: "^/api/movies/[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let url = URL(string: try AccountAPI.gatewayOrigin(gateway) + path) else { throw AppFailure("Update the Pi gateway to load movies.") }
        return url
    }
    func gatewayRows(kind: LibraryKind, category: String?) async throws -> [[String: Any]] {
        let connection = try await connectGateway()
        if kind == .live {
            if let category { return (connection["channels"] as? [[String: Any]] ?? []).filter { String(describing: $0["category_id"] ?? "") == category } }
            return connection["categories"] as? [[String: Any]] ?? []
        }
        let base = try movieURL(connection)
        if category == nil {
            if gatewayMovieCatalog == nil { gatewayMovieCatalog = try await gatewayRequest(base) }
            return gatewayMovieCatalog?["categories"] as? [[String: Any]] ?? []
        }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "category_id", value: category)]
        let result = try await gatewayRequest(parts.url!)
        gatewayMedia[.movies] = result["streams"] as? [String: String] ?? [:]
        return result["movies"] as? [[String: Any]] ?? []
    }
    func gatewayPlaybackURL(id: String, kind: LibraryKind) throws -> URL {
        guard account.session != nil else { throw AppFailure(GatewayAccess.signInMessage) }
        guard let path = gatewayMedia[kind]?[id],
              path.range(of: "^/media/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let url = URL(string: try AccountAPI.gatewayOrigin(gateway) + path) else { throw AppFailure("Reconnect the provider to refresh this stream.") }
        return url
    }
}
