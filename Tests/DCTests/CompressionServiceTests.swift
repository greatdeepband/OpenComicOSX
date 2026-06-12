import XCTest
@testable import DC

final class CompressionServiceTests: XCTestCase {

    /// Each test gets a private scratch directory so the filesystem-existence
    /// checks in `backupURL` operate on a clean slate.
    private func makeScratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dc-compsvc-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_backupURL_noCollision_usesPlainOriginalSuffix() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let comic = dir.appendingPathComponent("Foo.cbz")
        try Data("comic".utf8).write(to: comic)

        let backup = CompressionService.backupURL(for: comic)
        XCTAssertEqual(backup.lastPathComponent, "Foo-original.cbz")
    }

    /// The data-loss fix: when `Foo-original.cbz` already exists (a pristine
    /// backup from a prior compression, or an unrelated user file), the helper
    /// must NOT return that path — returning it would let the caller overwrite
    /// it. It must skip to the next free name.
    func test_backupURL_existingBackup_isNeverReturned() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let comic = dir.appendingPathComponent("Foo.cbz")
        try Data("compressed".utf8).write(to: comic)
        let pristine = dir.appendingPathComponent("Foo-original.cbz")
        try Data("PRISTINE".utf8).write(to: pristine)

        let backup = CompressionService.backupURL(for: comic)
        XCTAssertEqual(backup.lastPathComponent, "Foo-original-2.cbz")
        XCTAssertNotEqual(backup.path, pristine.path,
                          "Must never hand back the existing backup's path")
        // The existing pristine backup must be byte-for-byte intact.
        XCTAssertEqual(try Data(contentsOf: pristine), Data("PRISTINE".utf8))
    }

    func test_backupURL_multipleCollisions_incrementsToFirstFree() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let comic = dir.appendingPathComponent("Foo.cbz")
        try Data("c".utf8).write(to: comic)
        for name in ["Foo-original.cbz", "Foo-original-2.cbz", "Foo-original-3.cbz"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        let backup = CompressionService.backupURL(for: comic)
        XCTAssertEqual(backup.lastPathComponent, "Foo-original-4.cbz")
    }
}
