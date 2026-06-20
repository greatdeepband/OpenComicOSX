import Foundation

// Migration: copies UserDefaults from the old (typo'd) bundle-id suite to the
// new com.opencomic suite on first launch after the CFBundleIdentifier rename.
//
// Key literals are verified against LibraryViewModel (recentsKey/galleriesKey/
// favoritesKey/thumbnailScheme_fnv1a_v1/library.*), ReadingPositionStore
// (readingPositions/scrollOffsets/pageCounts/readingModes), and
// CompressionPreferences (cbz.compression.*). Do NOT refactor these into
// the source-site private constants — the migration needs to own stable copies
// that remain correct even if the call sites are renamed later.
enum OpncomicDefaultsMigration {
    static let flag = "didMigrateFromOpncomic_v1"
    static let oldSuite = "com.opncomic.open-comic"
    // EXACT keys the app uses (mirror the call sites in LibraryViewModel /
    // ReadingPosition / CompressionPromptSheet):
    static let keys = [
        "library.cardSize", "library.selectedSection", "library.sortPreferences",
        "recentComics", "galleries_v1", "favoriteURLs_v1", "thumbnailScheme_fnv1a_v1",
        "readingPositions", "scrollOffsets", "pageCounts", "readingModes",
        "cbz.compression.deleteOriginals.choice", "cbz.compression.convertPNGs.choice",
        "cbz.compression.deleteOriginals.remembered",
        "scrollPagesPerRow", "bookmarks", "readingDirection", "lastReadingDirection",
    ]

    static func runIfNeeded(standard: UserDefaults = .standard, oldSuiteName: String = oldSuite) {
        guard !standard.bool(forKey: flag) else { return }
        if let old = UserDefaults(suiteName: oldSuiteName) {
            for key in keys where standard.object(forKey: key) == nil {
                if let v = old.object(forKey: key) { standard.set(v, forKey: key) }   // untyped object() preserves Data/dict/Bool
            }
        }
        standard.set(true, forKey: flag)
    }
}
