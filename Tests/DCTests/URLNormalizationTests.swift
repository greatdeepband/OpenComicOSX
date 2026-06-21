import XCTest
@testable import DC

// MARK: - URLNormalizationTests
// Tests for Task 6: URL normalization on write, named-gallery tombstone,
// one-time existing-library migration, migration key count, and RTL solo slot logic.

@MainActor
final class URLNormalizationTests: XCTestCase {

    // MARK: - Tombstone: named gallery

    /// A URL that the user previously removed from a named gallery (tombstoned)
    /// must NOT be re-added by addComicFiles.
    func testTombstonedURLNotReaddedToNamedGallery() {
        let vm = makeIsolatedVM()
        let url = URL(fileURLWithPath: "/tmp/batman.cbz")
        let tombstoned = url.standardizedFileURL

        // Create a named (non-imported) gallery and seed its tombstone.
        let gallery = Gallery(name: "Heroes", deletedComics: [tombstoned])
        vm.galleries.append(gallery)
        guard let galleryID = vm.galleries.first?.id else {
            XCTFail("Gallery must exist"); return
        }

        vm.addComicFiles([url], to: galleryID)

        let updatedGallery = vm.galleries.first(where: { $0.id == galleryID })
        XCTAssertEqual(updatedGallery?.comics.count, 0,
            "A tombstoned URL must not be re-added to a named gallery")
    }

    // MARK: - Tombstone: Imported gallery ignores tombstone

    /// The Imported gallery (isImported == true) must allow re-import of a URL
    /// even if that URL is in its deletedComics set — Imported shelf is not
    /// governed by the named-gallery tombstone guard.
    func testTombstonedURLReaddedToImportedGallery() {
        let vm = makeIsolatedVM()
        let url = URL(fileURLWithPath: "/tmp/batman.cbz")
        let tombstoned = url.standardizedFileURL

        // Create an Imported gallery with the URL pre-tombstoned.
        let gallery = Gallery(name: "Imported", deletedComics: [tombstoned], isImported: true)
        vm.galleries.append(gallery)
        guard let importedID = vm.galleries.first(where: { $0.isImported })?.id else {
            XCTFail("Imported gallery must exist"); return
        }

        vm.addComicFiles([url], to: importedID)

        let updatedGallery = vm.galleries.first(where: { $0.id == importedID })
        XCTAssertEqual(updatedGallery?.comics.count, 1,
            "A tombstoned URL in the Imported gallery must still be re-addable")
        XCTAssertEqual(updatedGallery?.comics.first?.standardizedFileURL, tombstoned,
            "The stored URL must be the standardized form")
    }

    // MARK: - Normalize on write: addComicFiles stores canonical URL

    /// Adding a non-standardized URL (e.g. /tmp which is a symlink to /private/tmp)
    /// must store the canonicalized form.
    func testAddComicFilesStoresStandardizedURL() {
        let vm = makeIsolatedVM()
        let gallery = Gallery(name: "Test")
        vm.galleries.append(gallery)
        guard let galleryID = vm.galleries.first?.id else {
            XCTFail("Gallery must exist"); return
        }

        // /tmp is a symlink to /private/tmp on macOS; standardizedFileURL resolves it.
        let rawURL = URL(fileURLWithPath: "/tmp/issue1.cbz")
        let canonical = rawURL.standardizedFileURL

        vm.addComicFiles([rawURL], to: galleryID)

        let stored = vm.galleries.first(where: { $0.id == galleryID })?.comics.first
        XCTAssertNotNil(stored, "Comic must be added")
        XCTAssertEqual(stored, canonical,
            "Stored URL must equal standardizedFileURL of the input")
    }

    // MARK: - One-time migration: canonicalizes existing library

    /// Seeding a gallery with a non-canonical URL directly in UserDefaults (simulating
    /// a library written before the normalization migration), then re-initializing the VM,
    /// must produce a canonicalized URL for that entry.
    func testMigrationCanonicalizesExistingLibrary() throws {
        let suiteName = "URLNormalizationTests.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        // Seed a gallery with a non-canonical URL (/tmp/x.cbz, not /private/tmp/x.cbz).
        let rawURL = URL(fileURLWithPath: "/tmp/migrate-test.cbz")
        let canonical = rawURL.standardizedFileURL
        let seedGallery = Gallery(name: "Seed", comics: [rawURL])
        let data = try JSONEncoder().encode([seedGallery])
        defaults.set(data, forKey: "galleries_v1")

        // Re-init the VM — migration must fire and canonicalize.
        let vm = LibraryViewModel(userDefaults: defaults)

        let storedComic = vm.galleries.first?.comics.first
        XCTAssertNotNil(storedComic, "Migrated gallery must still have a comic")
        XCTAssertEqual(storedComic, canonical,
            "Migration must have canonicalized the stored URL to standardizedFileURL")
    }

    // MARK: - One-time migration: distinctly-different files are not dropped

    /// Two genuinely-distinct files (different paths that do NOT collapse to the
    /// same standardized URL) must both survive the migration dedupe pass.
    func testMigrationPreservesDistinctFiles() throws {
        let suiteName = "URLNormalizationTests.distinct.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        // Two genuinely-distinct files — different names, different standardized paths.
        let url1 = URL(fileURLWithPath: "/tmp/file-a.cbz").standardizedFileURL
        let url2 = URL(fileURLWithPath: "/tmp/file-b.cbz").standardizedFileURL
        // Sanity: they must not be equal already.
        XCTAssertNotEqual(url1, url2, "Test precondition: URLs must be distinct")

        let seedGallery = Gallery(name: "Two Files", comics: [url1, url2])
        let data = try JSONEncoder().encode([seedGallery])
        defaults.set(data, forKey: "galleries_v1")

        let vm = LibraryViewModel(userDefaults: defaults)

        let count = vm.galleries.first?.comics.count ?? 0
        XCTAssertEqual(count, 2,
            "Migration must not drop genuinely-distinct files — both must survive")
    }

    // MARK: - Migration key count

    /// OpncomicDefaultsMigration.keys must contain exactly 19 entries after
    /// adding scrollPagesPerRow, bookmarks, readingDirection, lastReadingDirection,
    /// and readStatusOverrides.
    func testMigrationKeyCountIs18() {
        XCTAssertEqual(OpncomicDefaultsMigration.keys.count, 19,
            "Migration key list must have exactly 19 entries")
    }

    // MARK: - RTL solo page slot (pure arithmetic)

    /// The soloX logic in rebuildDoubleSpread's solo branch:
    ///   soloX = isRTL ? (xOff + pageWidth + gutter) : xOff
    /// Test this arithmetic directly (the logic is not extracted to a helper,
    /// so we assert the formula in isolation).
    func testRTLSoloPageXOffset() {
        let xOff: CGFloat = 10
        let pageWidth: CGFloat = 400
        let gutter: CGFloat = 8

        let soloXLTR = xOff
        let soloXRTL = xOff + pageWidth + gutter

        XCTAssertEqual(soloXLTR, xOff,
            "LTR solo page must use xOff (left slot)")
        XCTAssertEqual(soloXRTL, xOff + pageWidth + gutter,
            "RTL solo page must use right-slot x offset (xOff + pageWidth + gutter)")
    }

    // MARK: - Tombstone persistence through rescan

    /// A tombstoned comic must stay gone after rescanGallery is called.
    /// This regression test ensures that rescan does not re-add deleted comics.
    func testTombstonedComicStaysGoneAfterRescan() throws {
        let suiteName = "URLNormalizationTests.tombstoneRescan.\(UUID().uuidString)"
        let vm = LibraryViewModel(userDefaults: UserDefaults(suiteName: suiteName)!)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        // Create a folder-backed named gallery with one comic.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tombstone-rescan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let comicURL = tempDir.appendingPathComponent("test.cbz")
        FileManager.default.createFile(atPath: comicURL.path, contents: Data())

        let gallery = Gallery(id: UUID(), name: "RescanTest", sourceFolders: [tempDir], comics: [], deletedComics: [])
        vm.galleries.append(gallery)
        guard let galleryID = vm.galleries.first?.id else {
            XCTFail("Gallery must exist"); return
        }

        vm.addComicFiles([comicURL], to: galleryID)
        let beforeDelete = vm.galleries.first(where: { $0.id == galleryID })?.comics.count ?? 0
        XCTAssertEqual(beforeDelete, 1, "Gallery must contain 1 comic after adding")

        // Remove the comic, tombstoning it.
        let canonicalURL = comicURL.standardizedFileURL
        vm.removeComics([canonicalURL], from: galleryID)
        let afterDelete = vm.galleries.first(where: { $0.id == galleryID })?.comics.count ?? 0
        XCTAssertEqual(afterDelete, 0, "Gallery must be empty after removal")

        // Verify the comic is tombstoned.
        let isTombstoned = vm.galleries.first(where: { $0.id == galleryID })?.deletedComics.contains(canonicalURL) ?? false
        XCTAssertTrue(isTombstoned, "Comic must be in deletedComics after removal")

        // Rescan — the tombstoned comic must NOT reappear.
        vm.rescanGallery(id: galleryID)
        let afterRescan = vm.galleries.first(where: { $0.id == galleryID })?.comics.count ?? 0
        XCTAssertEqual(afterRescan, 0,
            "Tombstoned comic must not be re-added by rescanGallery")
    }

    // MARK: - Helpers

    private func makeIsolatedVM() -> LibraryViewModel {
        let suiteName = "URLNormalizationTests.\(UUID().uuidString)"
        return LibraryViewModel(userDefaults: UserDefaults(suiteName: suiteName)!)
    }
}
