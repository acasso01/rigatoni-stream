import XCTest
#if REGRESSION_HOST
@testable import AntStreamsRegressionHost
#elseif os(tvOS)
@testable import RigatoniStreamTV
#else
@testable import RigatoniStream
#endif

final class CatalogPresentationTests: XCTestCase {
    func testPersistentSeriesIndexSurvivesSnapshotAndScopesSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = PersistentCatalogIndex(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        var provider = Provider()
        provider.server = "http://provider.example:8080"
        provider.username = "demo-user"
        provider.password = "do-not-persist"
        let first = SeriesItem(id: "101", name: "Café Aurora", poster: URL(string: "https://images.example/aurora.jpg"), categoryID: "series-1", year: "2024")
        let second = SeriesItem(id: "102", name: "Café Aurora", poster: nil, categoryID: "series-2", year: "2024")

        await index.storeSeries([first], scope: "profile-a", categoryID: "series-1", provider: provider)
        await index.storeSeries([second], scope: "profile-a", categoryID: "series-2", provider: provider)
        await index.markSeriesSnapshot([first, second], scope: "profile-a", categoryIDs: ["series-1", "series-2"], provider: provider)

        let restored = await index.loadSeriesSnapshot(scope: "profile-a", categoryIDs: ["series-2", "series-1"])
        let category = await index.loadSeries(scope: "profile-a", categoryID: "series-1")
        let matches = await index.searchSeries(scope: "profile-a", query: "cafe", categoryIDs: ["series-2"])
        let isolated = await index.loadSeriesSnapshot(scope: "another-profile", categoryIDs: ["series-1", "series-2"])
        XCTAssertEqual(Set(restored?.map(\.scopedID) ?? []), Set([first.scopedID, second.scopedID]))
        XCTAssertEqual(category?.first?.id, "101")
        XCTAssertEqual(matches.map(\.id), ["102"])
        XCTAssertNil(isolated)
    }

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

    func testMovieTitleCleanupAndSafeDeduplication() {
        let samples: [(String, String)] = [
            ("NF Cars 3", "Cars 3"),
            ("D+ Cars 2 (2011)", "Cars 2 (2011)"),
            ("4K-D+ Cars 3 (2017)", "Cars 3 (2017)"),
            ("4K-EN From (2022)", "From (2022)"),
            ("NF Breaking Bad", "Breaking Bad"),
            ("The Café 2 (2020)", "The Café 2 (2020)")
        ]
        for (raw, expected) in samples { XCTAssertEqual(MovieTitle.clean(raw), expected, raw) }

        func movie(_ id: String, _ name: String, _ year: String, _ category: String) -> CatalogItem {
            CatalogItem(id: id, name: name, kind: .movies, fileExtension: "mp4", poster: nil,
                        categoryID: category, year: year)
        }
        let entries = [
            movie("1", "NF Cars 3", "2017", "netflix"),
            movie("2", "4K-D+ Cars 3 (2017)", "2017", "disney"),
            movie("3", "Cars 2 (2011)", "2011", "movies"),
            movie("4", "Cars 3", "2024", "remake")
        ]
        XCTAssertEqual(MovieTitle.unique(entries).map(\.id), ["1", "3", "4"])
        let oneKnownRelease = [movie("5", "NF Cars 3", "", "netflix"), movie("6", "Cars 3 (2017)", "2017", "disney")]
        XCTAssertEqual(MovieTitle.unique(oneKnownRelease).map(\.id), ["5"])
        XCTAssertEqual(entries[0].name, "NF Cars 3", "Normalization must not replace the provider title used for source lookup.")
        let chosen = movie("10", "The Polar Express (2004)", "2004", "A")
        XCTAssertTrue(MovieTitle.matchesSource(movie("11", "4K-DE The Polar Express", "2004", "B"), for: chosen))
        XCTAssertTrue(MovieTitle.matchesSource(movie("12", "The Polar Express", "", "C"), for: chosen))
        XCTAssertFalse(MovieTitle.matchesSource(movie("13", "The Polar Express (2010)", "2010", "D"), for: chosen))
        XCTAssertFalse(MovieTitle.matchesSource(movie("14", "Polar Express", "2004", "E"), for: chosen))
    }

    @MainActor
    func testResolvedMovieSourcesAreCachedPerProviderLibraryScope() {
        let catalog = SessionCatalog()
        let item = CatalogItem(id: "31", name: "NF Cars 3", kind: .movies, fileExtension: "mp4", poster: nil, categoryID: "a", year: "2017")
        let secondSource = CatalogItem(id: "84", name: "4K-D+ Cars 3 (2017)", kind: .movies, fileExtension: "mkv", poster: nil, categoryID: "b", year: "2017")
        catalog.cacheMovieSources([item, secondSource], for: item, scope: "library-one")
        XCTAssertEqual(catalog.cachedMovieSources(for: item, scope: "library-one")?.map(\.scopedID), ["31", "84"])
        XCTAssertNil(catalog.cachedMovieSources(for: item, scope: "library-two"))
        catalog.reset()
        XCTAssertNil(catalog.cachedMovieSources(for: item, scope: "library-one"))
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

    func testCategorySelectionsArePerSectionAndNewCategoriesDefaultHiddenAfterCustomization() throws {
        var preferences = LibraryPreferences()
        preferences.observeCategories([CatalogCategory(id: "old", name: "News")], section: .live)
        preferences.setSection("old", section: .live, visible: false)
        preferences.setSection("movie", section: .movies, visible: false)
        XCTAssertFalse(preferences.categoryVisible("old", section: .live))
        XCTAssertTrue(preferences.categoryVisible("new", section: .live))
        preferences.observeCategories([
            CatalogCategory(id: "old", name: "News"),
            CatalogCategory(id: "new", name: "Sports")
        ], section: .live)
        XCTAssertFalse(preferences.categoryVisible("new", section: .live))
        XCTAssertTrue(preferences.categoryVisible("new", section: .movies))
        let restored = try JSONDecoder().decode(LibraryPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(restored.categoryVisible("new", section: .live))
        XCTAssertFalse(restored.categoryVisible("old", section: .live))
        preferences.resetCategorySection(.live)
        XCTAssertTrue(preferences.categoryVisible("new", section: .live))
        XCTAssertFalse(preferences.categoryVisible("movie", section: .movies))
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
            "category_id": 8, "last_modified": 180, "rating": 7.5, "releaseDate": "2024-05-01", "imdb": "tt1234567"
        ]])
        XCTAssertEqual(series.first?.categoryID, "8")
        XCTAssertEqual(series.first?.added, 180)
        XCTAssertEqual(series.first?.rating, 7.5)
        XCTAssertEqual(series.first?.year, "2024")
        XCTAssertEqual(series.first?.externalID, "imdb:tt1234567")
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

    func testUnifiedSeriesGroupingCombinesLanguageCopiesAndHonorsMetadataIDs() {
        let categories = [CatalogCategory(id: "en", name: "English"), CatalogCategory(id: "es", name: "Spanish")]
        let english = SeriesItem(id: "1", name: "American Horror Story", poster: nil, categoryID: "en", year: "2011", externalID: "imdb:tt1844624")
        let spanish = SeriesItem(id: "2", name: "Historia de horror americana", poster: nil, categoryID: "es", externalID: "imdb:tt1844624")

        var preferences = LibraryPreferences()
        preferences.hideNonEnglishCategories = false
        preferences.unitedStatesOnly = false
        let groups = SeriesSearchGrouping.matches([english, spanish], query: "horror", categories: categories, preferences: preferences)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].variants.map(\.id)), ["1", "2"])
    }

    func testSeriesSearchRanksExactAndYearlessTitlesBeforeLooseMatches() {
        let category = [CatalogCategory(id: "shows", name: "Shows")]
        let items = [
            SeriesItem(id: "1", name: "From Another Life", poster: nil, categoryID: "shows"),
            SeriesItem(id: "2", name: "From (2022)", poster: nil, categoryID: "shows", year: "2022"),
            SeriesItem(id: "3", name: "Breaking Bad", poster: nil, categoryID: "shows"),
            SeriesItem(id: "4", name: "The Office (2005)", poster: nil, categoryID: "shows", year: "2005"),
            SeriesItem(id: "5", name: "Lost in Space", poster: nil, categoryID: "shows"),
            SeriesItem(id: "6", name: "Lost", poster: nil, categoryID: "shows")
        ]
        let preferences = LibraryPreferences()
        let from = SeriesSearchGrouping.matches(items, query: "from", categories: category, preferences: preferences)
        XCTAssertEqual(from.first?.title, "From")
        XCTAssertEqual(from.first?.year, "2022")
        XCTAssertEqual(from.first?.preferred.id, "2")
        XCTAssertEqual(SeriesSearchGrouping.matches(items, query: "breaking bad", categories: category, preferences: preferences).first?.title, "Breaking Bad")
        XCTAssertEqual(SeriesSearchGrouping.matches(items, query: "the office", categories: category, preferences: preferences).first?.title, "The Office")
        XCTAssertEqual(SeriesSearchGrouping.matches(items, query: "lost", categories: category, preferences: preferences).first?.title, "Lost")
        XCTAssertEqual(SeriesSearchGrouping.matches(items, query: "cafe", categories: category, preferences: preferences).count, 0)
    }

    func testWarmSeriesIndexSearchAcross154Categories() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = PersistentCatalogIndex(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        var provider = Provider()
        provider.server = "http://provider.example:8080"
        provider.username = "demo-user"
        provider.password = "do-not-persist"
        let categoryIDs = (0..<154).map { "cat-\($0)" }

        for (categoryNumber, categoryID) in categoryIDs.enumerated() {
            let batch = (0..<650).map { row -> SeriesItem in
                let isMatch = row == 0
                let title = categoryNumber == 153 && isMatch ? "From (2022)" : (isMatch ? "From Another Life \(categoryNumber)" : "Catalog Drama \(categoryNumber)-\(row)")
                return SeriesItem(id: "\(categoryNumber)-\(row)", name: title, poster: nil, categoryID: categoryID)
            }
            await index.storeSeries(batch, scope: "perf-profile", categoryID: categoryID, provider: provider)
        }

        let start = ProcessInfo.processInfo.systemUptime
        let matches = await index.searchSeries(scope: "perf-profile", query: "from", categoryIDs: categoryIDs, limit: 1000)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        NSLog("Warm indexed search: 100,100 rows / 154 categories / %.3f seconds", elapsed)
        XCTAssertEqual(matches.count, 154)
        XCTAssertEqual(matches.first?.name, "From (2022)")
    }

    func testUnifiedSeriesGroupingKeepsRemakesAndUnknownYearsSeparate() {
        let categories = [CatalogCategory(id: "1", name: "Shows")]
        let original = SeriesItem(id: "1", name: "The Office (2001)", poster: nil, categoryID: "1")
        let remake = SeriesItem(id: "2", name: "The Office (2005)", poster: nil, categoryID: "1")
        let unknownYear = SeriesItem(id: "3", name: "The Office", poster: nil, categoryID: "1")

        let groups = SeriesSearchGrouping.groups([original, remake, unknownYear], categories: categories, preferences: LibraryPreferences())

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups.map(\.year)), ["", "2001", "2005"])
    }

    func testUnifiedEpisodeMapsTheSameEpisodeNumberToEveryProviderSource() {
        let providerA = SeriesItem(id: "100", name: "Show", poster: nil, providerID: UUID(), categoryID: "a")
        let providerB = SeriesItem(id: "200", name: "Show ES", poster: nil, providerID: UUID(), categoryID: "b")
        let season = [SeriesSeason(number: 1, name: "Season 1")]
        let first = SeriesShowDetails(seasons: season, episodes: [1: [SeriesEpisode(id: "501", number: 1, title: "Pilot", ext: "mp4")]], synopsis: "", genre: "", year: "", rating: "", contentRating: "", backdrop: nil)
        let second = SeriesShowDetails(seasons: season, episodes: [1: [SeriesEpisode(id: "901", number: 1, title: "Piloto", ext: "mkv")]], synopsis: "", genre: "", year: "", rating: "", contentRating: "", backdrop: nil)

        let merged = SeriesEpisodeGrouping.merge([(providerA, first), (providerB, second)])

        XCTAssertEqual(merged[1]?.count, 1)
        XCTAssertEqual(Set(merged[1]?.first?.sources.map(\.episode.id) ?? []), ["501", "901"])
        XCTAssertEqual(Set(merged[1]?.first?.sources.map(\.series.providerID) ?? []), [providerA.providerID, providerB.providerID])
        XCTAssertNotEqual(merged[1]?.first?.sources[0].progressID, merged[1]?.first?.sources[1].progressID)
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
