import XCTest
@testable import DC

final class MigrationTests: XCTestCase {

    func test_migration_copiesKeys_idempotent_noOverwrite() {
        // Use throwaway suite names so the test never touches production
        // com.opncomic / com.opencomic prefs domains.
        let oldName = "com.opncomic.open-comic.test-\(UUID().uuidString)"
        let stdName = "com.opencomic.open-comic.test-\(UUID().uuidString)"
        let old = UserDefaults(suiteName: oldName)!, std = UserDefaults(suiteName: stdName)!
        defer {
            UserDefaults().removePersistentDomain(forName: oldName)
            UserDefaults().removePersistentDomain(forName: stdName)
        }

        // Seed old domain with two keys.
        old.set("grid", forKey: "library.cardSize")
        old.set(Data([1, 2, 3]), forKey: "galleries_v1")

        // Pre-existing value in the new domain must NOT be overwritten.
        std.set("PRESET", forKey: "library.cardSize")

        OpncomicDefaultsMigration.runIfNeeded(standard: std, oldSuiteName: oldName)

        // galleries_v1 was absent in new domain — must be copied.
        XCTAssertEqual(std.data(forKey: "galleries_v1"), Data([1, 2, 3]))
        // library.cardSize was pre-set in new domain — must NOT be overwritten.
        XCTAssertEqual(std.string(forKey: "library.cardSize"), "PRESET")
        // Migration flag must be set.
        XCTAssertTrue(std.bool(forKey: OpncomicDefaultsMigration.flag))

        // 2nd run is a no-op: even if old domain changes, std must not change.
        old.set("rebel", forKey: "library.cardSize")
        old.set(Data([9, 9]), forKey: "galleries_v1")
        OpncomicDefaultsMigration.runIfNeeded(standard: std, oldSuiteName: oldName)
        XCTAssertEqual(std.string(forKey: "library.cardSize"), "PRESET")
        XCTAssertEqual(std.data(forKey: "galleries_v1"), Data([1, 2, 3]))
    }
}
