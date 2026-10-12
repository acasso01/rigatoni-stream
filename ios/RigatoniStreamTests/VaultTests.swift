import XCTest
@testable import RigatoniStream

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
        for auth: Any in [1, "1", true] {
            let data = try JSONSerialization.data(withJSONObject: ["user_info": ["auth": auth, "status": "Active"]])
            XCTAssertNoThrow(try ProviderAuthentication.validateXtream(data))
        }
        for root: [String: Any] in [["user_info": ["auth": 0]], ["user_info": ["auth": 1, "status": "Expired"]], ["unexpected": true]] {
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
}
