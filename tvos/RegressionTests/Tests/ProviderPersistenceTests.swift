import XCTest
@testable import AntStreamsRegressionHost

@MainActor
final class ProviderPersistenceTests: XCTestCase {
    private func reset() throws {
        try ProviderKeychain.clear(service: ProviderKeychain.vaultService)
        ProviderKeychain.clear()
        SessionKeychain.clear()
        UserDefaults.standard.removeObject(forKey: AppModel.providerSourceKey)
        UserDefaults.standard.set("separate", forKey: "ant-library-mode")
    }
    private func profile() throws -> ProviderProfile {
        let profile = ProviderProfile(provider: Provider(server: "http://127.0.0.1:18765", username: "mock", password: "old-fixture", name: "Profile A"))
        try ProviderKeychain.write(ProviderVault(profiles: [profile], selectedID: profile.id), service: ProviderKeychain.vaultService)
        return profile
    }
    private func locals() throws {
        let a = try LocalProvider.make(id: "local-a", name: "Local A", provider: Provider(server: "http://127.0.0.1:18765", username: "mock", password: "local-a"), gateway: "")
        let b = try LocalProvider.make(id: "local-b", name: "Local B", provider: Provider(server: "http://127.0.0.1:18767", username: "mock", password: "local-b"), gateway: "")
        try ProviderKeychain.write(LocalProviderVault(activeID: a.id, providers: [a, b]))
    }

    func testSettingsEditOfSelectedProfileSurvivesFreshModelRestore() async throws {
        try reset(); defer { try? reset() }
        let original = try profile()
        try locals()
        let model = AppModel()
        await model.restore()
        XCTAssertEqual(model.provider.name, "Profile A")
        model.provider.server = "http://127.0.0.1:18767"
        model.provider.username = "edited-user"
        model.provider.password = "edited-fixture-password"
        model.providerName = "Edited profile"
        await model.saveSettings()
        let saved = try ProviderKeychain.read(service: ProviderKeychain.vaultService)
        XCTAssertEqual(saved.selectedID, original.id)
        XCTAssertEqual(saved.profiles.count, 1)
        XCTAssertEqual(saved.profiles[0].provider.password, "edited-fixture-password")
        XCTAssertEqual(try ProviderKeychain.read().providers[0].password, "local-a")
        let relaunched = AppModel()
        await relaunched.restore()
        XCTAssertEqual(relaunched.provider.server, "http://127.0.0.1:18767")
        XCTAssertEqual(relaunched.provider.username, "edited-user")
        XCTAssertEqual(relaunched.provider.password, "edited-fixture-password")
        XCTAssertEqual(relaunched.providerName, "Edited profile")
        XCTAssertNil(relaunched.activeLocalID)
    }

    func testChosenLocalWinsOverOldProfileAndCanBeEditedAndRelaunched() async throws {
        try reset(); defer { try? reset() }
        let selected = try profile()
        try locals()
        let model = AppModel()
        await model.restore()
        let profileScope = model.preferenceKey
        model.useLocalProvider("local-b")
        XCTAssertEqual(model.activeLocalID, "local-b")
        XCTAssertNotEqual(model.preferenceKey, profileScope)
        let relaunched = AppModel()
        await relaunched.restore()
        XCTAssertEqual(relaunched.activeLocalID, "local-b")
        XCTAssertEqual(relaunched.provider.password, "local-b")
        relaunched.provider.password = "edited-local-password"
        await relaunched.saveSettings()
        let edited = AppModel()
        await edited.restore()
        XCTAssertEqual(edited.provider.password, "edited-local-password")
        XCTAssertEqual(edited.activeLocalID, "local-b")
        try edited.selectProvider(selected.id)
        let switchedBack = AppModel()
        await switchedBack.restore()
        XCTAssertEqual(switchedBack.provider.name, "Profile A")
        XCTAssertNil(switchedBack.activeLocalID)
    }

    func testReloadDiscardsDraftButDoesNotSwitchProviderStore() async throws {
        try reset(); defer { try? reset() }
        _ = try profile(); try locals()
        let model = AppModel()
        await model.restore()
        model.useLocalProvider("local-b")
        model.provider.password = "unsaved-draft"
        try await model.reloadSettings()
        XCTAssertEqual(model.activeLocalID, "local-b")
        XCTAssertEqual(model.provider.password, "local-b")
    }

    func testFailedSaveLeavesPersistedProfileAndSelectionIntact() async throws {
        try reset(); defer { try? reset() }
        let selected = try profile()
        let model = AppModel()
        await model.restore()
        model.provider.server = "ftp://invalid.example"
        await model.saveSettings()
        let persisted = try ProviderKeychain.read(service: ProviderKeychain.vaultService)
        XCTAssertEqual(persisted.selectedID, selected.id)
        XCTAssertEqual(persisted.profiles[0].provider.server, selected.provider.server)
        let relaunched = AppModel()
        await relaunched.restore()
        XCTAssertEqual(relaunched.provider.server, selected.provider.server)
    }

    func testDeletingAnInactiveProfileDoesNotReplaceSelectedLocalProvider() async throws {
        try reset(); defer { try? reset() }
        let inactive = try profile(); try locals()
        let model = AppModel()
        await model.restore()
        model.useLocalProvider("local-b")
        try model.deleteProvider(inactive.id)
        XCTAssertEqual(model.activeLocalID, "local-b")
        XCTAssertEqual(model.provider.password, "local-b")
        let relaunched = AppModel()
        await relaunched.restore()
        XCTAssertEqual(relaunched.activeLocalID, "local-b")
    }

    func testDeleteSettingsDeletesTheSelectedProfileStore() async throws {
        try reset(); defer { try? reset() }
        _ = try profile(); try locals()
        let model = AppModel()
        await model.restore()
        await model.deleteSettings()
        XCTAssertTrue(try ProviderKeychain.read(service: ProviderKeychain.vaultService).profiles.isEmpty)
        XCTAssertEqual(try ProviderKeychain.read().providers.count, 2)
        XCTAssertEqual(model.activeLocalID, "local-a")
    }

    func testAccountSessionDoesNotOverwriteExplicitDeviceProfile() async throws {
        try reset(); defer { try? reset() }
        let selected = try profile()
        UserDefaults.standard.set("profiles", forKey: AppModel.providerSourceKey)
        ProviderAccountFixture.calls = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderAccountFixture.self]
        let account = AccountAPI(http: URLSession(configuration: config))
        try await account.signIn(email: "fixture@example.invalid", password: "fixture")
        let model = AppModel(account: account)
        await model.restore()
        XCTAssertTrue(model.signedIn)
        XCTAssertEqual(model.provider.server, selected.provider.server)
        XCTAssertEqual(ProviderAccountFixture.calls, ["/auth/v1/token"])
        try await model.reloadSettings(preferAccount: true)
        XCTAssertEqual(model.provider.server, "https://account-fixture.example.invalid")
        XCTAssertTrue(ProviderAccountFixture.calls.contains("/functions/v1/provider-vault"))
    }
}

final class ProviderAccountFixture: URLProtocol {
    static var calls: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.calls.append(path)
        let body: [String: Any]
        if path == "/auth/v1/token" {
            body = ["access_token": "test-access", "refresh_token": "test-refresh", "expires_in": 3600,
                    "user": ["id": "fixture-user", "email": "fixture@example.invalid"]]
        } else if path == "/auth/v1/user" {
            body = ["id": "fixture-user", "email": "fixture@example.invalid", "user_metadata": [:]]
        } else {
            body = ["server_url": "https://account-fixture.example.invalid", "username": "fixture", "password": "fixture", "label": "Account fixture"]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
