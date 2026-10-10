import XCTest
@testable import RigatoniStream

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
            client?.urlProtocol(self, didLoad: JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class VaultTests: XCTestCase {
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
        let keychain = try SessionKeychain.read()
        let tokens = try JSONEncoder().encode(keychain!)
        XCTAssertFalse(String(decoding: tokens, as: UTF8.self).contains("dummy-provider-password"))
        try await api.deleteSettings()
        let deleted = try await api.loadSettings()
        XCTAssertTrue(deleted.0.password.isEmpty)
        XCTAssertTrue(deleted.1.isEmpty)
        XCTAssertEqual(calls, 9)
    }
}
