import XCTest
@testable import DC

/// Tests for F11: cross-session resume layout-awareness guard.
/// All tests use an isolated UserDefaults suite so they never touch .standard.
final class ResumeGuardTests: XCTestCase {

    private let testURL = URL(fileURLWithPath: "/tmp/dc-test-resume-guard.cbz")

    // MARK: - Round-trip

    func testScrollPagesPerRowRoundTrip() {
        let suiteName = "test.F11.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }

        ReadingPositionStore.save(scrollPagesPerRow: 2, for: testURL, defaults: d)
        XCTAssertEqual(ReadingPositionStore.scrollPagesPerRow(for: testURL, defaults: d), 2)
    }

    func testScrollPagesPerRowDefaultsToNil() {
        let suiteName = "test.F11.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(ReadingPositionStore.scrollPagesPerRow(for: testURL, defaults: d))
    }

    // MARK: - Predicate

    func testShouldUseSavedOffset_matchingLayouts_returnsTrue() {
        XCTAssertTrue(ReadingPositionStore.shouldUseSavedOffset(savedPagesPerRow: 2, currentPagesPerRow: 2))
    }

    func testShouldUseSavedOffset_mismatchedLayouts_returnsFalse() {
        XCTAssertFalse(ReadingPositionStore.shouldUseSavedOffset(savedPagesPerRow: 2, currentPagesPerRow: 1))
    }

    func testShouldUseSavedOffset_nilSaved_returnsFalse() {
        XCTAssertFalse(ReadingPositionStore.shouldUseSavedOffset(savedPagesPerRow: nil, currentPagesPerRow: 1))
    }
}
