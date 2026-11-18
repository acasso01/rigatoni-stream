import XCTest
#if REGRESSION_HOST
@testable import AntStreamsRegressionHost
#elseif os(tvOS)
@testable import RigatoniStreamTV
#else
@testable import RigatoniStream
#endif

final class CatalogPresentationTests: XCTestCase {
    func testCleanNamesMatchProviderSamples() {
        let samples: [(String, String)] = [
            ("US| TUBI RAW 60fps", "Tubi"),
            ("US| SPECTRUM NETWORK HD/RAW", "Spectrum Network"),
            ("AT&T: 365BLK RAW", "365BLK"),
            ("US| NETFLIX ON AIR RAW 60fps", "Netflix On Air"),
            ("US| NETFLIX ON AIR RAW 60 FPS", "Netflix On Air"),
            ("##### AT&T #####", "AT&T"),
            ("===== ESPN =====", "ESPN"),
            ("US| PEACOCK RAW", "Peacock"),
            ("US: HBO HD", "HBO"),
            ("(US) ESPN", "ESPN"),
            ("USA | CNN HD", "CNN"),
            ("UK| BBC ONE FHD", "BBC One"),
            ("EN| DISNEY PLUS HD", "Disney Plus"),
            ("US| PRIME RAW", "Prime"),
            ("AT&T: 5-MINUTE CRAFTS RAW", "5-Minute Crafts"),
            ("US| SPECTRUM NETWORK HD/RAW", "Spectrum Network"),
            ("AT&T RAW", "AT&T"),
            ("USA Network", "USA Network"),
            ("US OPEN", "US Open"),
            ("Movie (1080p)", "Movie"),
            ("Channel (HD)", "Channel"),
            ("The Batman (2022)", "The Batman (2022)"),
            ("News HEVC H.265", "News"),
            ("Sports 4K UHD", "Sports"),
            ("Doc ᴴᴰ", "Doc"),
            ("Clip ᴿᴬᵂ", "Clip"),
            ("Feed ⁶⁰fps", "Feed"),
            ("IN| BOLLYWOOD HD", "Bollywood"),
            ("LATINO | NOVELAS FHD", "Novelas"),
            ("US| TV LAND HD", "TV Land"),
            ("##### AT&T RAW #####", "AT&T"),
            ("XFINITY: USA NETWORK HD", "USA Network"),
            ("Home · US| TUBI RAW", "Home · Tubi")
        ]
        for (raw, expected) in samples {
            XCTAssertEqual(NameCleaner.clean(raw), expected, raw)
        }
    }

    func testUnitedStatesFilterKeepsUntaggedAndDropsForeign() {
        XCTAssertTrue(CategoryRegion.isUnitedStates("US| TUBI RAW"))
        XCTAssertTrue(CategoryRegion.isUnitedStates("US: HBO"))
        XCTAssertTrue(CategoryRegion.isUnitedStates("(US) ESPN"))
        XCTAssertTrue(CategoryRegion.isUnitedStates("USA | CNN"))
        XCTAssertTrue(CategoryRegion.isUnitedStates("EN| MOVIES HD"))
        XCTAssertTrue(CategoryRegion.isUnitedStates("USA Network"))
        XCTAssertTrue(CategoryRegion.isUnitedStates("ENGLISH PREMIER LEAGUE"))
        XCTAssertFalse(CategoryRegion.isUnitedStates("UK| BBC ONE"))
        XCTAssertFalse(CategoryRegion.isUnitedStates("SPORTS"))
        XCTAssertTrue(CategoryRegion.isForeign("UK| SKY SPORTS HD"))
        XCTAssertTrue(CategoryRegion.isForeign("CA| CBC"))
        XCTAssertTrue(CategoryRegion.isForeign("SPANISH MOVIES"))
        XCTAssertTrue(CategoryRegion.isForeign("LATINO | NOVELAS"))
        XCTAssertTrue(CategoryRegion.isForeign("CANADA | NEWS"))
        XCTAssertFalse(CategoryRegion.isForeign("US| UK NEWS"))
        XCTAssertFalse(CategoryRegion.isForeign("##### AT&T #####"))
        XCTAssertFalse(CategoryRegion.isForeign("AT&T RAW 60fps"))
        XCTAssertFalse(CategoryRegion.isForeign("SPORTS"))
        XCTAssertTrue(CategoryRegion.included("SPORTS", unitedStatesOnly: true))
        XCTAssertTrue(CategoryRegion.included("US| TUBI", unitedStatesOnly: true))
        XCTAssertFalse(CategoryRegion.included("MX| TELEMUNDO", unitedStatesOnly: true))
        XCTAssertTrue(CategoryRegion.included("MX| TELEMUNDO", unitedStatesOnly: false))
        XCTAssertTrue(CategoryRegion.included("Home · US| ESPN", unitedStatesOnly: true))
        XCTAssertFalse(CategoryRegion.included("Home · UK| BBC", unitedStatesOnly: true))
    }

    func testEnglishTagsAreIncludedWithoutMatchingFragments() {
        for name in ["EN Movies", "en| Movies", "[EN] From", "From (EN)", "Movie en HD", "ENG | Drama", "English Movies", "UK | EN Movies"] {
            XCTAssertTrue(CategoryRegion.isUnitedStates(name), name)
            XCTAssertTrue(CategoryRegion.included(name, unitedStatesOnly: true), name)
        }
        for name in ["Enemy", "Frozen", "Entertainment", "Englishman"] {
            XCTAssertFalse(CategoryRegion.isEnglish(name), name)
        }
        XCTAssertFalse(CategoryRegion.included("UK | BBC", unitedStatesOnly: true))
    }

    func testEnglishTitlesOverrideRegionButRespectManualHiding() {
        let categories = [CatalogCategory(id: "uk", name: "UK | Mixed")]
        let channel = CatalogItem(id: "en-live", name: "News EN", kind: .live, fileExtension: "ts", poster: nil, categoryID: "uk")
        let movie = CatalogItem(id: "en-movie", name: "Movie (EN)", kind: .movies, fileExtension: "mp4", poster: nil, categoryID: "uk")
        let show = SeriesItem(id: "en-show", name: "From EN", poster: nil, categoryID: "uk")
        var preferences = LibraryPreferences()
        preferences.unitedStatesOnly = true
        XCTAssertTrue(preferences.accepts(channel, categories: categories))
        XCTAssertTrue(preferences.accepts(movie, categories: categories))
        XCTAssertTrue(preferences.acceptsSeries(show, categories: categories))
        preferences.hiddenChannels.insert(channel.scopedID)
        preferences.hiddenMovieCategories.insert("uk")
        preferences.hiddenSeriesCategories.insert("uk")
        XCTAssertFalse(preferences.accepts(channel, categories: categories))
        XCTAssertFalse(preferences.accepts(movie, categories: categories))
        XCTAssertFalse(preferences.acceptsSeries(show, categories: categories))
    }

    func testNonEnglishCategoriesAreAutomaticallyHiddenAndCanBeRestored() throws {
        let hidden = ["Arabic Movies", "AR| Drama", "العربية", "أفلام عربية", "الأخبار", "ES| Cine", "Spanish Movies", "Hindi Movies", "Русские каналы"]
        let retained = ["EN Movies", "English Drama", "US| News", "UK| News", "Sports", "Entertainment"]
        var preferences = LibraryPreferences()
        preferences.unitedStatesOnly = false
        XCTAssertTrue(preferences.hideNonEnglishCategories)
        for name in hidden {
            XCTAssertTrue(CategoryRegion.isNonEnglish(name), name)
            for section in CatalogSection.allCases {
                XCTAssertFalse(preferences.allows(CatalogCategory(id: "test", name: name), section: section), name)
            }
        }
        for name in retained {
            XCTAssertFalse(CategoryRegion.isNonEnglish(name), name)
            XCTAssertTrue(preferences.allows(CatalogCategory(id: "test", name: name), section: .live), name)
        }
        let legacy = try JSONDecoder().decode(LibraryPreferences.self, from: Data(#"{"unitedStatesOnly":false,"progress":{"7":{"seconds":125,"duration":7200,"updated":1}}}"#.utf8))
        XCTAssertTrue(legacy.hideNonEnglishCategories)
        XCTAssertEqual(legacy.progress["7"]?.seconds, 125)
        preferences.hideNonEnglishCategories = false
        let restored = try JSONDecoder().decode(LibraryPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(restored.hideNonEnglishCategories)
        XCTAssertTrue(restored.allows(CatalogCategory(id: "ar", name: "العربية"), section: .live))
    }

    func testNonEnglishCategoryContentIsExcludedEvenWithEnglishTitle() {
        let categories = [CatalogCategory(id: "ar", name: "العربية")]
        var preferences = LibraryPreferences()
        preferences.unitedStatesOnly = false
        let movie = CatalogItem(id: "1", name: "Movie EN", kind: .movies, fileExtension: "mp4", poster: nil, categoryID: "ar")
        let show = SeriesItem(id: "2", name: "Show EN", poster: nil, categoryID: "ar")
        XCTAssertFalse(preferences.accepts(movie, categories: categories))
        XCTAssertFalse(preferences.acceptsSeries(show, categories: categories))
        preferences.hideNonEnglishCategories = false
        XCTAssertTrue(preferences.accepts(movie, categories: categories))
        XCTAssertTrue(preferences.acceptsSeries(show, categories: categories))
    }

    func testBrowseCategoriesHidesForeignAndHonorsOrderAndRenames() {
        let categories = [
            CatalogCategory(id: "1", name: "UK| BBC ONE HD"),
            CatalogCategory(id: "2", name: "US| TUBI RAW 60fps"),
            CatalogCategory(id: "3", name: "SPORTS"),
            CatalogCategory(id: "4", name: "##### ESPN #####")
        ]
        var preferences = LibraryPreferences()
        XCTAssertEqual(preferences.browseCategories(categories, section: .live).map(\.id), ["2", "3", "4"])
        XCTAssertEqual(preferences.browseCategories(categories, section: .live).map(\.name), ["Tubi", "Sports", "ESPN"])
        preferences.unitedStatesOnly = false
        preferences.moveCategory("3", section: .live, direction: -1, among: categories)
        XCTAssertEqual(preferences.presented(categories, section: .live).map(\.id), ["1", "3", "2", "4"])
        preferences.setSection("3", section: .live, visible: false)
        XCTAssertFalse(preferences.browseCategories(categories, section: .live).contains { $0.id == "3" })
        preferences.setRename("My Tubi", key: LibraryPreferences.renameKey(section: .live, role: "category", id: "2"))
        XCTAssertEqual(preferences.categoryTitle(categories[1], section: .live), "My Tubi")
        preferences.cleanNames = false
        preferences.setRename(nil, key: LibraryPreferences.renameKey(section: .live, role: "category", id: "2"))
        XCTAssertEqual(preferences.categoryTitle(categories[1], section: .live), "US| TUBI RAW 60fps")
    }

    func testLegacyPreferencesDecodeKeepsProgressAndDefaults() throws {
        let legacy = #"{"hiddenLiveCategories":["23"],"hiddenMovieCategories":[],"hiddenChannels":[],"progress":{"7":{"seconds":125,"duration":7200,"updated":1}}}"#
        let decoded = try JSONDecoder().decode(LibraryPreferences.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.categoryVisible("23", kind: .live))
        XCTAssertEqual(decoded.progress["7"]?.label, "2:05")
        XCTAssertTrue(decoded.unitedStatesOnly)
        XCTAssertTrue(decoded.cleanNames)
        XCTAssertTrue(decoded.hiddenSeriesCategories.isEmpty)
        let key = "rigatoni-presentation-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: key) }
        decoded.write(key: key)
        let stored = String(data: UserDefaults.standard.data(forKey: key)!, encoding: .utf8)!
        for secret in ["username", "password", "server", "playbackURL", "api_key"] {
            XCTAssertFalse(stored.contains(secret))
        }
        XCTAssertEqual(LibraryPreferences.read(key: key).progress["7"]?.seconds, 125)
    }

    func testShelfRankingUsesAddedRatingsAndTMDBMatches() {
        let items = [
            ShelfRanking.Candidate(index: 0, name: "Old Movie", added: 10, rating: 9, hasPoster: true),
            ShelfRanking.Candidate(index: 1, name: "Fresh Movie", added: 50, rating: 1, hasPoster: true),
            ShelfRanking.Candidate(index: 2, name: "Fresh Movie", added: 40, rating: 8, hasPoster: false),
            ShelfRanking.Candidate(index: 3, name: "No Date", added: 0, rating: 10, hasPoster: true)
        ]
        XCTAssertEqual(ShelfRanking.recentlyAdded(items), [1, 0])
        XCTAssertEqual(ShelfRanking.trending(items, tmdbTitles: []), [3, 0, 1])
        XCTAssertEqual(ShelfRanking.trending(items, tmdbTitles: ["Fresh Movie", "Missing Title", "Old Movie (2020)"]), [1, 0])
        XCTAssertEqual(ShelfRanking.normalize("Old Movie (2020)"), "old movie")
    }

    func testTMDBParserAndProviderFields() {
        let json = #"{"results":[{"title":"Dune","release_date":"2021-10-22"},{"name":"The Bear"},{"title":"  "} ]}"#
        XCTAssertEqual(TMDBClient.titles(in: Data(json.utf8)), ["Dune", "The Bear"])
        let row: [String: Any] = ["added": "1710000000", "rating_5based": "4.5", "year": "2026", "stream_id": "9", "name": "Example", "stream_icon": "https://cdn.example/poster.jpg"]
        let item = CatalogItem.parse(row, kind: .movies)
        XCTAssertEqual(item?.added, 1710000000)
        XCTAssertEqual(item?.rating, 9)
        XCTAssertEqual(item?.year, "2026")
        XCTAssertEqual(item?.poster?.host, "cdn.example")
        let series = SeriesStore.parseSeries([[
            "series_id": 4, "name": "US| SHOW RAW", "cover": "https://cdn.example/cover.jpg",
            "category_id": 8, "last_modified": 180, "rating": 7.5, "releaseDate": "2024-05-01"
        ]])
        XCTAssertEqual(series.first?.categoryID, "8")
        XCTAssertEqual(series.first?.added, 180)
        XCTAssertEqual(series.first?.rating, 7.5)
        XCTAssertEqual(series.first?.year, "2024")
    }

    func testSeriesSearchCoversEveryVisibleCategory() {
        let categories = [
            CatalogCategory(id: "1", name: "US| Drama"),
            CatalogCategory(id: "2", name: "US| Comedy"),
            CatalogCategory(id: "3", name: "UK| Drama"),
            CatalogCategory(id: "4", name: "العربية"),
            CatalogCategory(id: "5", name: "Sports"),
            CatalogCategory(id: "6", name: "Classics")
        ]
        var preferences = LibraryPreferences()
        preferences.hiddenSeriesCategories = ["5"]
        XCTAssertEqual(SeriesSearchScope.categories(categories, preferences: preferences).map(\.id), ["1", "2", "6"])
        let drama = SeriesItem(id: "10", name: "The Bear", poster: nil, categoryID: "1")
        let comedy = SeriesItem(id: "11", name: "The Bear Extra", poster: nil, categoryID: "2")
        let uk = SeriesItem(id: "12", name: "The Bear UK", poster: nil, categoryID: "3")
        let englishUK = SeriesItem(id: "15", name: "The Bear EN", poster: nil, categoryID: "3")
        let arabic = SeriesItem(id: "13", name: "The Bear AR", poster: nil, categoryID: "4")
        let hidden = SeriesItem(id: "14", name: "The Bear Sports", poster: nil, categoryID: "5")
        let classic = SeriesItem(id: "16", name: "The Bear Classic", poster: nil, categoryID: "6")
        let hits = SeriesSearchScope.matching([drama, comedy, uk, englishUK, arabic, hidden, classic], query: "bear", categories: categories, preferences: preferences)
        XCTAssertEqual(hits.map(\.id), ["10", "11", "16"])
        preferences.unitedStatesOnly = false
        preferences.hideNonEnglishCategories = false
        XCTAssertEqual(SeriesSearchScope.categories(categories, preferences: preferences).map(\.id), ["1", "2", "3", "4", "6"])
        XCTAssertEqual(SeriesSearchScope.matching([uk, englishUK], query: "bear", categories: categories, preferences: preferences).map(\.id), ["12", "15"])
        let merged = SeriesSearchScope.merge([[drama], [comedy, drama]])
        XCTAssertEqual(merged.map(\.id), ["10", "11"])
        XCTAssertEqual(Set(merged.map(\.categoryID)), ["1", "2"])
    }
    func testSeriesParseStampsTheRequestedCategoryWhenTheRowOmitsIt() {
        let stamped = SeriesStore.parseSeries([["series_id": "5", "name": "Show"]], fallbackCategoryID: "42")
        XCTAssertEqual(stamped.first?.categoryID, "42")
        let explicit = SeriesStore.parseSeries([["series_id": "6", "name": "Show", "category_id": 7]], fallbackCategoryID: "42")
        XCTAssertEqual(explicit.first?.categoryID, "7")
    }
    func testItemRenameUsesScopedIdentity() {
        var preferences = LibraryPreferences()
        let item = CatalogItem(id: "7", name: "US| ESPN RAW 60fps", kind: .live, fileExtension: "ts", poster: nil, categoryID: "2")
        XCTAssertEqual(preferences.itemTitle(item), "ESPN")
        preferences.setRename("Main ESPN", key: LibraryPreferences.renameKey(section: .live, role: "item", id: item.scopedID))
        XCTAssertEqual(preferences.itemTitle(item), "Main ESPN")
        let show = SeriesItem(id: "3", name: "UK| BAKE OFF HD", poster: nil, categoryID: "9")
        XCTAssertEqual(preferences.seriesTitle(show), "Bake Off")
        XCTAssertFalse(preferences.acceptsSeries(show, categories: [CatalogCategory(id: "9", name: "UK| REALITY HD")]))
        preferences.unitedStatesOnly = false
        XCTAssertTrue(preferences.acceptsSeries(show, categories: [CatalogCategory(id: "9", name: "UK| REALITY HD")]))
    }
}
