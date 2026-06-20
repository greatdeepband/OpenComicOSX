import XCTest
@testable import DC

final class CompressionPreferencesTests: XCTestCase {

    func test_hasRememberedChoice_falseInitially() {
        let suiteName = "test.F8.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(CompressionPreferences.hasRememberedChoice(defaults: d))
    }

    func test_remember_setsHasRememberedChoiceAndValues() {
        let suiteName = "test.F8.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        CompressionPreferences.remember(deleteOriginals: false, convertPNGs: true, defaults: d)

        XCTAssertTrue(CompressionPreferences.hasRememberedChoice(defaults: d))
        XCTAssertFalse(CompressionPreferences.rememberedDeleteOriginals(defaults: d))
        XCTAssertTrue(CompressionPreferences.rememberedConvertPNGs(defaults: d))
    }

    func test_reset_clearsHasRememberedChoice() {
        let suiteName = "test.F8.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        CompressionPreferences.remember(deleteOriginals: true, convertPNGs: false, defaults: d)
        XCTAssertTrue(CompressionPreferences.hasRememberedChoice(defaults: d))

        CompressionPreferences.reset(defaults: d)
        XCTAssertFalse(CompressionPreferences.hasRememberedChoice(defaults: d))
    }
}
