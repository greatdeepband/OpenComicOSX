import XCTest
@testable import DC

/// Tests for ReadingPositionStore round-trip through UserDefaults.standard.
///
/// These tests touch UserDefaults.standard directly (no DI in the production
/// code yet). Each test cleans its own keys in setUp/tearDown so concurrent
/// runs of the host app on the same machine don't leak state into tests and
/// vice-versa. Test URLs use a known prefix (`file:///tmp/dc-test-*`) so
/// real-library entries are never touched.
final class ReadingPositionStoreTests: XCTestCase {

    private let testURL1 = URL(fileURLWithPath: "/tmp/dc-test-comic-A.cbz")
    private let testURL2 = URL(fileURLWithPath: "/tmp/dc-test-comic-B.cbz")

    private let allKeys = [
        "readingPositions",
        "readingModes",
        "scrollOffsets",
        "pageCounts"
    ]

    override func setUp() {
        super.setUp()
        purgeTestEntries()
    }

    override func tearDown() {
        purgeTestEntries()
        super.tearDown()
    }

    /// Strip only the test URLs from each dict, leaving other entries alone.
    private func purgeTestEntries() {
        let defaults = UserDefaults.standard
        for key in allKeys {
            guard var dict = defaults.dictionary(forKey: key) else { continue }
            dict.removeValue(forKey: testURL1.path)
            dict.removeValue(forKey: testURL2.path)
            defaults.set(dict, forKey: key)
        }
    }

    // MARK: - Page

    func testPageDefaultsToZero() {
        XCTAssertEqual(ReadingPositionStore.page(for: testURL1), 0)
    }

    func testPageRoundTrip() {
        ReadingPositionStore.save(page: 42, for: testURL1)
        XCTAssertEqual(ReadingPositionStore.page(for: testURL1), 42)
    }

    func testPagesAreScopedPerURL() {
        ReadingPositionStore.save(page: 10, for: testURL1)
        ReadingPositionStore.save(page: 99, for: testURL2)
        XCTAssertEqual(ReadingPositionStore.page(for: testURL1), 10)
        XCTAssertEqual(ReadingPositionStore.page(for: testURL2), 99)
    }

    // MARK: - Scroll offset

    func testScrollOffsetDefaultsToNil() {
        XCTAssertNil(ReadingPositionStore.scrollOffset(for: testURL1))
    }

    func testScrollOffsetRoundTrip() {
        ReadingPositionStore.save(scrollOffset: 0.375, for: testURL1)
        XCTAssertEqual(ReadingPositionStore.scrollOffset(for: testURL1) ?? -1, 0.375, accuracy: 1e-9)
    }

    // MARK: - Progress

    func testProgressIsZeroForSinglePage() {
        ReadingPositionStore.save(page: 0, for: testURL1)
        XCTAssertEqual(ReadingPositionStore.progress(for: testURL1, totalPages: 1), 0)
    }

    func testProgressIsCorrectMidComic() {
        ReadingPositionStore.save(page: 50, for: testURL1)
        // 50 / (101 - 1) = 0.5
        XCTAssertEqual(
            ReadingPositionStore.progress(for: testURL1, totalPages: 101),
            0.5,
            accuracy: 1e-9
        )
    }

    func testProgressClampsAtFullRead() {
        ReadingPositionStore.save(page: 100, for: testURL1)
        XCTAssertEqual(
            ReadingPositionStore.progress(for: testURL1, totalPages: 101),
            1.0,
            accuracy: 1e-9
        )
    }
}
