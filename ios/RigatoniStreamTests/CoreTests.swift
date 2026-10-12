import XCTest
import UIKit
@testable import RigatoniStream

final class CoreTests: XCTestCase {
    @MainActor func testSeriesURLPreservesBasePathAndEncodesCredentials() throws {
        var provider = Provider()
        provider.server = "https://provider.example.invalid/base%20path"
        provider.username = "test/user"
        provider.password = "test?#pass"
        let url = try SeriesStore.seriesStreamURL(provider: provider, episodeID: "42", ext: "mkv")
        XCTAssertEqual(url.host, "provider.example.invalid")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/base%20path/series/test%2Fuser/test%3F%23pass/42.mkv")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }
    @MainActor func testSeriesDetailsInferSeasonsSortEpisodesAndValidateFormats() {
        let detail = SeriesStore.parseDetail(["episodes": ["2": [
            ["id": "12", "episode_num": 2, "title": "Second", "container_extension": "mkv"],
            ["id": 11, "episode_num": 1, "title": "First", "info": ["container_extension": "m4v"]],
            ["id": "13", "episode_num": 3, "container_extension": "../../invalid"],
            ["id": "12", "episode_num": 4],
            ["id": "bad/id", "episode_num": 5]
        ]]])
        XCTAssertEqual(detail.seasons.map(\.number), [2])
        XCTAssertEqual(detail.episodes[2]?.map(\.id), ["11", "12", "13"])
        XCTAssertEqual(detail.episodes[2]?.map(\.ext), ["m4v", "mkv", "mp4"])
    }
    @MainActor func testEpisodeProgressDoesNotCollideWithMovieProgress() {
        let episode = SeriesEpisode(id: "42", number: 1, title: "Pilot", ext: "mp4")
        var preferences = LibraryPreferences()
        preferences.progress["42"] = MovieProgress(seconds: 125, duration: 7200, updated: 1)
        preferences.progress[episode.progressID] = MovieProgress(seconds: 300, duration: 1800, updated: 2)
        XCTAssertEqual(preferences.progress["42"]?.seconds, 125)
        XCTAssertEqual(preferences.progress[episode.progressID]?.seconds, 300)
    }
    func testHiddenContentIsRemovedFromUnifiedSearchAndCanBeRestored() {
        let movie = CatalogItem(id: "7", name: "Sports movie", kind: .movies, fileExtension: "mkv", poster: nil, categoryID: "2")
        let channel = CatalogItem(id: "7", name: "Sports channel", kind: .live, fileExtension: "ts", poster: nil, categoryID: "1")
        var preferences = LibraryPreferences()
        preferences.setCategory("2", kind: .movies, visible: false)
        preferences.hiddenChannels.insert("7")
        XCTAssertTrue(UnifiedSearch.matches([movie, channel].filter(preferences.visible), query: "sports", filter: "all").isEmpty)
        preferences.setCategory("2", kind: .movies, visible: true)
        XCTAssertEqual([movie, channel].filter(preferences.visible).map(\.kind), [.movies])
        preferences.hiddenChannels.remove("7")
        XCTAssertEqual([movie, channel].filter(preferences.visible).count, 2)
    }
    func testLibraryPreferencesPersistProgressWithoutCredentialsAndKeepNamespacesSeparate() {
        let key = "rigatoni-test-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: key) }
        var preferences = LibraryPreferences()
        preferences.progress["7"] = MovieProgress(seconds: 125, duration: 7200, updated: 1)
        preferences.hiddenLiveCategories = ["23"]
        preferences.write(key: key)
        XCTAssertEqual(LibraryPreferences.read(key: key).progress["7"]?.label, "2:05")
        XCTAssertFalse(LibraryPreferences.read(key: key).categoryVisible("23", kind: .live))
        XCTAssertTrue(LibraryPreferences.read(key: key + "other").progress.isEmpty)
        let stored = String(data: UserDefaults.standard.data(forKey: key)!, encoding: .utf8)!
        for secretField in ["username", "password", "server", "playbackURL"] { XCTAssertFalse(stored.contains(secretField)) }
    }
    func testMovieDetailsReadProviderFieldsAndHandleMissingMetadata() {
        let info = MovieInformation.parse(["info": ["plot": "A movie overview", "releaseDate": "2026-01-01", "genre": "Drama"]])
        XCTAssertEqual(info.overview, "A movie overview")
        XCTAssertEqual(info.release, "2026-01-01")
        XCTAssertEqual(info.genre, "Drama")
        XCTAssertEqual(MovieInformation.parse([:]), MovieInformation())
        XCTAssertEqual(MovieInformation.parse(["movie_data": ["releasedate": "2020"]]).release, "2020")
    }

    func testCategoryPinsKeepOrderAndRemovePins() {
        let categories = [CatalogCategory(id: "1", name: "News"), CatalogCategory(id: "2", name: "Sports"), CatalogCategory(id: "3", name: "Movies")]
        let pins = CategoryPins.toggled("2", in: [])
        XCTAssertEqual(CategoryPins.ordered(categories, pins: pins).map(\.id), ["2", "1", "3"])
        XCTAssertEqual(CategoryPins.toggled("2", in: pins), [])
        XCTAssertEqual(CategoryPins.toggled("../bad", in: pins), pins)
        XCTAssertEqual(CategoryPins.ordered(categories, pins: ["99", "2"]).map(\.id), ["2", "1", "3"])
        XCTAssertNotEqual(CategoryPins.key(accountID: "a", host: "provider.example.invalid"), CategoryPins.key(accountID: "b", host: "provider.example.invalid"))
        XCTAssertFalse(CategoryPins.key(accountID: "a", host: "provider.example.invalid").contains("provider.example.invalid"))
    }
    @MainActor func testVideoTapHandlerStaysAttachedWhileControlsHide() {
        let canvas = VideoCanvas()
        var taps = 0
        canvas.onTap = { taps += 1 }
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 250)
        let vlcControls = UIButton(frame: canvas.bounds)
        canvas.drawable.addSubview(vlcControls)
        canvas.layoutIfNeeded()
        XCTAssertEqual(canvas.touchSurface.gestureRecognizers?.count, 1)
        XCTAssertTrue(canvas.hitTest(CGPoint(x: 200, y: 125), with: nil) === canvas.touchSurface)
        XCTAssertFalse(canvas.hitTest(CGPoint(x: 200, y: 125), with: nil) === vlcControls)
        canvas.tapped(); canvas.tapped()
        XCTAssertEqual(taps, 2)
    }
    func testUnifiedSearchKeepsMovieAndChannelWithSameProviderID() {
        let movie = CatalogItem(id: "7", name: "Sports movie", kind: .movies, fileExtension: "mkv", poster: nil)
        let channel = CatalogItem(id: "7", name: "Sports channel", kind: .live, fileExtension: "ts", poster: nil)
        let all = UnifiedSearch.matches([movie, channel], query: "SPORTS", filter: "all")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.id)).count, 2)
        XCTAssertEqual(UnifiedSearch.matches([movie, channel], query: "sports", filter: "movies").map(\.item.kind), [.movies])
        XCTAssertTrue(UnifiedSearch.matches([movie, channel], query: "missing", filter: "all").isEmpty)
    }
    @MainActor func testCatalogResetClearsSearchResults() {
        let catalog = SessionCatalog()
        let before = catalog.revision
        catalog.reset()
        XCTAssertTrue(catalog.searchable.isEmpty)
        XCTAssertTrue(catalog.progress.isEmpty)
        XCTAssertGreaterThan(catalog.revision, before)
    }
    func testBackgroundAudioIsEnabledInInstalledBuild() {
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio"))
    }

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

    func testLiveChannelNavigationStopsAtBoundaries() {
        let channels = (1...3).map { CatalogItem(id: String($0), name: "Channel \($0)", kind: .live, fileExtension: "ts", poster: nil) }
        XCTAssertEqual(ChannelNavigation.adjacent(in: channels, currentID: "2", offset: 1)?.id, "3")
        XCTAssertEqual(ChannelNavigation.adjacent(in: channels, currentID: "2", offset: -1)?.id, "1")
        XCTAssertNil(ChannelNavigation.adjacent(in: channels, currentID: "1", offset: -1))
        XCTAssertNil(ChannelNavigation.adjacent(in: channels, currentID: "3", offset: 1))
        XCTAssertNil(ChannelNavigation.adjacent(in: [], currentID: "1", offset: 1))
    }
    @MainActor func testFullCatalogSearchUsesOneRequest() async throws {
        let movie = CatalogItem(id: "1", name: "Movie", kind: .movies, fileExtension: "mkv", poster: nil)
        var calls: [String?] = []
        let result = try await CatalogLoader.load(categoryIDs: ["10", "20"], preferFullCatalog: true, fetch: {
            calls.append($0); return [movie, movie]
        }, progress: { _, _ in })
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.notice.isEmpty)
    }
    @MainActor func testCatalogFallbackPublishesPartialResults() async throws {
        let movie = CatalogItem(id: "1", name: "Movie", kind: .movies, fileExtension: "mkv", poster: nil)
        var calls: [String?] = []
        var counts: [Int] = []
        let result = try await CatalogLoader.load(categoryIDs: ["10", "20"], preferFullCatalog: true, fetch: { category in
            calls.append(category)
            guard category == "10" else { throw AppFailure("Unavailable") }
            return [movie]
        }, progress: { items, _ in counts.append(items.count) })
        XCTAssertEqual(calls, [nil, "10", "20"])
        XCTAssertEqual(result.items.map(\.id), ["1"])
        XCTAssertTrue(result.notice.contains("1 categories"))
        XCTAssertTrue(counts.contains(1))
    }
    @MainActor func testCancelledCatalogDoesNotStartRequests() async {
        var calls = 0
        let task = Task { @MainActor in
            try await CatalogLoader.load(categoryIDs: ["10"], preferFullCatalog: true, fetch: { _ in
                calls += 1; return []
            }, progress: { _, _ in })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
    }

}
