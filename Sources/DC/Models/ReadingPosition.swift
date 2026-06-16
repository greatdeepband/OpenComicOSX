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
}
