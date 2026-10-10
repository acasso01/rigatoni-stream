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
    @MainActor func testGatewayPreferenceMatchesWebsiteValidation() throws {
        XCTAssertEqual(try AccountAPI.gatewayOrigin("https://homepi.test.ts.net:8443/"), "https://homepi.test.ts.net:8443")
        XCTAssertEqual(try AccountAPI.gatewayOrigin(""), "")
        for gateway in ["http://homepi.test.ts.net", "https://example.invalid", "https://homepi.test.ts.net/private", "https://user:pass@homepi.test.ts.net"] {
            XCTAssertThrowsError(try AccountAPI.gatewayOrigin(gateway))
        }
    }
}
