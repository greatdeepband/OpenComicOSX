import XCTest
@testable import DC

final class LibrarySearchFilterTests: XCTestCase {
    func testMultiTokenMatch() {
        XCTAssertTrue(matchesQuery(filename: "Batman #003 (1940)", query: "batman 3"))
    }
    func testNoMatch() {
        XCTAssertFalse(matchesQuery(filename: "Batman #003 (1940)", query: "batman x"))
    }
    func testEmptyQueryAlwaysTrue() {
        XCTAssertTrue(matchesQuery(filename: "Batman #003 (1940)", query: ""))
    }
    func testCaseInsensitive() {
        XCTAssertTrue(matchesQuery(filename: "saga vol 03", query: "SAGA VOL"))
    }
    func testOrderIndependent() {
        XCTAssertTrue(matchesQuery(filename: "Batman #003 (1940)", query: "1940 batman"))
    }
    func testSingleTokenMatch() {
        XCTAssertTrue(matchesQuery(filename: "Batman #003 (1940)", query: "batman"))
    }
    func testPartialNoMatch() {
        XCTAssertFalse(matchesQuery(filename: "Batman #003 (1940)", query: "batman superman"))
    }

    // MARK: - LibraryFilter / comicMatchesFilter tests

    func testDefaultFilterIsNotActive() {
        XCTAssertFalse(LibraryFilter().isActive)
    }

    func testDefaultFilterMatchesEverything() {
        let f = LibraryFilter()
        XCTAssertTrue(comicMatchesFilter(status: .unread,           isFavorited: false, format: "cbz", filter: f))
        XCTAssertTrue(comicMatchesFilter(status: .inProgress(0.5),  isFavorited: true,  format: "pdf", filter: f))
        XCTAssertTrue(comicMatchesFilter(status: .finished,          isFavorited: false, format: "cbr", filter: f))
    }

    func testStatusFilterUnread() {
        var f = LibraryFilter(); f.status = .unread
        XCTAssertTrue( comicMatchesFilter(status: .unread,          isFavorited: false, format: "cbz", filter: f))
        XCTAssertFalse(comicMatchesFilter(status: .inProgress(0.5), isFavorited: false, format: "cbz", filter: f))
        XCTAssertFalse(comicMatchesFilter(status: .finished,         isFavorited: false, format: "cbz", filter: f))
    }

    func testStatusFilterInProgress() {
        var f = LibraryFilter(); f.status = .inProgress
        XCTAssertFalse(comicMatchesFilter(status: .unread,          isFavorited: false, format: "cbz", filter: f))
        XCTAssertTrue( comicMatchesFilter(status: .inProgress(0.5), isFavorited: false, format: "cbz", filter: f))
        XCTAssertFalse(comicMatchesFilter(status: .finished,         isFavorited: false, format: "cbz", filter: f))
    }

    func testStatusFilterFinished() {
        var f = LibraryFilter(); f.status = .finished
        XCTAssertFalse(comicMatchesFilter(status: .unread,          isFavorited: false, format: "cbz", filter: f))
        XCTAssertFalse(comicMatchesFilter(status: .inProgress(0.5), isFavorited: false, format: "cbz", filter: f))
        XCTAssertTrue( comicMatchesFilter(status: .finished,         isFavorited: false, format: "cbz", filter: f))
    }

    func testFavoritedOnlyPassesFavoritedOnly() {
        var f = LibraryFilter(); f.favoritedOnly = true
        XCTAssertTrue( comicMatchesFilter(status: .unread, isFavorited: true,  format: "cbz", filter: f))
        XCTAssertFalse(comicMatchesFilter(status: .unread, isFavorited: false, format: "cbz", filter: f))
    }

    func testFavoritedOnlyMakesFilterActive() {
        var f = LibraryFilter(); f.favoritedOnly = true
        XCTAssertTrue(f.isActive)
    }

    func testFormatFilterPassesCbzRejectsPdf() {
        var f = LibraryFilter(); f.formats = ["cbz"]
        XCTAssertTrue( comicMatchesFilter(status: .unread, isFavorited: false, format: "cbz", filter: f))
        XCTAssertFalse(comicMatchesFilter(status: .unread, isFavorited: false, format: "pdf", filter: f))
    }

    func testFormatFilterEmptySetPassesAll() {
        var f = LibraryFilter(); f.formats = []
        XCTAssertTrue(comicMatchesFilter(status: .unread, isFavorited: false, format: "cbz", filter: f))
        XCTAssertTrue(comicMatchesFilter(status: .unread, isFavorited: false, format: "pdf", filter: f))
    }

    func testFormatFilterCaseInsensitive() {
        var f = LibraryFilter(); f.formats = ["cbz"]
        XCTAssertTrue(comicMatchesFilter(status: .unread, isFavorited: false, format: "CBZ", filter: f))
    }

    func testFormatFilterMakesFilterActive() {
        var f = LibraryFilter(); f.formats = ["cbz"]
        XCTAssertTrue(f.isActive)
    }

    func testCombinedFilterRequiresAllConditions() {
        var f = LibraryFilter()
        f.status = .finished
        f.favoritedOnly = true
        f.formats = ["pdf"]

        // all three match
        XCTAssertTrue( comicMatchesFilter(status: .finished, isFavorited: true,  format: "pdf", filter: f))
        // wrong status
        XCTAssertFalse(comicMatchesFilter(status: .unread,   isFavorited: true,  format: "pdf", filter: f))
        // not favorited
        XCTAssertFalse(comicMatchesFilter(status: .finished, isFavorited: false, format: "pdf", filter: f))
        // wrong format
        XCTAssertFalse(comicMatchesFilter(status: .finished, isFavorited: true,  format: "cbz", filter: f))
    }
}
