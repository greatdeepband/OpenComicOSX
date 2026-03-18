import Foundation

/// Persists the last-read page for each comic file.
/// Stored in UserDefaults keyed by the comic file path.
struct ReadingPositionStore {
    private static let key = "readingPositions"

    private static func load() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    static func save(page: Int, for url: URL) {
        var store = load()
        store[url.path] = page
        UserDefaults.standard.set(store, forKey: key)
    }

    static func page(for url: URL) -> Int {
        load()[url.path] ?? 0
    }

    /// Returns reading progress as a fraction (0.0 – 1.0) for the given comic.
    static func progress(for url: URL, totalPages: Int) -> Double {
        guard totalPages > 1 else { return 0 }
        let page = page(for: url)
        return Double(page) / Double(totalPages - 1)
    }
}
