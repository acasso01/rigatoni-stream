import XCTest
#if os(tvOS)
@testable import RigatoniStreamTV
#else
@testable import RigatoniStream
#endif

final class AccountProtocol: URLProtocol {
    static var respond: ((URLRequest, Data?) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                body = data
            }
            let response = try Self.respond!(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class VaultTests: XCTestCase {
    func testKeychainMultipleProvidersReloadEditSelectDelete() throws {
        let service = "ant-streams-test-" + UUID().uuidString
        defer { try? ProviderKeychain.clear(service: service) }
        let first = ProviderProfile(provider: Provider(server: "http://provider.example.invalid:8080", username: "mock-user", password: "mock-password", name: "Test"))
        let second = ProviderProfile(provider: Provider(server: "https://playlist.example.invalid/list?token=mock", name: "Playlist", kind: .m3u))
        var vault = ProviderVault(profiles: [first, second], selectedID: first.id)
        try ProviderKeychain.write(vault, service: service)
        XCTAssertEqual(try ProviderKeychain.read(service: service), vault)
        vault.profiles[0].provider.password = "edited-mock-password"
        vault.selectedID = second.id
        try ProviderKeychain.write(vault, service: service)
        XCTAssertEqual(try ProviderKeychain.read(service: service), vault)
        vault.profiles.removeFirst()
        try ProviderKeychain.write(vault, service: service)
        XCTAssertEqual(try ProviderKeychain.read(service: service).profiles.map(\.id), [second.id])
        try ProviderKeychain.clear(service: service)
        XCTAssertTrue(try ProviderKeychain.read(service: service).profiles.isEmpty)
        XCTAssertNil(UserDefaults.standard.object(forKey: service))
    }
    func testXtreamAuthenticationResponses() throws {
        for auth in [1, "1", true] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["user_info": ["auth": auth, "status": "Active"]])
            XCTAssertNoThrow(try ProviderAuthentication.validateXtream(data))
        }
        for root in [["user_info": ["auth": 0]], ["user_info": ["auth": 1, "status": "Expired"]], ["unexpected": true]] as [[String: Any]] {
            XCTAssertThrowsError(try ProviderAuthentication.validateXtream(JSONSerialization.data(withJSONObject: root)))
        }
        XCTAssertThrowsError(try ProviderAuthentication.validateXtream(Data("<html>error</html>".utf8)))
    }
    func testM3UCategoriesRelativeURLsPortsAndEPG() throws {
        let fixture = """
        #EXTM3U x-tvg-url="guide.xml"
        #EXTINF:-1 tvg-id="sports" group-title="US, Sports" tvg-logo="logo.png",Sports HD
        live/channel.m3u8
        #EXTINF:3600 group-title="Movies",A movie
        http://media.example.invalid:25461/movie.mkv?token=mock
        #EXTINF:-1 group-title="Duplicate",Duplicate
        live/channel.m3u8
        #EXTINF:-1,Unsupported
        file:///private/file
        """
        let catalog = try M3UParser.parse(Data(fixture.utf8), baseURL: URL(string: "https://example.invalid:8000/base/list.m3u")!)
        XCTAssertEqual(catalog.items.count, 2)
        XCTAssertEqual(catalog.categories[.live]?.first?.name, "US, Sports")
        XCTAssertEqual(catalog.items[0].playbackURL?.absoluteString, "https://example.invalid:8000/base/live/channel.m3u8")
        XCTAssertEqual(catalog.items[1].kind, .movies)
        XCTAssertEqual(catalog.items[1].playbackURL?.port, 25461)
        XCTAssertEqual(catalog.epgIDs[catalog.items[0].id], "sports")
        XCTAssertEqual(catalog.epgURL?.absoluteString, "https://example.invalid:8000/base/guide.xml")
        XCTAssertEqual(catalog.skipped, 1)
        XCTAssertEqual(try Provider(server: "https://example.invalid/list?token=mock", kind: .m3u).streamURL(item: catalog.items[1]), catalog.items[1].playbackURL)
    }
    func testM3URejectsUnsupportedAndSingleStreamManifests() {
        for text in ["not a playlist", "#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts", "#EXTM3U\n#EXTINF:-1,Unsupported\nftp://example.invalid/file"] {
            XCTAssertThrowsError(try M3UParser.parse(Data(text.utf8), baseURL: URL(string: "https://example.invalid/list")!))
        }
    }
    func testXMLTVOffsetsAndEntityRejection() throws {
        let now = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
        let xml = """
        <tv><programme channel="sports" start="20260101010000 +0100" stop="20260101020000 +0100"><title>Sports &amp; news</title><desc>Live</desc></programme></tv>
        """
        let entries = try XMLTVParser.parse(Data(xml.utf8), now: now)
        XCTAssertEqual(entries["sports"]?.first?.title, "Sports & news")
        XCTAssertEqual(entries["sports"]?.first?.start, now)
        XCTAssertThrowsError(try XMLTVParser.parse(Data("<!DOCTYPE tv [<!ENTITY bad SYSTEM 'file:///etc/passwd'>]><tv/>".utf8)))
    }
    func testPlaybackRoutingDoesNotAssumeAVPlayerSupportsMatroskaOrTS() {
        XCTAssertTrue(PlaybackRouting.usesApple(extension: "m3u8", preference: "auto"))
        XCTAssertTrue(PlaybackRouting.usesApple(extension: "mp4", preference: "auto"))
        XCTAssertFalse(PlaybackRouting.usesApple(extension: "mkv", preference: "auto"))
        XCTAssertFalse(PlaybackRouting.usesApple(extension: "ts", preference: "auto"))
        XCTAssertFalse(PlaybackRouting.usesApple(extension: "m3u8", preference: "vlc"))
    }

    @MainActor func testSecureSaveReloadDeleteWithoutProviderConnection() async throws {
        var saved: [String: Any] = ["saved": false]
        var gateway: Any = NSNull()
        var calls = 0
        AccountProtocol.respond = { request, body in
            // A settings operation must only reach Supabase, never a provider or gateway.
            XCTAssertEqual(request.url?.host, "edjejdftwjiasfhpffmc.supabase.co")
            calls += 1
            let payload = try body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if request.url?.path == "/auth/v1/token" {
                return ["access_token": "dummy-test-access", "refresh_token": "dummy-test-refresh", "expires_in": 3600, "user": ["id": "test-user", "email": "test@example.invalid"]]
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-test-access")
            if request.url?.path == "/auth/v1/user" {
                if request.httpMethod == "PUT" { gateway = (payload["data"] as? [String: Any])?["rigatoni_gateway_url"] ?? NSNull() }
                return ["id": "test-user", "email": "test@example.invalid", "user_metadata": ["rigatoni_gateway_url": gateway]]
            }
            XCTAssertEqual(request.url?.path, "/functions/v1/provider-vault")
            if request.httpMethod == "POST" { saved = payload; saved["saved"] = true; return ["saved": true] }
            if request.httpMethod == "DELETE" { saved = ["saved": false]; return ["deleted": true] }
            return saved
        }
        defer { AccountProtocol.respond = nil; SessionKeychain.clear() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountProtocol.self]; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = AccountAPI(http: session)
        try await api.signIn(email: "test@example.invalid", password: "dummy-account-password")
        let provider = Provider(server: "http://provider.example.invalid:8080", username: "dummy-user", password: "dummy-provider-password")
        try await api.save(provider: provider, gateway: "https://homepi.test.ts.net:8443/")
        let reloaded = try await api.loadSettings()
        XCTAssertEqual(reloaded.0, provider)
        XCTAssertEqual(reloaded.1, "https://homepi.test.ts.net:8443")
        XCTAssertTrue(reloaded.name.isEmpty)
        let keychain = try SessionKeychain.read()
        let tokens = try JSONEncoder().encode(keychain!)
        XCTAssertFalse(String(decoding: tokens, as: UTF8.self).contains("dummy-provider-password"))
        try await api.deleteSettings()
        let deleted = try await api.loadSettings()
        XCTAssertTrue(deleted.0.password.isEmpty)
        XCTAssertTrue(deleted.1.isEmpty)
        XCTAssertEqual(calls, 9)
    }

    @MainActor func testLocalProviderKeychainWithoutAccount() async throws {
        ProviderKeychain.clear()
        defer { ProviderKeychain.clear(); SessionKeychain.clear() }
        let model = AppModel()
        model.provider = Provider(server: "https://provider.example.invalid", username: "dummy-user", password: "")
        await model.saveSettings()
        XCTAssertTrue(try ProviderKeychain.read().providers.isEmpty)
        XCTAssertFalse(model.signedIn)

        model.provider = Provider(server: "http://provider.example.invalid", username: "dummy-user", password: "dummy-provider-password")
        model.providerName = "Living room"
        model.gateway = "https://homepi.test.ts.net:8443/"
        await model.saveSettings()
        XCTAssertTrue(model.providerReady)
        XCTAssertFalse(model.signedIn)
        XCTAssertTrue(model.notice.contains("this device"))
        if model.provider.requiresGateway {
            XCTAssertTrue(model.notice.contains("Sign in"))
        } else {
            XCTAssertTrue(model.notice.contains("No account required"))
        }
        var store = try ProviderKeychain.read()
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers[0].name, "Living room")
        XCTAssertEqual(store.providers[0].password, "dummy-provider-password")
        XCTAssertEqual(store.providers[0].gateway, "https://homepi.test.ts.net:8443")
        XCTAssertEqual(store.activeID, model.activeLocalID)
        try assertProviderKeychainIsDeviceOnly()
        assertDefaultsOmit("dummy-provider-password")

        model.provider.username = "dummy-user-edited"
        await model.saveSettings()
        store = try ProviderKeychain.read()
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers[0].username, "dummy-user-edited")
        try assertProviderKeychainIsDeviceOnly()

        let added = await model.addLocalProvider(
            name: "Cabin",
            provider: Provider(server: "https://other.example.invalid", username: "other-user", password: "other-dummy-password"),
            gateway: ""
        )
        XCTAssertTrue(added)
        store = try ProviderKeychain.read()
        XCTAssertEqual(store.providers.count, 2)
        XCTAssertEqual(store.activeID, model.activeLocalID)
        XCTAssertEqual(model.provider.username, "other-user")
        XCTAssertFalse(model.provider.requiresGateway)
        let key = try XCTUnwrap(model.preferenceKey)
        XCTAssertFalse(key.contains("other-dummy-password"))
        XCTAssertFalse(key.contains("dummy-provider-password"))
        XCTAssertFalse(key.contains("other.example.invalid"))
        XCTAssertNil(model.account.session)
        do {
            _ = try await model.gatewayRows(kind: .live, category: nil)
            XCTFail("Gateway playback should require an account")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in"))
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("direct"))
        }
        // The HTTPS provider does not use the gateway, so this call is only to
        // prove the guard text. Switch back to the HTTP provider first.
        let httpID = try XCTUnwrap(store.providers.first { $0.server.hasPrefix("http://") }?.id)
        model.useLocalProvider(httpID)
        XCTAssertTrue(model.providerReady)
        do {
            _ = try await model.gatewayRows(kind: .live, category: nil)
            XCTFail("Gateway playback should require an account")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in"))
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("direct"))
        }

        await model.removeLocalProvider(httpID)
        store = try ProviderKeychain.read()
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers[0].name, "Cabin")
        await model.signOut()
        XCTAssertFalse(model.signedIn)
        XCTAssertTrue(model.providerReady)
        XCTAssertEqual(try ProviderKeychain.read().providers.count, 1)
        XCTAssertNil(try SessionKeychain.read())
        assertDefaultsOmit("dummy-provider-password")
        assertDefaultsOmit("other-dummy-password")
    }

    private func assertProviderKeychainIsDeviceOnly() throws {
        let attrs = try XCTUnwrap(ProviderKeychain.attributes())
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, ProviderKeychain.service)
        if let itemClass = attrs[kSecClass as String] as? String {
            XCTAssertEqual(itemClass, kSecClassGenericPassword as String)
        }
    }

    private func assertDefaultsOmit(_ secret: String) {
        let prefs = UserDefaults.standard.dictionaryRepresentation()
        XCTAssertFalse(prefs.keys.contains { $0.contains(secret) })
        XCTAssertFalse(prefs.values.contains { String(describing: $0).contains(secret) })
    }
}
