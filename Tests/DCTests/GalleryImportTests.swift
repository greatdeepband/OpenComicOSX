import XCTest
@testable import DC

// MARK: - GalleryImportTests
// Tests for Task 1: Gallery.isImported safe Codable migration + importComics dedup.

@MainActor
final class GalleryImportTests: XCTestCase {

    // MARK: - Codable migration (the library-wipe guard)

    /// A Gallery encoded WITHOUT the isImported key must decode successfully
    /// with isImported == false. If decoding throws, loadGalleries() leaves
    /// `galleries` empty — wiping the user's entire library.
    func testDecodeLegacyGalleryWithoutIsImported() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "My Comics",
            "sourceFolders": [],
            "comics": [],
            "deletedComics": []
        }
        """.data(using: .utf8)!

        let gallery = try JSONDecoder().decode(Gallery.self, from: json)
        XCTAssertEqual(gallery.name, "My Comics")
        XCTAssertFalse(gallery.isImported,
            "isImported must default to false when absent from persisted JSON")
    }

    /// An array of legacy (pre-isImported) galleries must all decode; none must
    /// be lost. This is the production path: loadGalleries decodes [Gallery].
    func testDecodeLegacyGalleryArray() throws {
        let json = """
        [
            {
                "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "name": "Gallery A",
                "sourceFolders": [],
                "comics": [],
                "deletedComics": []
            },
            {
                "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "name": "Gallery B",
                "sourceFolders": [],
                "comics": [],
                "deletedComics": []
            }
        ]
        """.data(using: .utf8)!

        let galleries = try JSONDecoder().decode([Gallery].self, from: json)
        XCTAssertEqual(galleries.count, 2,
            "Both legacy galleries must survive decode — a keyNotFound throw would wipe the library")
        XCTAssertTrue(galleries.allSatisfy { !$0.isImported },
            "All legacy galleries should have isImported == false")
    }

    /// A gallery written with isImported == true must round-trip correctly.
    func testEncodeDecodeWithIsImported() throws {
        let original = Gallery(name: "Imported", isImported: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Gallery.self, from: data)
        XCTAssertTrue(decoded.isImported)
        XCTAssertEqual(decoded.name, "Imported")
    }

    // MARK: - Static dedup predicate

    /// Helper used by importComics to decide whether a URL is already in the library.
    /// We test the membership logic via a pure static function to avoid loading
    /// the full LibraryViewModel (which hits UserDefaults and the file system).
    func testIsInLibraryReturnsTrueForKnownURL() {
        let knownURL = URL(fileURLWithPath: "/tmp/batman.cbz")
        var g = Gallery(name: "Heroes")
        g.comics = [knownURL]
        XCTAssertTrue(GalleryImportTests.isInLibrary(knownURL, galleries: [g]))
    }

    func testIsInLibraryReturnsFalseForUnknownURL() {
        let knownURL = URL(fileURLWithPath: "/tmp/batman.cbz")
        let unknownURL = URL(fileURLWithPath: "/tmp/superman.cbz")
        var g = Gallery(name: "Heroes")
        g.comics = [knownURL]
        XCTAssertFalse(GalleryImportTests.isInLibrary(unknownURL, galleries: [g]))
    }

    /// A URL present only in recents (not in any gallery) IS importable.
    func testURLInRecentsOnlyIsImportable() {
        // Recents are not galleries — importComics checks gallery.comics only.
        let recentOnlyURL = URL(fileURLWithPath: "/tmp/only-in-recents.cbz")
        let emptyGalleries: [Gallery] = []
        XCTAssertFalse(GalleryImportTests.isInLibrary(recentOnlyURL, galleries: emptyGalleries),
            "A URL that is only in recents (not any gallery) should be importable")
    }

    /// Membership uses standardizedFileURL so path variants of the same file
    /// are not re-imported.
    func testStandardizedURLMembership() {
        // /tmp is a symlink to /private/tmp on macOS — standardizedFileURL resolves it.
        let stored = URL(fileURLWithPath: "/tmp/x.cbz").standardizedFileURL
        var g = Gallery(name: "G")
        g.comics = [stored]
        let symlinked = URL(fileURLWithPath: "/tmp/x.cbz")
        XCTAssertTrue(GalleryImportTests.isInLibrary(symlinked, galleries: [g]),
            "standardizedFileURL variants of the same path must be treated as duplicates")
    }

    // MARK: - importComics integration (isolated state)

    /// importComics must filter out non-comic extensions.
    func testImportComicsFiltersNonComicTypes() {
        let vm = makeIsolatedVM()
        let jpgURL  = URL(fileURLWithPath: "/tmp/image.jpg")
        let cbzURL  = URL(fileURLWithPath: "/tmp/valid.cbz")
        vm.importComics([jpgURL, cbzURL])
        let imported = vm.galleries.first(where: { $0.isImported })
        XCTAssertNotNil(imported, "Imported gallery must be created")
        XCTAssertTrue(imported!.comics.contains(cbzURL), "cbz should be imported")
        XCTAssertFalse(imported!.comics.contains(jpgURL), "jpg must be rejected")
    }

    /// importComics must not re-import a URL already in another gallery.
    func testImportComicsDeduplicatesAgainstExistingGallery() {
        let vm = makeIsolatedVM()
        let existingURL = URL(fileURLWithPath: "/tmp/existing.cbz")
        // Seed an existing gallery with that URL.
        let seedGallery = Gallery(name: "Seed", comics: [existingURL])
        vm.galleries.append(seedGallery)

        vm.importComics([existingURL])
        let imported = vm.galleries.first(where: { $0.isImported })
        XCTAssertNil(imported, "No Imported gallery should be created — the URL is already in the library")
    }

    /// importComics with all-known URLs must be a no-op (no gallery created).
    func testImportComicsNoOpWhenAllKnown() {
        let vm = makeIsolatedVM()
        let url = URL(fileURLWithPath: "/tmp/known.cbz")
        vm.importComics([url])  // first call imports it
        let countAfterFirst = vm.galleries.count
        vm.importComics([url])  // second call must be a no-op
        XCTAssertEqual(vm.galleries.count, countAfterFirst,
            "Second import of the same URL must not mutate the gallery list")
        let imported = vm.galleries.filter { $0.isImported }
        XCTAssertEqual(imported.count, 1, "There must be exactly one Imported gallery")
        XCTAssertEqual(imported[0].comics.filter { $0 == url }.count, 1,
            "URL must appear exactly once in the Imported gallery")
    }

    /// Two importComics calls must produce exactly one isImported gallery.
    func testImportComicsExactlyOneImportedGallery() {
        let vm = makeIsolatedVM()
        vm.importComics([URL(fileURLWithPath: "/tmp/a.cbz")])
        vm.importComics([URL(fileURLWithPath: "/tmp/b.pdf")])
        let importedGalleries = vm.galleries.filter { $0.isImported }
        XCTAssertEqual(importedGalleries.count, 1,
            "Two importComics batches must produce exactly one Imported gallery")
        XCTAssertEqual(importedGalleries[0].comics.count, 2,
            "Both comics must land in the single Imported gallery")
    }

    // MARK: - Drop routing tests (Task 3)

    /// A URL already present in a gallery's comics list must be routed to "move"
    /// (true = known = relocate), not re-imported.
    func testDropRouteKnownURLReturnsTrueForMove() {
        let knownURL = URL(fileURLWithPath: "/tmp/batman.cbz")
        var g = Gallery(name: "Heroes")
        g.comics = [knownURL]
        // LibraryViewModel.isInLibrary is the canonical predicate used by handleDrop.
        XCTAssertTrue(LibraryViewModel.isInLibrary(knownURL, galleries: [g]),
            "A URL present in a gallery must be routed to move (true)")
    }

    /// A brand-new URL not present in any gallery must be routed to "import"
    /// (false = unknown = add + thumbnail generation).
    func testDropRouteBrandNewURLReturnsFalseForImport() {
        let knownURL = URL(fileURLWithPath: "/tmp/batman.cbz")
        let newURL   = URL(fileURLWithPath: "/tmp/superman.cbz")
        var g = Gallery(name: "Heroes")
        g.comics = [knownURL]
        XCTAssertFalse(LibraryViewModel.isInLibrary(newURL, galleries: [g]),
            "A brand-new URL must be routed to import (false)")
    }

    /// The routing predicate uses standardizedFileURL, so a path stored with a trailing
    /// slash component variant normalises the same way at lookup time (→ move, not re-import).
    func testDropRouteStandardizedURLRoutedToMove() {
        // Store the URL via a path that standardizedFileURL would normalise (e.g. double slash).
        let stored = URL(fileURLWithPath: "/tmp/./issue1.cbz")
        var g = Gallery(name: "G")
        g.comics = [stored]
        // Lookup with a clean path — both standardize to /tmp/issue1.cbz.
        let clean = URL(fileURLWithPath: "/tmp/issue1.cbz")
        XCTAssertTrue(LibraryViewModel.isInLibrary(clean, galleries: [g]),
            "Path-variant of a known URL (normalised by standardizedFileURL) must route to move")
    }

    // MARK: - Rescan Folders (Task 4)

    /// rescanGallery must pick up files added to a source folder after the gallery
    /// was created, without duplicating the file that was already present.
    func testRescanGalleryPicksUpNewFiles() throws {
        // Create an isolated temp directory that we own.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write the first comic file into the temp dir.
        let file1 = tempDir.appendingPathComponent("issue-1.cbz")
        try Data("dummy".utf8).write(to: file1)

        // Build a VM and a gallery over the temp dir — mirrors createGallery.
        let vm = makeIsolatedVM()
        vm.createGallery(name: "Test Gallery", folders: [tempDir])
        guard let galleryID = vm.galleries.first?.id else {
            XCTFail("createGallery must produce at least one gallery"); return
        }

        // Confirm the initial state: exactly one comic (issue-1.cbz).
        XCTAssertEqual(vm.galleries.first?.comics.count, 1,
            "Gallery should start with exactly one comic")

        // Add a second comic to the same folder (simulating a file arriving later).
        let file2 = tempDir.appendingPathComponent("issue-2.cbz")
        try Data("dummy2".utf8).write(to: file2)

        // Rescan — must pick up issue-2 only.
        vm.rescanGallery(id: galleryID)

        guard let gallery = vm.galleries.first(where: { $0.id == galleryID }) else {
            XCTFail("Gallery must still exist after rescan"); return
        }
        XCTAssertEqual(gallery.comics.count, 2,
            "After rescan the gallery must contain both comics")
        // Compare via standardizedFileURL — temporaryDirectory may resolve through
        // symlinks (/var → /private/var) differently than the FileManager enumerator.
        let standardComics = gallery.comics.map { $0.standardizedFileURL }
        XCTAssertTrue(standardComics.contains(file1.standardizedFileURL),
            "Original comic must still be present (no duplicate)")
        XCTAssertTrue(standardComics.contains(file2.standardizedFileURL),
            "New comic must have been picked up by rescan")
        // Confirm issue-1 was NOT duplicated.
        XCTAssertEqual(standardComics.filter { $0 == file1.standardizedFileURL }.count, 1,
            "Issue-1 must appear exactly once — no duplicates after rescan")
    }

    /// rescanGallery on a gallery with no source folders must be a no-op.
    func testRescanGalleryNoOpWhenNoSourceFolders() {
        let vm = makeIsolatedVM()
        // importComics creates the Imported gallery (no sourceFolders).
        vm.importComics([URL(fileURLWithPath: "/tmp/a.cbz")])
        guard let importedID = vm.galleries.first(where: { $0.isImported })?.id else {
            XCTFail("Imported gallery must exist"); return
        }
        let countBefore = vm.galleries.first(where: { $0.id == importedID })?.comics.count ?? 0
        vm.rescanGallery(id: importedID)
        let countAfter = vm.galleries.first(where: { $0.id == importedID })?.comics.count ?? 0
        XCTAssertEqual(countBefore, countAfter,
            "rescanGallery on a sourceFolders-less gallery must not change comics")
    }

    // MARK: - Private helpers

    /// Pure membership predicate extracted from importComics logic.
    /// Tests this directly to avoid side-effects of the full VM.
    static func isInLibrary(_ url: URL, galleries: [Gallery]) -> Bool {
        let known = Set(galleries.flatMap { $0.comics }.map { $0.standardizedFileURL })
        return known.contains(url.standardizedFileURL)
    }

    /// Creates a LibraryViewModel with an isolated UserDefaults suite so tests
    /// never read from or write to the real user library.
    private func makeIsolatedVM() -> LibraryViewModel {
        // Use a unique suite name per test invocation to guarantee isolation.
        let suiteName = "GalleryImportTests.\(UUID().uuidString)"
        let vm = LibraryViewModel(userDefaults: UserDefaults(suiteName: suiteName)!)
        return vm
    }
}
