import XCTest
import AVFoundation
#if os(tvOS)
@testable import RigatoniStreamTV
#else
@testable import RigatoniStream
#endif

// Run fixtures/start.sh and trust its one-day certificate in the simulator first.
// CI requires these tests; local runs without the fixture service skip them.
final class DirectConnectionTests: XCTestCase {
    private func fixture() async throws {
        do { _ = try await BoundedTransfer(limit: 1024, timeout: 2).fetch(URL(string: "http://localhost:8765/health")!) }
        catch {
            if ProcessInfo.processInfo.environment["ANT_REQUIRE_FIXTURES"] == "1" { throw error }
            throw XCTSkip("Start ios/fixtures/start.sh to run local transport/media tests.")
        }
    }
    @MainActor func testDirectHTTPAndHTTPSAuthenticationCatalogEPGAndPlaylist() async throws {
        try await fixture()
        for origin in ["http://localhost:8765", "https://localhost:8766"] {
            let provider = Provider(server: origin, username: "mock", password: "mock", name: "Fixture")
            try await ProviderAuthentication.validate(provider)
            var invalid = provider; invalid.password = "wrong"
            do { try await ProviderAuthentication.validate(invalid); XCTFail("Invalid credentials accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("Incorrect")) }
            for kind in LibraryKind.allCases {
                let rows = try await DirectCatalog.rows(provider: provider, action: kind.streamAction)
                XCTAssertEqual(rows.compactMap { CatalogItem.parse($0, kind: kind) }.count, 1)
            }
            let series = try await DirectCatalog.rows(provider: provider, action: "get_series")
            XCTAssertEqual(series.first?["name"] as? String, "Test series")
            let epg = EPGCache()
            let programs = await epg.programs(streamID: "1", provider: provider, scope: origin)
            XCTAssertEqual(programs.first?.title, "Test program")
            let playlist = Provider(server: origin + "/list.m3u", name: "Fixture M3U", kind: .m3u)
            let store = PlaylistStore()
            let parsed = try await store.load(playlist)
            XCTAssertEqual(parsed.items.count, 2)
            let guide = try await store.programs(streamID: parsed.items[0].id, provider: playlist)
            XCTAssertEqual(guide.first?.title, "Test program")
        }
    }
    func testHTTPRedirectAndResponseBounds() async throws {
        try await fixture()
        let transfer = BoundedTransfer(limit: 1024)
        _ = try await transfer.fetch(URL(string: "https://localhost:8766/redirect")!)
        XCTAssertEqual(transfer.resolvedURL?.scheme, "http")
        XCTAssertEqual(transfer.resolvedURL?.port, 8765)
        for path in ["oversized", "denied"] {
            do { _ = try await BoundedTransfer(limit: 1024).fetch(URL(string: "http://localhost:8765/" + path)!); XCTFail("Response should be rejected") }
            catch { XCTAssertFalse(error.localizedDescription.contains("localhost")) }
        }
    }
    @MainActor func testApplePlaybackReceivesVideoAndAdvancesForHTTPHLSAndHTTPSMovie() async throws {
        try await fixture()
        for address in ["http://localhost:8765/media/live.m3u8", "https://localhost:8766/media/movie.mp4"] {
            let player = ApplePlayback()
            player.open(URL(string: address)!, live: false, start: 0)
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline && !player.failed && player.player.currentTime().seconds < 2 {
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTAssertFalse(player.failed)
            XCTAssertGreaterThan(player.player.currentTime().seconds, 1)
            XCTAssertGreaterThan(player.player.currentItem?.presentationSize.width ?? 0, 0)
            player.stop()
        }
    }
}
