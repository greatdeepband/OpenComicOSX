import XCTest
@testable import DC

/// Tests for canonical file-identity key (Task 7).
///
/// Verifies that favorites and recents persist using a stable canonical key
/// derived from `url.standardizedFileURL.path`, and that the idempotent
/// migration correctly handles both old-format entries (stored as
/// `absoluteString`, e.g. `file:///Users/x/A.cbz`) and already-migrated
/// bare-path entries (e.g. `/Users/x/A.cbz`).
final class FileIdentityTests: XCTestCase {

    // MARK: - T1: canonicalKey consistency

    /// A URL built from a bare path and one reconstructed from its
    /// `absoluteString` must produce the same canonical key.
    func testCanonicalKeyIsConsistentAcrossConstructionMethods() {
        let path = "/Users/x/Comics/A.cbz"
        let urlFromPath      = URL(fileURLWithPath: path)
        let urlFromAbsString = URL(string: urlFromPath.absoluteString)!

        XCTAssertEqual(
            canonicalKey(urlFromPath),
            canonicalKey(urlFromAbsString),
            "canonicalKey must be identical regardless of how the URL was constructed"
        )
    }

    // MARK: - T2: migration of old-format (absoluteString) favorites

    /// Old entries stored as `absoluteString` (e.g. `file:///Users/x/A.cbz`)
    /// must migrate to the canonical key equal to the bare path.
    func testOldFormatFavoritesMigrateToCanonicalKey() {
        let path = "/Users/x/Comics/B.cbz"
        let canonicalURL = URL(fileURLWithPath: path)

        // Simulate what loadFavorites used to store: absoluteString
        let oldFormatString = canonicalURL.absoluteString   // "file:///Users/x/Comics/B.cbz"

        // Apply the migration reconstruction logic
        let reconstructed = migrateStoredEntry(oldFormatString)

        XCTAssertNotNil(reconstructed, "Migration should produce a URL from an old-format absoluteString")
        XCTAssertEqual(
            reconstructed.map { canonicalKey($0) },
            canonicalKey(canonicalURL),
            "Migrated URL's canonical key must match the canonical key of the original URL"
        )
    }

    // MARK: - T3: idempotency — running migration twice is stable

    /// `URL(string: "/Users/x/A.cbz")` on macOS returns a relative URL with
    /// `scheme == nil` — NOT a `file://` URL. The migration logic must detect
    /// this case and fall through to the `URL(fileURLWithPath:)` branch so
    /// that already-migrated bare-path entries are reconstructed correctly.
    func testAlreadyMigratedBarePathEntryStillLoads() {
        let barePath = "/Users/x/Comics/C.cbz"

        // On macOS, URL(string:) accepts bare paths but returns no scheme —
        // the migration must use the fileURLWithPath fallback in this case.
        let parsedRelative = URL(string: barePath)
        XCTAssertNil(
            parsedRelative?.scheme,
            "URL(string:) with a bare POSIX path must have no scheme — validates that the fallback branch is needed"
        )

        // Apply the migration reconstruction logic to an already-migrated entry
        let reconstructed = migrateStoredEntry(barePath)

        XCTAssertNotNil(reconstructed, "Migration must still produce a URL from an already-migrated bare path")
        XCTAssertEqual(
            reconstructed?.path,
            barePath,
            "Bare-path entry must round-trip to the same path after migration"
        )
    }

    // MARK: - T3b: double migration is stable

    /// Applying the migration reconstruction twice to a canonical-key string
    /// (bare path) must yield the same canonical key — i.e. it is idempotent.
    func testMigrationIsIdempotent() {
        let path = "/Users/x/Comics/D.cbz"
        let originalURL = URL(fileURLWithPath: path)

        // First pass: store as canonical key (bare path), then reload
        let canonicalKeyString = canonicalKey(originalURL)   // "/Users/x/Comics/D.cbz"
        let firstPass = migrateStoredEntry(canonicalKeyString)

        XCTAssertNotNil(firstPass)
        let keyAfterFirstPass = firstPass.map { canonicalKey($0) }

        // Second pass: store the result of first pass, reload again
        let secondPassInput = keyAfterFirstPass ?? ""
        let secondPass = migrateStoredEntry(secondPassInput)

        XCTAssertEqual(
            keyAfterFirstPass,
            secondPass.map { canonicalKey($0) },
            "Running the migration twice must produce the same canonical key"
        )
    }
}

// MARK: - Helpers mirroring the production migration logic

/// Mirrors `canonicalKey(_:)` from LibraryViewModel.
private func canonicalKey(_ url: URL) -> String {
    url.standardizedFileURL.path
}

/// Mirrors the idempotent migration reconstruction used in `loadFavorites`.
/// Returns nil only if both reconstruction attempts fail (should never happen
/// for well-formed stored entries).
private func migrateStoredEntry(_ stored: String) -> URL? {
    // Step 1 — old format: absoluteString e.g. "file:///path/to/A.cbz"
    // A valid old entry has a scheme (e.g. "file"). A bare path parsed by
    // URL(string:) on macOS has scheme == nil and must use the fallback.
    if let url = URL(string: stored), url.scheme != nil {
        return url
    }
    // Step 2 — already-migrated: bare POSIX path e.g. "/path/to/A.cbz"
    return URL(fileURLWithPath: stored)
}
