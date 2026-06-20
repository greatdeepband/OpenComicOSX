import XCTest
@testable import DC

final class BookmarksTests: XCTestCase {

    // MARK: - Helpers

    private func makeSuite() -> (UserDefaults, String) {
        let name = "test.bm.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func cleanUp(_ defaults: UserDefaults, name: String) {
        defaults.removePersistentDomain(forName: name)
    }

    private let comicURL = URL(fileURLWithPath: "/tmp/test-bookmarks-comic.cbz")

    // MARK: - Toggle adds and removes

    func testToggle_addsPage() {
        let (d, name) = makeSuite()
        defer { cleanUp(d, name: name) }

        ReadingPositionStore.toggleBookmark(page: 3, for: comicURL, defaults: d)
        XCTAssertTrue(ReadingPositionStore.bookmarks(for: comicURL, defaults: d).contains(3))
    }

    func testToggle_removesExistingPage() {
        let (d, name) = makeSuite()
        defer { cleanUp(d, name: name) }

        ReadingPositionStore.toggleBookmark(page: 3, for: comicURL, defaults: d)
        ReadingPositionStore.toggleBookmark(page: 3, for: comicURL, defaults: d)
        XCTAssertFalse(ReadingPositionStore.bookmarks(for: comicURL, defaults: d).contains(3))
    }

    // MARK: - isBookmarked reflects toggle state

    func testIsBookmarked_trueAfterAdd() {
        let (d, name) = makeSuite()
        defer { cleanUp(d, name: name) }

        ReadingPositionStore.toggleBookmark(page: 7, for: comicURL, defaults: d)
        XCTAssertTrue(ReadingPositionStore.isBookmarked(page: 7, for: comicURL, defaults: d))
    }

    func testIsBookmarked_falseAfterRemove() {
        let (d, name) = makeSuite()
        defer { cleanUp(d, name: name) }

        ReadingPositionStore.toggleBookmark(page: 7, for: comicURL, defaults: d)
        ReadingPositionStore.toggleBookmark(page: 7, for: comicURL, defaults: d)
        XCTAssertFalse(ReadingPositionStore.isBookmarked(page: 7, for: comicURL, defaults: d))
    }

    // MARK: - Sorted order

    func testBookmarks_areSortedAscending() {
        let (d, name) = makeSuite()
        defer { cleanUp(d, name: name) }

        ReadingPositionStore.toggleBookmark(page: 5, for: comicURL, defaults: d)
        ReadingPositionStore.toggleBookmark(page: 1, for: comicURL, defaults: d)
        ReadingPositionStore.toggleBookmark(page: 3, for: comicURL, defaults: d)
        XCTAssertEqual(ReadingPositionStore.bookmarks(for: comicURL, defaults: d), [1, 3, 5])
    }

    // MARK: - Survival: "bookmarks" survives the cache-clear key wipe

    func testBookmarks_survivesCacheKeyWipe() {
        let name = "test.bm.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }

        let cacheKeys = ["readingPositions", "scrollOffsets", "readingModes", "pageCounts", "recentComics"]

        // Seed every cache key AND "bookmarks" into the injected suite.
        for key in cacheKeys {
            d.set(["seed": "value"], forKey: key)
        }
        ReadingPositionStore.toggleBookmark(page: 2, for: comicURL, defaults: d)
        XCTAssertTrue(ReadingPositionStore.isBookmarked(page: 2, for: comicURL, defaults: d),
                      "Precondition: bookmark should be present before wipe")

        // Simulate clearAllCache's 5-key wipe (bookmarks intentionally excluded).
        for key in cacheKeys {
            d.removeObject(forKey: key)
        }

        // Bookmarks must survive.
        XCTAssertTrue(
            ReadingPositionStore.isBookmarked(page: 2, for: comicURL, defaults: d),
            "Bookmarks must survive clearAllCache's key wipe — they are user intent, not cache"
        )
    }
}
