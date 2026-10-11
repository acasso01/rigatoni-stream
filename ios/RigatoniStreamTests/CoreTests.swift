import XCTest
@testable import RigatoniStream

final class CoreTests: XCTestCase {
    func testProviderURLsEncodeCredentialsAndKeepMovieContainer() throws {
        let provider = Provider(server: "http://provider.example.invalid:8080/base/", username: "user /?", password: "dummy/#%")
        let api = try provider.apiURL(action: "get_vod_streams", category: "72")
        let query = URLComponents(url: api, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "password" }?.value, "dummy/#%")
        XCTAssertEqual(query.first { $0.name == "category_id" }?.value, "72")
        let item = CatalogItem(id: "123", name: "Test", kind: .movies, fileExtension: "mkv", poster: nil)
        let stream = try provider.streamURL(item: item)
        XCTAssertEqual(stream.scheme, "http")
        XCTAssertTrue(stream.absoluteString.contains("user%20%2F%3F/dummy%2F%23%25/123.mkv"))
        XCTAssertNil(stream.query)
        XCTAssertNil(stream.fragment)
    }
    func testProviderRejectsEmbeddedCredentialsAndQuery() {
        for server in ["file:///etc/passwd", "http://user:pass@example.invalid", "http://example.invalid?password=dummy", "http://example.invalid#fragment"] {
            XCTAssertThrowsError(try Provider(server: server, username: "dummy", password: "dummy").baseURL())
        }
    }
    func testFlexibleCatalogTypesAndSafeContainer() {
        let movie = CatalogItem.parse(["stream_id": 45, "name": "Movie", "container_extension": "MKV", "stream_icon": "javascript:alert(1)"], kind: .movies)
        XCTAssertEqual(movie?.id, "45")
        XCTAssertEqual(movie?.fileExtension, "mkv")
        XCTAssertNil(movie?.poster)
        XCTAssertNil(CatalogItem.parse(["stream_id": "../private"], kind: .live))
        XCTAssertEqual(CatalogItem.parse(["stream_id": "1", "container_extension": "../../bad"], kind: .movies)?.fileExtension, "mp4")
    }
    @MainActor func testGatewayPreferenceMatchesWebsiteValidation() async throws {
        XCTAssertEqual(try AccountAPI.gatewayOrigin("https://homepi.test.ts.net:8443/"), "https://homepi.test.ts.net:8443")
        XCTAssertEqual(try AccountAPI.gatewayOrigin(""), "")
        for gateway in ["http://homepi.test.ts.net", "https://example.invalid", "https://homepi.test.ts.net/private", "https://user:pass@homepi.test.ts.net"] {
            XCTAssertThrowsError(try AccountAPI.gatewayOrigin(gateway))
        }
    }
    func testDirectHTTPPolicyOnlyAllowsConfiguredProviderHost() {
        let settings: [String: Any] = ["NSExceptionDomains": ["provider.example.invalid": ["NSExceptionAllowsInsecureHTTPLoads": true, "NSIncludesSubdomains": false]]]
        XCTAssertTrue(TransportPolicy.permits(URL(string: "http://provider.example.invalid:8080/movie/1.mkv")!, settings: settings))
        XCTAssertFalse(TransportPolicy.permits(URL(string: "http://other.example.invalid")!, settings: settings))
        XCTAssertFalse(TransportPolicy.permits(URL(string: "http://sub.provider.example.invalid")!, settings: settings))
        XCTAssertFalse(TransportPolicy.permits(URL(string: "http://provider.example.invalid")!, settings: [:]))
        XCTAssertTrue(TransportPolicy.permits(URL(string: "https://account.example.invalid")!, settings: settings))
    }
    func testConfiguredProviderBypassesGatewayInActualBuild() throws {
        let settings = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        let domains = settings?["NSExceptionDomains"] as? [String: Any]
        guard let host = domains?.keys.first else { throw XCTSkip("This build uses the HTTPS gateway for HTTP providers.") }
        let provider = Provider(server: "http://\(host)", username: "dummy", password: "dummy")
        XCTAssertTrue(provider.usesHTTP)
        XCTAssertFalse(provider.requiresGateway)
        let other = Provider(server: "http://other.example.invalid", username: "dummy", password: "dummy")
        XCTAssertTrue(other.requiresGateway)
    }

    func testPictureModesPreserveAspectAndCoverScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1500, height: 700)
        let video = CGSize(width: 1920, height: 1080)
        let fit = VideoDisplayMode.fit.frame(in: bounds, video: video)
        XCTAssertEqual(fit.height, 700, accuracy: 0.01)
        XCTAssertLessThan(fit.width, bounds.width)
        let fill = VideoDisplayMode.fill.frame(in: bounds, video: video)
        XCTAssertEqual(fill.width, 1500, accuracy: 0.01)
        XCTAssertGreaterThan(fill.height, bounds.height)
        let zoom = VideoDisplayMode.zoom.frame(in: bounds, video: video)
        XCTAssertEqual(zoom.width, fill.width * 1.25, accuracy: 0.01)
        for frame in [fit, fill, zoom] {
            XCTAssertEqual(frame.midX, bounds.midX, accuracy: 0.01)
            XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.01)
            XCTAssertEqual(frame.width / frame.height, video.width / video.height, accuracy: 0.001)
        }
        XCTAssertEqual(VideoDisplayMode.fit.frame(in: bounds, video: .zero), bounds)
        XCTAssertEqual(VideoDisplayMode.zoom.next, .fit)
        let portrait = CGRect(x: 0, y: 0, width: 400, height: 850)
        XCTAssertGreaterThanOrEqual(VideoDisplayMode.fill.frame(in: portrait, video: video).width, portrait.width)
    }
    func testSearchCombinesCategoriesWithoutDuplicateTitles() throws {
        let first = CatalogItem(id: "1", name: "Sports HD", kind: .live, fileExtension: "ts", poster: nil)
        let second = CatalogItem(id: "2", name: "News HD", kind: .live, fileExtension: "ts", poster: nil)
        var index = CatalogIndex()
        try index.append([first])
        try index.append([first, second])
        XCTAssertEqual(index.items.map(\.id), ["1", "2"])
        XCTAssertEqual(CatalogIndex.matches(index.items, query: " news ").map(\.id), ["2"])
        XCTAssertEqual(CatalogIndex.matches(index.items, query: "HD").count, 2)
        XCTAssertEqual(CatalogIndex.matches(index.items, query: "  ").count, 2)
    }
    func testSearchLimitPreservesLoadedResults() throws {
        var index = CatalogIndex()
        let batch = (0..<CatalogIndex.maximumItems).map {
            CatalogItem(id: String($0), name: "Title", kind: .movies, fileExtension: "mkv", poster: nil)
        }
        try index.append(batch)
        try index.append([batch[0]])
        XCTAssertThrowsError(try index.append([CatalogItem(id: "extra", name: "Extra", kind: .movies, fileExtension: "mkv", poster: nil)]))
        XCTAssertEqual(index.items.count, CatalogIndex.maximumItems)
    }

}
