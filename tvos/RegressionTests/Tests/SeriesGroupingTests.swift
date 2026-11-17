import XCTest
@testable import AntStreamsRegressionHost

final class SeriesGroupingTests: XCTestCase {
    func testSeriesVersionsGroupAcrossCountriesAndKeepEnglishFirst() {
        let categories = [CatalogCategory(id: "us", name: "US| Drama"), CatalogCategory(id: "en", name: "EN Shows"), CatalogCategory(id: "ar", name: "العربية")]
        let us = SeriesItem(id: "1", name: "US| From (2022) HD", poster: nil, categoryID: "us", year: "2022")
        let en = SeriesItem(id: "2", name: "EN| From (2022) FHD", poster: nil, categoryID: "en", year: "2022")
        let ar = SeriesItem(id: "3", name: "AR| From (2022)", poster: nil, categoryID: "ar", year: "2022")
        let groups = SeriesSearchGrouping.matches([ar, en, us, us], query: " from ", categories: categories, preferences: LibraryPreferences())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "From")
        XCTAssertEqual(groups.first?.year, "2022")
        XCTAssertEqual(groups.first?.variants.map(\.id), ["1", "2", "3"])
        XCTAssertTrue(SeriesSearchGrouping.label(en, categories: categories).contains("EN"))
    }

    func testForeignOnlySearchGroupStaysHiddenAndManualHidesApplyToVersions() {
        let categories = [CatalogCategory(id: "us", name: "US| Drama"), CatalogCategory(id: "ar", name: "العربية")]
        let us = SeriesItem(id: "1", name: "US| From", poster: nil, categoryID: "us")
        let ar = SeriesItem(id: "2", name: "AR| From", poster: nil, categoryID: "ar")
        var preferences = LibraryPreferences()
        XCTAssertTrue(SeriesSearchGrouping.matches([ar], query: "From", categories: categories, preferences: preferences).isEmpty)
        preferences.hiddenSeriesCategories.insert("ar")
        XCTAssertEqual(SeriesSearchGrouping.matches([us, ar], query: "From", categories: categories, preferences: preferences).first?.variants.map(\.id), ["1"])
    }

    func testSameNameRemakesAndAmbiguousMissingYearsStaySeparate() {
        let first = SeriesItem(id: "1", name: "US| The Office (2001)", poster: nil)
        let remake = SeriesItem(id: "2", name: "EN| The Office (2005)", poster: nil)
        let unknown = SeriesItem(id: "3", name: "The Office", poster: nil)
        let groups = SeriesSearchGrouping.matches([first, remake, unknown], query: "office", categories: [], preferences: LibraryPreferences())
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups.map(\.year)), ["2001", "2005", ""])
    }

    func testMissingYearJoinsOnlyOneKnownEdition() {
        let first = SeriesItem(id: "1", name: "US| From (2022)", poster: nil)
        let unknown = SeriesItem(id: "2", name: "EN From [EN]", poster: nil)
        XCTAssertEqual(SeriesSearchGrouping.matches([first, unknown], query: "FROM", categories: [], preferences: LibraryPreferences()).first?.variants.count, 2)
    }

    func testMatchingIDsFromDifferentProvidersRemainSelectableVersions() {
        let one = SeriesItem(id: "1", name: "From", poster: nil, providerID: UUID())
        let two = SeriesItem(id: "1", name: "From", poster: nil, providerID: UUID())
        XCTAssertEqual(SeriesSearchGrouping.matches([one, two], query: "From", categories: [], preferences: LibraryPreferences()).first?.variants.count, 2)
    }

}
