import XCTest
@testable import DC

final class ReadingProgressResetTests: XCTestCase {

    func testRemoveReadingProgress_wipesAllKeysAndPreservesBookmarks() {
        let suiteName = "test.F9.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }

        // Seed all 6 reading-progress keys with non-nil values.
        d.set(["comic1": 3], forKey: "readingPositions")
        d.set(["comic1": 0.5], forKey: "scrollOffsets")
        d.set(["comic1": "rtl"], forKey: "readingModes")
        d.set(["comic1": 24], forKey: "pageCounts")
        d.set(2, forKey: "scrollPagesPerRow")
        d.set(["comic1", "comic2"], forKey: "recentComics")

        // Seed a key that must NOT be removed.
        d.set("keep-me", forKey: "bookmarks")

        // Act.
        LibraryViewModel.removeReadingProgress(from: d)

        // Assert: all 6 reading-progress keys are gone.
        XCTAssertNil(d.object(forKey: "readingPositions"),  "readingPositions should be removed")
        XCTAssertNil(d.object(forKey: "scrollOffsets"),     "scrollOffsets should be removed")
        XCTAssertNil(d.object(forKey: "readingModes"),      "readingModes should be removed")
        XCTAssertNil(d.object(forKey: "pageCounts"),        "pageCounts should be removed")
        XCTAssertNil(d.object(forKey: "scrollPagesPerRow"), "scrollPagesPerRow should be removed")
        XCTAssertNil(d.object(forKey: "recentComics"),      "recentComics should be removed")

        // Assert: unrelated key survives (bookmark-safe seam).
        XCTAssertEqual(d.string(forKey: "bookmarks"), "keep-me",
                       "bookmarks key must not be touched by removeReadingProgress")
    }
}
