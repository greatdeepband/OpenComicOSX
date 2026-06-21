import XCTest
@testable import DC

final class ReadingStatusTests: XCTestCase {

    // MARK: - effectiveStatus: override precedence

    func testFinishedOverrideWinsRegardlessOfPage() {
        XCTAssertEqual(effectiveStatus(override: .finished, page: 0, total: 0), .finished)
        XCTAssertEqual(effectiveStatus(override: .finished, page: 0, total: 1), .finished)
        XCTAssertEqual(effectiveStatus(override: .finished, page: 5, total: 100), .finished)
    }

    func testUnreadOverrideWinsRegardlessOfPage() {
        XCTAssertEqual(effectiveStatus(override: .unread, page: 49, total: 50), .unread)
        XCTAssertEqual(effectiveStatus(override: .unread, page: 100, total: 100), .unread)
    }

    // MARK: - effectiveStatus: auto-derive (no override)

    func testTotalZeroOrOneIsUnread() {
        XCTAssertEqual(effectiveStatus(override: nil, page: 0, total: 0), .unread)
        XCTAssertEqual(effectiveStatus(override: nil, page: 1, total: 1), .unread)
    }

    func testPageZeroIsUnread() {
        XCTAssertEqual(effectiveStatus(override: nil, page: 0, total: 50), .unread)
    }

    func testNearlyFinishedIsFinished() {
        // page=49, total=50 → f = 49/49 = 1.0 ≥ 0.98 → finished
        XCTAssertEqual(effectiveStatus(override: nil, page: 49, total: 50), .finished)
    }

    func testExactly098IsFinished() {
        // f = 0.98 → finished (>= threshold)
        // total=51, page=49+? — compute: need f=0.98 exactly → page/(total-1)=0.98
        // Use total=51 → total-1=50, page=49 → f=0.98 exactly
        XCTAssertEqual(effectiveStatus(override: nil, page: 49, total: 51), .finished)
    }

    func testBelowThresholdIsInProgress() {
        // f = 0.97 → inProgress
        // total=101 → total-1=100, page=97 → f=0.97
        let result = effectiveStatus(override: nil, page: 97, total: 101)
        if case .inProgress(let f) = result {
            XCTAssertEqual(f, 0.97, accuracy: 1e-10)
        } else {
            XCTFail("Expected .inProgress(0.97), got \(result)")
        }
    }

    // MARK: - Store round-trip (injectable UserDefaults suite)

    private var testSuite: UserDefaults!
    private let suiteName = "com.opencomic.test.ReadingStatusTests"

    override func setUp() {
        super.setUp()
        testSuite = UserDefaults(suiteName: suiteName)!
        testSuite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        testSuite.removePersistentDomain(forName: suiteName)
        testSuite = nil
        super.tearDown()
    }

    func testSetAndReadBackFinished() {
        let url = URL(fileURLWithPath: "/test/comic.cbz")
        ReadingPositionStore.setReadStatusOverride(.finished, for: url, defaults: testSuite)
        XCTAssertEqual(ReadingPositionStore.readStatusOverride(for: url, defaults: testSuite), .finished)
    }

    func testSetAndReadBackUnread() {
        let url = URL(fileURLWithPath: "/test/comic.cbz")
        ReadingPositionStore.setReadStatusOverride(.unread, for: url, defaults: testSuite)
        XCTAssertEqual(ReadingPositionStore.readStatusOverride(for: url, defaults: testSuite), .unread)
    }

    func testClearReturnsNil() {
        let url = URL(fileURLWithPath: "/test/comic.cbz")
        ReadingPositionStore.setReadStatusOverride(.finished, for: url, defaults: testSuite)
        ReadingPositionStore.setReadStatusOverride(nil, for: url, defaults: testSuite)
        XCTAssertNil(ReadingPositionStore.readStatusOverride(for: url, defaults: testSuite))
    }

    func testAbsentKeyReturnsNil() {
        let url = URL(fileURLWithPath: "/test/never-set.cbz")
        XCTAssertNil(ReadingPositionStore.readStatusOverride(for: url, defaults: testSuite))
    }

    func testTwoDifferentURLsAreIndependent() {
        let url1 = URL(fileURLWithPath: "/test/comic1.cbz")
        let url2 = URL(fileURLWithPath: "/test/comic2.cbz")
        ReadingPositionStore.setReadStatusOverride(.finished, for: url1, defaults: testSuite)
        ReadingPositionStore.setReadStatusOverride(.unread, for: url2, defaults: testSuite)
        XCTAssertEqual(ReadingPositionStore.readStatusOverride(for: url1, defaults: testSuite), .finished)
        XCTAssertEqual(ReadingPositionStore.readStatusOverride(for: url2, defaults: testSuite), .unread)
    }
}
