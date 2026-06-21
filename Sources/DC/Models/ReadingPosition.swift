import Foundation

/// Persists the last-read page and reading mode for each comic file.
/// Stored in UserDefaults keyed by the comic file path.
struct ReadingPositionStore {
    private static let pageKey = "readingPositions"
    private static let modeKey = "readingModes"

    // MARK: - Page

    private static func loadPages() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: pageKey) as? [String: Int]) ?? [:]
    }

    static func save(page: Int, for url: URL) {
        var store = loadPages()
        store[url.path] = page
        UserDefaults.standard.set(store, forKey: pageKey)
    }

    static func page(for url: URL) -> Int {
        loadPages()[url.path] ?? 0
    }

    /// Returns reading progress as a fraction (0.0 – 1.0) for the given comic.
    static func progress(for url: URL, totalPages: Int) -> Double {
        guard totalPages > 1 else { return 0 }
        let page = page(for: url)
        return Double(page) / Double(totalPages - 1)
    }

    // MARK: - Scroll offset (for vertical modes)

    private static let offsetKey = "scrollOffsets"

    private static func loadOffsets() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: offsetKey) as? [String: Double]) ?? [:]
    }

    static func save(scrollOffset: Double, for url: URL) {
        var store = loadOffsets()
        store[url.path] = scrollOffset
        UserDefaults.standard.set(store, forKey: offsetKey)
    }

    static func scrollOffset(for url: URL) -> Double? {
        loadOffsets()[url.path]
    }

    // MARK: - Scroll pagesPerRow (layout companion for scroll offset)

    private static let pagesPerRowKey = "scrollPagesPerRow"

    private static func loadScrollPagesPerRow(defaults: UserDefaults) -> [String: Int] {
        (defaults.dictionary(forKey: pagesPerRowKey) as? [String: Int]) ?? [:]
    }

    static func save(scrollPagesPerRow: Int, for url: URL, defaults: UserDefaults = .standard) {
        var store = loadScrollPagesPerRow(defaults: defaults)
        store[url.path] = scrollPagesPerRow
        defaults.set(store, forKey: pagesPerRowKey)
    }

    static func scrollPagesPerRow(for url: URL, defaults: UserDefaults = .standard) -> Int? {
        loadScrollPagesPerRow(defaults: defaults)[url.path]
    }

    /// Returns true only when the saved layout matches the current one so the
    /// saved fraction is meaningful. A nil companion (legacy save with no
    /// pagesPerRow recorded) is treated as a mismatch → page-based fallback.
    static func shouldUseSavedOffset(savedPagesPerRow: Int?, currentPagesPerRow: Int) -> Bool {
        guard let s = savedPagesPerRow else { return false }
        return s == currentPagesPerRow
    }

    // MARK: - Page count (for stats)

    private static let pageCountKey = "pageCounts"

    private static func loadPageCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: pageCountKey) as? [String: Int]) ?? [:]
    }

    static func save(pageCount: Int, for url: URL) {
        guard pageCount > 0 else { return }
        var store = loadPageCounts()
        store[url.path] = pageCount
        UserDefaults.standard.set(store, forKey: pageCountKey)
    }

    static func pageCount(for url: URL) -> Int {
        loadPageCounts()[url.path] ?? 0
    }

    static func totalPagesRead() -> Int {
        loadPageCounts().values.reduce(0, +)
    }

    // MARK: - Reading mode

    private static func loadModes() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: modeKey) as? [String: String]) ?? [:]
    }

    static func save(mode: String, for url: URL) {
        var store = loadModes()
        store[url.path] = mode
        UserDefaults.standard.set(store, forKey: modeKey)
    }

    static func mode(for url: URL) -> String? {
        loadModes()[url.path]
    }

    // MARK: - Reading direction (per-comic + sticky global)

    private static let directionKey = "readingDirection"
    private static let lastDirectionKey = "lastReadingDirection"

    static func readingDirection(for url: URL, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: directionKey) as? [String: String])?[url.path]
    }

    static func saveReadingDirection(_ dir: String, for url: URL, defaults: UserDefaults = .standard) {
        var store = (defaults.dictionary(forKey: directionKey) as? [String: String]) ?? [:]
        store[url.path] = dir
        defaults.set(store, forKey: directionKey)
        defaults.set(dir, forKey: lastDirectionKey)
    }

    static func lastReadingDirection(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: lastDirectionKey) ?? "ltr"
    }

    // MARK: - Bookmarks (per-comic; user intent — NOT cleared by clearAllCache)

    private static let bookmarksKey = "bookmarks"

    /// Returns the sorted list of bookmarked page indices for `url`.
    static func bookmarks(for url: URL, defaults: UserDefaults = .standard) -> [Int] {
        let store = (defaults.dictionary(forKey: bookmarksKey) as? [String: [Int]]) ?? [:]
        return store[url.path] ?? []
    }

    /// Returns `true` when `page` is bookmarked for `url`.
    static func isBookmarked(page: Int, for url: URL, defaults: UserDefaults = .standard) -> Bool {
        bookmarks(for: url, defaults: defaults).contains(page)
    }

    /// Adds `page` to the bookmark list if absent, removes it if present.
    /// The stored list is always sorted ascending.
    static func toggleBookmark(page: Int, for url: URL, defaults: UserDefaults = .standard) {
        var store = (defaults.dictionary(forKey: bookmarksKey) as? [String: [Int]]) ?? [:]
        var pages = store[url.path] ?? []
        if let idx = pages.firstIndex(of: page) {
            pages.remove(at: idx)
        } else {
            pages.append(page)
            pages.sort()
        }
        store[url.path] = pages
        defaults.set(store, forKey: bookmarksKey)
    }

    // MARK: - Read-status overrides (per-comic; user intent — NOT cleared by clearAllCache)

    private static let readStatusOverridesKey = "readStatusOverrides"

    /// Returns the manual read-status override for `url`, or nil when absent (auto-derived).
    static func readStatusOverride(for url: URL, defaults: UserDefaults = .standard) -> ManualStatus? {
        let store = (defaults.dictionary(forKey: readStatusOverridesKey) as? [String: String]) ?? [:]
        guard let raw = store[url.standardizedFileURL.path] else { return nil }
        return ManualStatus(rawValue: raw)
    }

    /// Persists a manual read-status override for `url`. Pass `nil` to clear (revert to auto-derived).
    static func setReadStatusOverride(_ status: ManualStatus?, for url: URL, defaults: UserDefaults = .standard) {
        var store = (defaults.dictionary(forKey: readStatusOverridesKey) as? [String: String]) ?? [:]
        let key = url.standardizedFileURL.path
        if let status {
            store[key] = status.rawValue
        } else {
            store.removeValue(forKey: key)
        }
        defaults.set(store, forKey: readStatusOverridesKey)
    }
}
