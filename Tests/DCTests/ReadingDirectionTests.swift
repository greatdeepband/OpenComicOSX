import XCTest
@testable import DC

final class ReadingDirectionTests: XCTestCase {

    // MARK: - navStep truth table

    func testNavStep_forwardLTR() {
        XCTAssertEqual(navStep(forwardInput: true, isRTL: false), .next)
    }

    func testNavStep_forwardRTL() {
        XCTAssertEqual(navStep(forwardInput: true, isRTL: true), .prev)
    }

    func testNavStep_backwardLTR() {
        XCTAssertEqual(navStep(forwardInput: false, isRTL: false), .prev)
    }

    func testNavStep_backwardRTL() {
        XCTAssertEqual(navStep(forwardInput: false, isRTL: true), .next)
    }

    // MARK: - spreadSlots

    func testSpreadSlots_LTR() {
        let result = spreadSlots(currentPage: 3, isRTL: false)
        XCTAssertEqual(result.left, 3)
        XCTAssertEqual(result.right, 4)
    }

    func testSpreadSlots_RTL() {
        let result = spreadSlots(currentPage: 3, isRTL: true)
        XCTAssertEqual(result.left, 4)
        XCTAssertEqual(result.right, 3)
    }

    // MARK: - Sticky default (injectable UserDefaults)

    private func makeSuite() -> (UserDefaults, String) {
        let name = "test.dir.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func cleanUp(_ defaults: UserDefaults, name: String) {
        defaults.removePersistentDomain(forName: name)
    }

    func testStickyDefault_noStoredDir_returnsLTR() {
        let (suite, name) = makeSuite()
        defer { cleanUp(suite, name: name) }

        let urlA = URL(fileURLWithPath: "/tmp/comicA.cbz")
        // No direction stored — resolution should fall back to lastReadingDirection ("ltr")
        let resolved = ReadingPositionStore.readingDirection(for: urlA, defaults: suite)
            ?? ReadingPositionStore.lastReadingDirection(defaults: suite)
        XCTAssertEqual(resolved, "ltr")
    }

    func testStickyDefault_saveRTL_setsLastReadingDirection() {
        let (suite, name) = makeSuite()
        defer { cleanUp(suite, name: name) }

        let urlA = URL(fileURLWithPath: "/tmp/comicA.cbz")
        ReadingPositionStore.saveReadingDirection("rtl", for: urlA, defaults: suite)
        XCTAssertEqual(ReadingPositionStore.lastReadingDirection(defaults: suite), "rtl")
    }

    func testStickyDefault_perComicOverridesGlobal() {
        let (suite, name) = makeSuite()
        defer { cleanUp(suite, name: name) }

        let urlA = URL(fileURLWithPath: "/tmp/comicA.cbz")
        let urlB = URL(fileURLWithPath: "/tmp/comicB.cbz")

        // Establish a global RTL via comicA
        ReadingPositionStore.saveReadingDirection("rtl", for: urlA, defaults: suite)
        XCTAssertEqual(ReadingPositionStore.lastReadingDirection(defaults: suite), "rtl")

        // Store an explicit "ltr" for comicB
        ReadingPositionStore.saveReadingDirection("ltr", for: urlB, defaults: suite)

        // comicB should return its own "ltr", not the global "rtl"
        let resolved = ReadingPositionStore.readingDirection(for: urlB, defaults: suite)
            ?? ReadingPositionStore.lastReadingDirection(defaults: suite)
        XCTAssertEqual(resolved, "ltr")
    }
}
