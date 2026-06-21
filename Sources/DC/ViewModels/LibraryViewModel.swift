import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Gallery model

/// A named, ordered collection of comic files sourced from one or more folders.
struct Gallery: Identifiable, Codable {
    var id: UUID
    var name: String
    /// Source folders, in the order the user added them.
    var sourceFolders: [URL]
    /// Resolved comic URLs — folder order first, then alphabetically within each folder.
    var comics: [URL]
    /// Comic URLs the user has explicitly removed from this gallery.
    /// These are permanently excluded to prevent reappearing when addFolders re-scans source folders.
    var deletedComics: Set<URL>
    /// True for the system-managed "Imported" gallery created by importComics(_:).
    /// Defaults to false so legacy persisted data (which lacks this key) decodes
    /// without throwing keyNotFound — a throw would leave `galleries` empty and
    /// wipe the user's entire library.
    var isImported: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, sourceFolders, comics, deletedComics, isImported
    }

    init(id: UUID = UUID(), name: String, sourceFolders: [URL] = [], comics: [URL] = [], deletedComics: Set<URL> = [], isImported: Bool = false) {
        self.id = id
        self.name = name
        self.sourceFolders = sourceFolders
        self.comics = comics
        self.deletedComics = deletedComics
        self.isImported = isImported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourceFolders = try c.decode([URL].self, forKey: .sourceFolders)
        comics = try c.decode([URL].self, forKey: .comics)
        deletedComics = try c.decode(Set<URL>.self, forKey: .deletedComics)
        // decodeIfPresent so legacy galleries_v1 data without this key decodes
        // as false rather than throwing keyNotFound (which would wipe the library).
        isImported = try c.decodeIfPresent(Bool.self, forKey: .isImported) ?? false
    }
}

// MARK: - RecentComic model

struct RecentComic: Identifiable, Codable {
    let id: UUID
    let url: URL
    var title: String { url.deletingPathExtension().lastPathComponent }
    /// Computed from ReadingPositionStore — not stored in Codable.
    /// Uses the page count saved by ReaderViewModel.init so the fraction is accurate.
    var readingProgress: Double? {
        let page = ReadingPositionStore.page(for: url)
        guard page > 0 else { return nil }
        let total = ReadingPositionStore.pageCount(for: url)
        guard total > 1 else { return nil }
        return Double(page) / Double(total - 1)
    }

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

// MARK: - LibraryViewModel

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var recentComics: [RecentComic] = []
    @Published var galleries: [Gallery] = []
    @Published var openComic: Comic? = nil
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    /// The URL of the last comic opened — used to scroll the library back to that card.
    @Published var lastOpenedURL: URL? = nil

    /// Per-URL refresh signal for thumbnail availability. Cards subscribe
    /// via `.onReceive(library.thumbnailUpdates)` and flip their render
    /// token only when the emitted URL matches their own. This subject is
    /// **not** `@Published` — sending an event does NOT fire
    /// `objectWillChange`, so a thumbnail decoded for card N never
    /// invalidates cards 1..N-1 / N+1..end. Eliminates the full-grid
    /// re-render that surfaced as cover-flicker during fast scroll
    /// (diagnosed 2026-04-28; see CHANGELOG v0.11.1).
    let thumbnailUpdates = PassthroughSubject<URL, Never>()

    /// Per-URL refresh signal for read-status changes. Cards subscribe via
    /// `.onReceive(library.statusUpdates)` and flip their render token only
    /// when the emitted URL matches their own. Separate from `thumbnailUpdates`
    /// — different contract; a status write must NOT trigger a thumbnail reload.
    /// `ReadingPositionStore` writes do not fire `objectWillChange`, so this
    /// channel is the only way to propagate a single-card or batch mark to ALL
    /// affected cards without a full-grid re-render.
    let statusUpdates = PassthroughSubject<URL, Never>()

    /// Current search query — empty string means no filter.
    @Published var searchQuery: String = ""

    /// Active filter state — in-memory (not persisted).
    @Published var libraryFilter: LibraryFilter = LibraryFilter()

    /// Ordered list of favorited comic URLs (most recently favorited first).
    @Published var favoriteURLs: [URL] = []

    /// Cross-cutting service that handles single + batch CBZ compression.
    /// Sheets (`CompressionPromptSheet`, `CompressionProgressSheet`) observe
    /// this service directly.
    @Published var compressionService = CompressionService()

    /// Pending compression intent — set when the user triggers an action;
    /// drives the prompt sheet. `nil` means "no prompt up". When the user
    /// confirms in the prompt, we read `pendingCompressionURLs` and call
    /// `compressionService.runBatch(...)`.
    @Published var pendingCompressionURLs: [URL]? = nil
    @Published var pendingCompressionTitle: String = ""
    @Published var pendingCompressionDetail: String = ""

    // MARK: - New library UI state

    /// Currently selected sidebar row. Optional because SwiftUI `List`
    /// single-selection bindings are typed as `Selection?`; nil is treated as
    /// "Home" for rendering purposes. Persisted to UserDefaults so the app
    /// restores the same view on relaunch.
    @Published var selectedSection: LibrarySection? = .home {
        didSet {
            saveSelectedSection()
            clearSelection()
        }
    }

    // MARK: - Grid multi-selection state (Task 6)

    /// The set of URLs currently selected in the grid. Cleared on section change
    /// and when `selectMode` is toggled off.
    @Published var selection: Set<URL> = []

    /// The URL last used as a shift-range anchor. Not published — UI only needs
    /// `selection` to decide rendering; anchor is read-only by gesture handlers.
    var selectionAnchor: URL?

    /// When true, plain taps on cards toggle rather than replace the selection
    /// (equivalent to holding ⌘). Cleared selection when turned off.
    @Published var selectMode: Bool = false {
        didSet {
            if !selectMode { clearSelection() }
        }
    }

    /// Resets `selection` and `selectionAnchor` to empty / nil.
    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// Grid card size, persisted.
    @Published var cardSize: CardSize = .medium {
        didSet { defaults.set(cardSize.rawValue, forKey: "library.cardSize") }
    }

    /// Sort order per sidebar section, keyed by `LibrarySection.storageKey`.
    @Published var sortPreferences: [String: LibrarySortOrder] = [:] {
        didSet { saveSortPreferences() }
    }

    /// Returns the sort order for the given section, falling back to sensible
    /// per-section defaults.
    func sortOrder(for section: LibrarySection) -> LibrarySortOrder {
        if let stored = sortPreferences[section.storageKey] { return stored }
        switch section {
        case .home:        return .recentlyRead
        case .favorites:   return .recentlyAdded
        case .recents:     return .recentlyRead
        case .allComics:   return .alphabetical
        case .gallery:     return .manual
        }
    }

    func setSortOrder(_ order: LibrarySortOrder, for section: LibrarySection) {
        sortPreferences[section.storageKey] = order
    }

    /// Computes the effective reading status for a URL using ReadingPositionStore directly
    /// (not recentComics-capped) so it works for all comics including never-opened ones.
    func readingStatus(for url: URL) -> ReadingStatus {
        let override = ReadingPositionStore.readStatusOverride(for: url)
        let page = ReadingPositionStore.page(for: url)
        let total = ReadingPositionStore.pageCount(for: url)
        return effectiveStatus(override: override, page: page, total: total)
    }

    /// Central display pipeline: search → filter → sort.
    /// `corpus` is the input list. `section` drives the sort order lookup.
    /// `isGlobalSearch` = true causes `.manual` sort to fall back to `.alphabetical`.
    func displayURLs(
        corpus: [URL],
        section: LibrarySection,
        isGlobalSearch: Bool
    ) -> [URL] {
        let afterSearch: [URL]
        if searchQuery.isEmpty {
            afterSearch = corpus
        } else {
            let q = searchQuery
            afterSearch = corpus.filter {
                matchesQuery(filename: $0.deletingPathExtension().lastPathComponent, query: q)
            }
        }
        let afterFilter = afterSearch.filter { url in
            let status = readingStatus(for: url)
            let favorited = isFavorite(url: url)
            let fmt = url.pathExtension.lowercased()
            return comicMatchesFilter(status: status, isFavorited: favorited, format: fmt, filter: libraryFilter)
        }
        var order = sortOrder(for: section)
        if isGlobalSearch && order == .manual { order = .alphabetical }
        return LibrarySort.apply(order, to: afterFilter, library: self)
    }

    // MARK: - Derived collections for the new library

    /// Memoised flat deduplicated list of every comic URL across all galleries
    /// plus orphan recents. Published-property invalidation is triggered by a
    /// coarse signature (sum of gallery comic counts + recents count) that
    /// changes whenever a comic is added/removed anywhere. Lookup is O(1)
    /// between invalidations; recompute is O(n+m).
    private var _allComicURLs: [URL] = []
    private var _allComicURLsSignature: Int = -1

    var allComicURLs: [URL] {
        let signature = galleries.reduce(0) { $0 + $1.comics.count } + recentComics.count
        if signature == _allComicURLsSignature { return _allComicURLs }

        var seen = Set<URL>()
        var result: [URL] = []
        for gallery in galleries {
            for url in gallery.comics where !seen.contains(url) {
                seen.insert(url)
                result.append(url)
            }
        }
        for recent in recentComics where !seen.contains(recent.url) {
            seen.insert(recent.url)
            result.append(recent.url)
        }
        _allComicURLs = result
        _allComicURLsSignature = signature
        return result
    }

    /// The "continue reading" candidate for the Home hero: the most-recently-
    /// opened comic whose reading progress is strictly between 0 and 1. Falls
    /// back to the most recently opened comic if none qualifies.
    func continueReadingURL() -> URL? {
        for recent in recentComics {
            if let p = recent.readingProgress, p > 0.02, p < 0.98 { return recent.url }
        }
        return recentComics.first?.url
    }

    /// Fully removes a URL from the library: every gallery, recents, and
    /// favorites. Used by the "Remove from Library" action in the All Comics
    /// pane. The underlying file on disk is untouched.
    func removeFromLibrary(url: URL) {
        var changed = false
        for idx in galleries.indices {
            if let removeIdx = galleries[idx].comics.firstIndex(of: url) {
                galleries[idx].comics.remove(at: removeIdx)
                changed = true
            }
        }
        if let recent = recentComics.first(where: { canonicalKey($0.url) == canonicalKey(url) }) {
            removeRecent(recent)
        }
        if isFavorite(url: url) {
            let key = canonicalKey(url)
            favoriteURLs.removeAll { canonicalKey($0) == key }
            saveFavorites()
        }
        if changed { saveGalleries() }
    }

    /// Appends individual comic files to a gallery without scanning source
    /// folders. Used by the per-gallery unified picker when the user selects
    /// loose files (as opposed to folders). De-duplicates silently.
    func addComicFiles(_ urls: [URL], to galleryID: UUID) {
        guard let idx = galleries.firstIndex(where: { $0.id == galleryID }) else { return }
        var changed = false
        for url in urls {
            let u = url.standardizedFileURL
            guard !galleries[idx].comics.contains(u) else { continue }
            // For named (non-imported) galleries, respect the tombstone: skip comics
            // the user explicitly removed so they don't reappear on re-import.
            if !galleries[idx].isImported && galleries[idx].deletedComics.contains(u) { continue }
            galleries[idx].comics.append(u)
            changed = true
        }
        if changed { saveGalleries() }
    }

    /// Moves a comic from whichever gallery currently contains it into the
    /// target gallery. No-op if the comic is already in the target or the
    /// target doesn't exist. Used for drag-onto-sidebar-row reordering.
    func moveComic(_ url: URL, toGallery targetID: UUID) {
        guard galleries.contains(where: { $0.id == targetID }) else { return }
        var changed = false
        for idx in galleries.indices where galleries[idx].id != targetID {
            if let removeIdx = galleries[idx].comics.firstIndex(of: url) {
                galleries[idx].comics.remove(at: removeIdx)
                changed = true
            }
        }
        if let targetIdx = galleries.firstIndex(where: { $0.id == targetID }),
           !galleries[targetIdx].comics.contains(url) {
            galleries[targetIdx].comics.append(url)
            changed = true
        }
        if changed { saveGalleries() }
    }

    // MARK: - Compression entry points

    /// Triggered by the "Compress All Comics…" menu item.
    func requestCompressAll() {
        let urls = allComicURLs
        let cbzCount = urls.filter { $0.pathExtension.lowercased() == "cbz" }.count
        pendingCompressionTitle = "Compress \(cbzCount) comic\(cbzCount == 1 ? "" : "s")?"
        pendingCompressionDetail =
            "Recompresses JPEG images inside each .cbz, typically shrinking each file 30–50 % " +
            "with no visible change at typical reading scales. PNG entries and non-CBZ formats " +
            "(PDF, CBR, CB7, CBT) are skipped."
        pendingCompressionURLs = urls
        runPendingIfRemembered()
    }

    /// Triggered by right-click → "Compress Gallery" on a sidebar row.
    func requestCompressGallery(_ id: UUID) {
        guard let gallery = galleries.first(where: { $0.id == id }) else { return }
        let cbzCount = gallery.comics.filter { $0.pathExtension.lowercased() == "cbz" }.count
        pendingCompressionTitle = "Compress \(cbzCount) comic\(cbzCount == 1 ? "" : "s") in '\(gallery.name)'?"
        pendingCompressionDetail =
            "Recompresses JPEG images inside each .cbz, typically shrinking 30–50 % per file. " +
            "PNG entries and non-CBZ formats are skipped."
        pendingCompressionURLs = gallery.comics
        runPendingIfRemembered()
    }

    /// Triggered by the batch-select "Compress" action.
    func requestCompressSelection(_ urls: Set<URL>) {
        let cbzURLs = urls.filter { $0.pathExtension.lowercased() == "cbz" }
        guard !cbzURLs.isEmpty else { return }
        let count = cbzURLs.count
        pendingCompressionTitle = "Compress \(count) selected comic\(count == 1 ? "" : "s")?"
        pendingCompressionDetail =
            "Recompresses JPEG images inside each .cbz, typically shrinking each file 30–50 % " +
            "with no visible change at typical reading scales."
        pendingCompressionURLs = Array(cbzURLs)
        runPendingIfRemembered()
    }

    /// Triggered by right-click → "Compress Comic" on a card.
    func requestCompressComic(at url: URL) {
        pendingCompressionTitle = "Compress '\(url.lastPathComponent)'?"
        pendingCompressionDetail =
            "Recompresses JPEG images inside the .cbz, typically shrinking it 30–50 % with no " +
            "visible change at typical reading scales."
        pendingCompressionURLs = [url]
        runPendingIfRemembered()
    }

    /// If the user has previously ticked "Remember my choice", skip the
    /// prompt and run with the remembered delete-originals value.
    private func runPendingIfRemembered() {
        guard let urls = pendingCompressionURLs else { return }
        if CompressionPreferences.hasRememberedChoice() {
            let delete = CompressionPreferences.rememberedDeleteOriginals()
            let convertPNGs = CompressionPreferences.rememberedConvertPNGs()
            pendingCompressionURLs = nil
            startBatch(urls: urls, deleteOriginals: delete, convertPNGs: convertPNGs)
        }
    }

    /// Called by `CompressionPromptSheet`'s confirm callback.
    func confirmPendingCompression(deleteOriginals: Bool, convertPNGs: Bool, remember: Bool) {
        guard let urls = pendingCompressionURLs else { return }
        pendingCompressionURLs = nil
        if remember {
            CompressionPreferences.remember(deleteOriginals: deleteOriginals, convertPNGs: convertPNGs)
        } else if CompressionPreferences.hasRememberedChoice() {
            CompressionPreferences.reset()
        }
        startBatch(urls: urls, deleteOriginals: deleteOriginals, convertPNGs: convertPNGs)
    }

    func cancelPendingCompression() {
        pendingCompressionURLs = nil
    }

    /// One place that kicks off the batch + wires the per-file completion
    /// hook to thumbnail invalidation. After each successful compression
    /// the card's cover refreshes from the new (smaller) file so the user
    /// sees the result without restarting the app, and the library's URL
    /// continues to point at the now-compressed file.
    private func startBatch(urls: [URL], deleteOriginals: Bool, convertPNGs: Bool) {
        compressionService.runBatch(
            urls: urls,
            deleteOriginals: deleteOriginals,
            convertPNGs: convertPNGs,
            onFileCompleted: { [weak self] url in
                self?.invalidateThumbnail(for: url)
                self?.thumbnailUpdates.send(url)
            }
        )
    }

    /// Removes the disk-cached thumbnail (FNV-1a-hashed path under
    /// `~/Library/Application Support/DC/Thumbnails/<hash>.jpg`) and the
    /// in-memory NSCache entry so the next thumbnail request decodes a
    /// fresh cover from the compressed CBZ.
    func invalidateThumbnail(for url: URL) {
        let key = Self.thumbnailCacheKey(for: url) as NSString
        thumbnailCache.removeObject(forKey: key)
        let diskURL = Self.thumbnailURL(for: url)
        try? FileManager.default.removeItem(at: diskURL)
    }

    // MARK: - Persistence helpers for new UI state

    private func saveSelectedSection() {
        guard let value = selectedSection else { return }
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            Task { await DCLogger.shared.log("[PERSIST] selectedSection encode failed: \(error)") }
            return
        }
        defaults.set(data, forKey: "library.selectedSection")
    }

    private func saveSortPreferences() {
        let dict: [String: String] = sortPreferences.mapValues { $0.rawValue }
        defaults.set(dict, forKey: "library.sortPreferences")
    }

    func loadNewLibraryState() {
        if let data = defaults.data(forKey: "library.selectedSection") {
            do {
                selectedSection = try JSONDecoder().decode(LibrarySection.self, from: data)
            } catch {
                Task { await DCLogger.shared.log("[PERSIST] selectedSection decode failed: \(error) — falling back to default") }
            }
        }
        if let raw = defaults.string(forKey: "library.cardSize"),
           let size = CardSize(rawValue: raw) {
            cardSize = size
        }
        if let dict = defaults.dictionary(forKey: "library.sortPreferences") as? [String: String] {
            var prefs: [String: LibrarySortOrder] = [:]
            for (k, v) in dict {
                if let order = LibrarySortOrder(rawValue: v) { prefs[k] = order }
            }
            sortPreferences = prefs
        }
    }

    /// Total number of unique comics across all galleries.
    var totalComics: Int {
        Set(galleries.flatMap { $0.comics }).count
    }

    /// Cumulative pages read across all comics (sum of page counts for opened comics).
    var totalPages: Int {
        ReadingPositionStore.totalPagesRead()
    }

    /// In-memory thumbnail cache backed by NSCache.
    ///
    /// NSCache differs from a plain dictionary in two important ways:
    /// 1. It automatically evicts entries when the system is under memory pressure.
    /// 2. countLimit caps the number of entries, preventing unbounded growth.
    ///
    /// We set countLimit to 600 — comfortably above the largest expected library (369
    /// comics) while ensuring the cache never grows to cover all 18,000+ historical
    /// thumbnails on disk.
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    /// Manually tracked count of items in the NSCache.
    /// NSCache has no built-in count property, so we increment/decrement here.
    /// Used by MemoryMonitor for debug stats.
    private(set) var thumbnailCacheCount: Int = 0

    private let recentsKey = "recentComics"
    private let galleriesKey = "galleries_v1"
    private let favoritesKey = "favoriteURLs_v1"

    /// The UserDefaults suite used for all persistence. Defaults to
    /// UserDefaults.standard; tests pass an isolated suite so they never
    /// touch the real user library.
    private let defaults: UserDefaults

    /// Disk cache directory for cover thumbnails.
    static let thumbnailCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("DC/Thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// UTType list for the NSOpenPanel — covers every format the reader supports.
    static let comicContentTypes: [UTType] = [.pdf]
        + ["cbz", "cbr", "cb7", "cbt"].compactMap { UTType(filenameExtension: $0) }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        loadRecents()
        loadGalleries()
        // One-time migration: canonicalize all stored URLs to standardizedFileURL so
        // that subsequent equality checks (dedup, tombstone, isInLibrary) are reliable.
        // The flag prevents re-running on every launch. We run even when galleries is
        // empty (fresh install) so the flag is always set — the empty-gallery early-
        // return in loadGalleries() must not skip this block.
        let normalizeURLsKey = "didNormalizeGalleryURLs_v1"
        if !defaults.bool(forKey: normalizeURLsKey) {
            for idx in galleries.indices {
                // Map each URL to its canonical form, then deduplicate preserving order
                // (standardization can collapse /tmp/x.cbz and /private/tmp/x.cbz into
                // the same path — keep first occurrence; don't drop genuinely-distinct files).
                var seen = Set<URL>()
                galleries[idx].comics = galleries[idx].comics
                    .map { $0.standardizedFileURL }
                    .filter { seen.insert($0).inserted }
                galleries[idx].deletedComics = Set(
                    galleries[idx].deletedComics.map { $0.standardizedFileURL }
                )
            }
            defaults.set(true, forKey: normalizeURLsKey)
            if !galleries.isEmpty { saveGalleries() }
        }
        loadFavorites()
        loadNewLibraryState()
        // One-time migration: wipe the entire thumbnail cache on first launch after
        // switching from Swift's non-deterministic hashValue to FNV-1a.
        // All old files have names that don't match any FNV-1a key, so purgeOrphanedThumbnails
        // would delete them anyway — but doing it upfront avoids a false "all missing" state
        // that triggers a full regeneration pass on every launch until the purge runs.
        let migrationKey = "thumbnailScheme_fnv1a_v1"
        if !defaults.bool(forKey: migrationKey) {
            let dir = LibraryViewModel.thumbnailCacheDir
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files { try? FileManager.default.removeItem(at: file) }
                Task { await DCLogger.shared.log("[THUMB] Migration: cleared \(files.count) old hashValue thumbnail(s).") }
            }
            defaults.set(true, forKey: migrationKey)
        }
        // Generate any missing thumbnails and clean up orphaned files from previous sessions.
        // Thumbnail loading is fully lazy — requestThumbnail(for:) handles everything on demand.
        Task.detached(priority: .utility) { [weak self] in
            await self?.generateMissingThumbnails()
            await self?.purgeOrphanedThumbnails()
        }
    }

    // MARK: - Background thumbnail generation on launch

    /// Deletes thumbnail files on disk whose names don't match any comic currently
    /// in the library. This cleans up the 2,000+ orphaned files left by the old
    /// non-deterministic hashValue scheme, and keeps the cache directory tidy.
    /// Runs at low priority after generation is complete.
    private func purgeOrphanedThumbnails() async {
        let recents = await recentComics
        let allGalleries = await galleries
        var validKeys = Set<String>(recents.map { LibraryViewModel.thumbnailCacheKey(for: $0.url) })
        for gallery in allGalleries {
            for url in gallery.comics {
                validKeys.insert(LibraryViewModel.thumbnailCacheKey(for: url))
            }
        }
        let dir = LibraryViewModel.thumbnailCacheDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        var deleted = 0
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            if !validKeys.contains(stem) {
                try? FileManager.default.removeItem(at: file)
                deleted += 1
            }
        }
        if deleted > 0 {
            Task { await DCLogger.shared.log("[THUMB] Purged \(deleted) orphaned thumbnail(s) from disk.") }
        }
    }

    private func generateMissingThumbnails() async {
        let recents = await recentComics
        let allGalleries = await galleries
        var all: [URL] = recents.map { $0.url }
        for gallery in allGalleries { all.append(contentsOf: gallery.comics) }
        // Visible-first: comics already requested by visible cards are processed
        // first (they are in visibleRequestQueue). The rest fill in afterwards.
        let prioritised = await buildPrioritisedQueue(all: all)
        await generateThumbnailsParallel(for: prioritised)
    }

    /// URLs requested by visible ComicCards that don't have a thumbnail yet.
    /// Populated by requestThumbnailGeneration(for:); consumed by generateMissingThumbnails.
    private var visibleRequestQueue: [URL] = []

    /// Builds a URL list with visible comics first, then the rest in library order.
    private func buildPrioritisedQueue(all: [URL]) async -> [URL] {
        let visible = await visibleRequestQueue
        var seen = Set<URL>(visible)
        var result = visible
        for url in all {
            if !seen.contains(url) {
                seen.insert(url)
                result.append(url)
            }
        }
        return result
    }

    /// Extract and cache covers for a list of URLs, 2 at a time.
    ///
    /// Concurrency is capped at 8 — streaming CBZ extraction is fast and low-RAM,
    /// so we can parallelise more aggressively without memory pressure.
    /// A Task.yield() after each completion lets the OS schedule UI work between
    /// extractions, keeping the app responsive during bulk generation.
    private func generateThumbnailsParallel(for urls: [URL]) async {
        let missing = urls.filter {
            !FileManager.default.fileExists(atPath: LibraryViewModel.thumbnailURL(for: $0).path)
        }
        guard !missing.isEmpty else { return }
        let concurrency = 8
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for url in missing {
                if inFlight >= concurrency {
                    await group.next()
                    inFlight -= 1
                    await Task.yield()
                }
                inFlight += 1
                group.addTask(priority: .background) { [weak self] in
                    guard let self else { return }
                    // Load and scale cover entirely on the background thread.
                    guard let cgImage = await ComicLoader.loadCoverCGImage(url: url) else { return }
                    // Encode and write to disk on the background thread — no MainActor needed.
                    let diskURL = LibraryViewModel.thumbnailURL(for: url)
                    LibraryViewModel.saveCGImage(cgImage, to: diskURL)
                    // Only cache visible comics — off-screen comics are written
                    // to disk only and loaded lazily when their card fires onAppear.
                    // This prevents the 1 GB RAM spike from caching all 2000+ thumbnails
                    // during the first-launch generation pass.
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let isVisible = self.visibleRequestQueue.contains(url)
                        if isVisible {
                            let thumb = NSImage(cgImage: cgImage, size: .zero)
                            let key = LibraryViewModel.thumbnailCacheKey(for: url) as NSString
                            let isNew = self.thumbnailCache.object(forKey: key) == nil
                            self.thumbnailCache.setObject(thumb, forKey: key)
                            if isNew { self.thumbnailCacheCount += 1 }
                            self.thumbnailUpdates.send(url)
                        }
                        // Off-screen: disk write already done above. Card will load
                        // lazily via requestThumbnail when it fires onAppear.
                    }
                }
            }
        }
    }

    /// Called by ComicCard.onAppear when the thumbnail is not yet on disk.
    /// Adds the URL to the visible-first queue so it is prioritised by the
    /// background generator. If the thumbnail already exists on disk, loads
    /// it into the cache directly without queuing generation.
    func requestThumbnail(for comicURL: URL) {
        // Already cached — nothing to do.
        guard cachedThumbnail(for: comicURL) == nil else { return }

        // Thumbnail exists on disk — load it into cache on a background thread.
        if FileManager.default.fileExists(atPath: LibraryViewModel.thumbnailURL(for: comicURL).path) {
            Task.detached(priority: .utility) { [weak self] in
                guard let img = LibraryViewModel.loadThumbnail(for: comicURL) else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.insertIntoCache(img, for: comicURL)
                }
            }
            return
        }

        // No thumbnail on disk yet — add to the visible-first queue.
        if !visibleRequestQueue.contains(comicURL) {
            visibleRequestQueue.append(comicURL)
        }
    }

    // MARK: - File Picker (open single file)

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Open Comic"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.comicContentTypes
        panel.message = "Choose a CBZ, PDF, CBR, CB7, or CBT file"

        if panel.runModal() == .OK, let url = panel.url {
            Task { importComics([url]); await load(url: url) }
        }
    }

    // MARK: - Loading

    func load(url: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let comic = try await Task.detached(priority: .userInitiated) {
                try await ComicLoader.load(url: url)
            }.value
            openComic = comic
            lastOpenedURL = url
            // addRecent is called in closeComic() to avoid mutating recentComics
            // while LibraryView is alive in the ZStack — that mutation triggers a
            // re-render which resets the scroll position before the reader even appears.
            // Generate thumbnail in background if not already cached.
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                let thumbURL = LibraryViewModel.thumbnailURL(for: url)
                if !FileManager.default.fileExists(atPath: thumbURL.path),
                   let cover = await ComicLoader.loadCover(url: url) {
                    await MainActor.run { self.saveThumbnailAndCache(cover, for: url) }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func closeComic() {
        // Add to recents now (on close) rather than on open, so the recentComics
        // mutation doesn't trigger a LibraryView re-render while the reader is open.
        if let url = lastOpenedURL {
            addRecent(url: url)
        }
        openComic = nil
    }

    // MARK: - Adjacent gallery navigation

    /// Returns the URL of the comic before (-1) or after (+1) the current one
    /// in the first gallery that contains it. Returns nil if not found or at boundary.
    func adjacentComicURL(offset: Int) -> URL? {
        guard let url = lastOpenedURL else {
            Task { await DCLogger.shared.log("[NAV] adjacentComicURL: lastOpenedURL is nil") }
            return nil
        }
        let normalizedTarget = url.standardizedFileURL.path
        Task { await DCLogger.shared.log("[NAV] adjacentComicURL: looking for \(normalizedTarget) offset=\(offset)") }
        Task { await DCLogger.shared.log("[NAV] adjacentComicURL: galleries.count=\(self.galleries.count)") }
        for gallery in galleries {
            Task { await DCLogger.shared.log("[NAV] adjacentComicURL: checking gallery '\(gallery.name)' comics.count=\(gallery.comics.count)") }
            if gallery.comics.count > 0 {
                Task { await DCLogger.shared.log("[NAV] adjacentComicURL: first comic in gallery=\(gallery.comics[0].standardizedFileURL.path)") }
            }
            if let idx = gallery.comics.firstIndex(where: { $0.standardizedFileURL.path == normalizedTarget }) {
                let next = idx + offset
                Task { await DCLogger.shared.log("[NAV] adjacentComicURL: found at idx=\(idx), next=\(next), count=\(gallery.comics.count)") }
                guard next >= 0 && next < gallery.comics.count else {
                    Task { await DCLogger.shared.log("[NAV] adjacentComicURL: at boundary, returning nil") }
                    return nil
                }
                Task { await DCLogger.shared.log("[NAV] adjacentComicURL: returning \(gallery.comics[next].lastPathComponent)") }
                return gallery.comics[next]
            }
        }
        Task { await DCLogger.shared.log("[NAV] adjacentComicURL: comic not found in any gallery") }
        return nil
    }

    /// Persists recents for the current comic, then opens the adjacent one.
    /// currentMode: the reading mode active in the reader right now — inherited by the next comic
    /// if it has no previously saved mode of its own.
    func openAdjacentComic(offset: Int, currentMode: String) {
        guard let nextURL = adjacentComicURL(offset: offset) else { return }
        // Add current comic to recents before moving on.
        if let url = lastOpenedURL { addRecent(url: url) }
        // Seed the next comic's mode only if it has never been opened before.
        if ReadingPositionStore.mode(for: nextURL) == nil {
            ReadingPositionStore.save(mode: currentMode, for: nextURL)
        }
        Task { await load(url: nextURL) }
    }

    func removeRecent(_ recent: RecentComic) {
        recentComics.removeAll { $0.id == recent.id }
        saveRecents()
    }

    // MARK: - File-identity helpers

    /// Canonical key for a comic URL — stable across alias resolution and
    /// across the two URL construction methods (`fileURLWithPath` vs
    /// `URL(string: absoluteString)`).  Used by favorites and recents
    /// persistence so entries survive app restarts and macOS symlink changes.
    private func canonicalKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Idempotent migration helper: reconstructs a URL from a stored string
    /// that may be either an old-format `absoluteString` (e.g. `file:///…`)
    /// or an already-migrated bare POSIX path (e.g. `/Users/…`).
    ///
    /// - `URL(string:)` succeeds for both forms on macOS, but only returns a
    ///   non-nil *scheme* for absolute URLs (old format). Bare paths parse as
    ///   relative URLs with `scheme == nil` and must fall through to
    ///   `URL(fileURLWithPath:)` to produce a proper `file://` URL.
    private func migrateStoredURL(_ stored: String) -> URL? {
        if let url = URL(string: stored), url.scheme != nil {
            return url   // old format: "file:///path/to/A.cbz"
        }
        return URL(fileURLWithPath: stored)   // already-migrated: "/path/to/A.cbz"
    }

    // MARK: - Favorites

    func isFavorite(url: URL) -> Bool {
        let key = canonicalKey(url)
        return favoriteURLs.contains { canonicalKey($0) == key }
    }

    func toggleFavorite(url: URL) {
        let key = canonicalKey(url)
        if isFavorite(url: url) {
            favoriteURLs.removeAll { canonicalKey($0) == key }
        } else {
            favoriteURLs.insert(url, at: 0)
        }
        saveFavorites()
    }

    private func loadFavorites() {
        guard let data = defaults.data(forKey: favoritesKey) else { return }
        let paths: [String]
        do {
            paths = try JSONDecoder().decode([String].self, from: data)
        } catch {
            Task { await DCLogger.shared.log("[PERSIST] favorites decode failed: \(error) — favorites list will appear empty") }
            return
        }
        // Idempotent migration: old entries are absoluteStrings ("file:///…");
        // already-migrated entries are bare paths ("/…"). Both are handled.
        favoriteURLs = paths.compactMap { migrateStoredURL($0) }
    }

    private func saveFavorites() {
        // Persist as canonical bare paths — stable across URL construction methods.
        let paths = favoriteURLs.map { canonicalKey($0) }
        let data: Data
        do {
            data = try JSONEncoder().encode(paths)
        } catch {
            Task { await DCLogger.shared.log("[PERSIST] favorites encode failed: \(error) — favorites change not persisted") }
            return
        }
        defaults.set(data, forKey: favoritesKey)
    }

    // MARK: - Recents

    private func addRecent(url: URL) {
        let entry = RecentComic(url: url)
        let key = canonicalKey(url)
        recentComics.removeAll { canonicalKey($0.url) == key }
        recentComics.insert(entry, at: 0)
        if recentComics.count > 20 { recentComics = Array(recentComics.prefix(20)) }
        saveRecents()
    }

    private func loadRecents() {
        guard let data = defaults.data(forKey: recentsKey) else { return }
        do {
            var decoded = try JSONDecoder().decode([RecentComic].self, from: data)
            // Idempotent migration: URL Codable encodes as absoluteString, so
            // existing entries already decode to proper file:// URLs. Re-wrap
            // each entry so its URL is the canonically keyed file URL.
            decoded = decoded.map { recent in
                let canonical = URL(fileURLWithPath: canonicalKey(recent.url))
                guard canonical != recent.url else { return recent }
                return RecentComic(url: canonical)
            }
            recentComics = decoded
        } catch {
            Task { await DCLogger.shared.log("[PERSIST] recents decode failed: \(error) — Continue Reading will appear empty") }
        }
    }

    private func saveRecents() {
        let data: Data
        do {
            data = try JSONEncoder().encode(recentComics)
        } catch {
            Task { await DCLogger.shared.log("[PERSIST] recents encode failed: \(error) — last-opened state not persisted") }
            return
        }
        defaults.set(data, forKey: recentsKey)
    }

    // MARK: - Galleries

    /// Comic file extensions recognised by the importer. Mirrors the inline set
    /// in resolveComics(from:) — kept in sync manually.
    static let comicExtensions: Set<String> = ["cbz", "cbr", "cb7", "cbt", "pdf"]

    /// Internal trampoline so callers never need to reference the private async
    /// generateThumbnailsParallel(for:) directly.
    func generateThumbnails(for urls: [URL]) {
        Task.detached(priority: .background) { [weak self, urls] in
            await self?.generateThumbnailsParallel(for: urls)
        }
    }

    /// Returns true if `url` (by standardizedFileURL) is already present in
    /// any gallery's `comics` list. Used by `handleDrop` to route a drop to
    /// "relocate" (move) vs "import" (add + thumbnail generation).
    static func isInLibrary(_ url: URL, galleries: [Gallery]) -> Bool {
        let known = Set(galleries.flatMap { $0.comics }.map { $0.standardizedFileURL })
        return known.contains(url.standardizedFileURL)
    }

    /// Returns the id of the existing "Imported" gallery, or creates one and
    /// returns its id. Always call from the main actor (synchronous).
    func ensureImportedGallery() -> UUID {
        if let g = galleries.first(where: { $0.isImported }) { return g.id }
        let g = Gallery(name: "Imported", isImported: true)
        galleries.append(g)
        saveGalleries()
        return g.id
    }

    /// Imports loose comic files into the "Imported" gallery, deduplicating
    /// against every gallery already in the library. Synchronous on the main
    /// actor; thumbnail generation is spawned detached so this never blocks.
    func importComics(_ urls: [URL]) {
        let known = Set(galleries.flatMap { $0.comics }.map { $0.standardizedFileURL })
        let fresh = urls.filter {
            Self.comicExtensions.contains($0.pathExtension.lowercased())
                && !known.contains($0.standardizedFileURL)
        }
        guard !fresh.isEmpty else { return }
        let importedID = ensureImportedGallery()
        addComicFiles(fresh, to: importedID)
        generateThumbnails(for: fresh)
    }

    /// Imports comic files and/or folders without auto-opening.
    /// If `galleryID` is non-nil, routes to that gallery; otherwise imports to the
    /// "Imported" shelf. Mirrors the addToGallery split in LibraryGalleryPane.
    func addComicsOrFolders(_ urls: [URL], toGallery galleryID: UUID?) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        if let id = galleryID {
            if !folders.isEmpty { addFolders(folders, to: id) }
            if !files.isEmpty   { addComicFiles(files, to: id) }
        } else {
            if !files.isEmpty   { importComics(files) }
            // For folders when no gallery: scan for comics and import them
            for folder in folders {
                let comics = resolveComics(from: [folder])
                if !comics.isEmpty { importComics(comics) }
            }
        }
    }

    func createGallery(name: String, folders: [URL]) {
        var gallery = Gallery(name: name, sourceFolders: folders)
        gallery.comics = resolveComics(from: folders)
        galleries.append(gallery)
        saveGalleries()
        Task.detached(priority: .background) { [weak self, comics = gallery.comics] in
            await self?.generateThumbnailsParallel(for: comics)
        }
    }

    func renameGallery(id: UUID, newName: String) {
        guard !(galleries.first(where: { $0.id == id })?.isImported ?? false) else { return }
        guard let idx = galleries.firstIndex(where: { $0.id == id }) else { return }
        galleries[idx].name = newName
        saveGalleries()
    }

    func addFolders(_ folders: [URL], to galleryID: UUID) {
        guard let idx = galleries.firstIndex(where: { $0.id == galleryID }) else { return }
        // Append only new source folders
        let existingFolders = Set(galleries[idx].sourceFolders.map { $0.path })
        let newFolders = folders.filter { !existingFolders.contains($0.path) }
        galleries[idx].sourceFolders.append(contentsOf: newFolders)
        // Re-scan all source folders but only append comics not already present
        // and not in deletedComics (permanently removed by the user).
        let existingComics = Set(galleries[idx].comics)
        let deletedComics = galleries[idx].deletedComics
        let newComics = resolveComics(from: galleries[idx].sourceFolders)
            .filter { !existingComics.contains($0) && !deletedComics.contains($0) }
        galleries[idx].comics.append(contentsOf: newComics)
        saveGalleries()
        Task.detached(priority: .background) { [weak self, newComics] in
            await self?.generateThumbnailsParallel(for: newComics)
        }
    }

    func deleteGallery(id: UUID) {
        guard !(galleries.first(where: { $0.id == id })?.isImported ?? false) else { return }
        galleries.removeAll { $0.id == id }
        saveGalleries()
        // If the deleted gallery was the active sidebar selection, snap the
        // detail pane back to Home so it doesn't end up on a dead route.
        if case .gallery(let selected) = selectedSection, selected == id {
            selectedSection = .home
        }
    }

    func moveGallery(from source: IndexSet, to destination: Int) {
        galleries.move(fromOffsets: source, toOffset: destination)
        saveGalleries()
    }

    /// Reorder comics within a gallery (drag-to-reorder).
    func moveComics(in galleryID: UUID, from source: IndexSet, to destination: Int) {
        guard let idx = galleries.firstIndex(where: { $0.id == galleryID }) else { return }
        galleries[idx].comics.move(fromOffsets: source, toOffset: destination)
        saveGalleries()
    }

    /// Remove specific comic URLs from a gallery and persist the deletion
    /// so they do not reappear when addFolders re-scans source folders.
    func removeComics(_ urls: Set<URL>, from galleryID: UUID) {
        guard let idx = galleries.firstIndex(where: { $0.id == galleryID }) else { return }
        galleries[idx].comics.removeAll { urls.contains($0) }
        galleries[idx].deletedComics.formUnion(urls)
        saveGalleries()
    }

    /// Removes each URL in `urls` from EVERY gallery that contains it (including the
    /// Imported shelf) and from recents + favorites. Used by batch actions while
    /// searching, where the selection can span multiple galleries simultaneously.
    /// The underlying files on disk are untouched.
    func removeFromLibraryBatch(_ urls: Set<URL>) {
        for url in urls { removeFromLibrary(url: url) }
    }

    // MARK: - Batch helpers for multi-select actions (Task 6)
    // Each helper loops the existing single-URL method so the per-URL invariants
    // (de-dup, tombstone checks, canonical-key matching) are preserved exactly.
    // `removeComics(_:from:)` already accepts a Set<URL> — reuse it directly.

    /// Toggles the favorite state for each URL in `urls`.
    /// Wraps the existing single-URL `toggleFavorite(url:)`.
    func favorite(_ urls: Set<URL>) {
        for url in urls { toggleFavorite(url: url) }
    }

    /// Moves each URL in `urls` into the gallery identified by `id`.
    /// Wraps the existing single-URL `moveComic(_:toGallery:)`.
    func move(_ urls: Set<URL>, toGallery id: UUID) {
        for url in urls { moveComic(url, toGallery: id) }
    }

    /// Appends each URL in `urls` to the gallery identified by `id` without
    /// removing it from its current gallery.
    /// Wraps the existing `addComicFiles(_:to:)` (which takes an array).
    func addToGallery(_ urls: Set<URL>, _ id: UUID) {
        addComicFiles(Array(urls), to: id)
    }

    /// Reset a gallery's comic order back to folder-first, then alphabetical.
    func resetGalleryOrder(id: UUID) {
        guard let idx = galleries.firstIndex(where: { $0.id == id }) else { return }
        galleries[idx].comics = resolveComics(from: galleries[idx].sourceFolders)
        saveGalleries()
    }

    /// Re-scans the gallery's source folders and appends any comics that have
    /// been added to those folders since the last scan. Comics already in the
    /// gallery (or explicitly deleted by the user) are not re-added.
    /// No-op if the gallery has no source folders (e.g. the file-backed Imported gallery).
    func rescanGallery(id: UUID) {
        guard let idx = galleries.firstIndex(where: { $0.id == id }) else { return }
        guard !galleries[idx].sourceFolders.isEmpty else { return }
        let existingComics = Set(galleries[idx].comics)
        let deletedComics  = galleries[idx].deletedComics
        let newComics = resolveComics(from: galleries[idx].sourceFolders)
            .filter { !existingComics.contains($0) && !deletedComics.contains($0) }
        guard !newComics.isEmpty else { return }
        galleries[idx].comics.append(contentsOf: newComics)
        saveGalleries()
        generateThumbnails(for: newComics)
    }

    private func loadGalleries() {
        guard let data = defaults.data(forKey: galleriesKey) else { return }
        do {
            galleries = try JSONDecoder().decode([Gallery].self, from: data)
        } catch {
            // Galleries hold user-curated content — if this decode fails, the user's
            // library appears empty. Log loudly so a regression can be diagnosed
            // before the user has to report "my library disappeared".
            Task { await DCLogger.shared.log("[PERSIST] galleries decode failed: \(error) — library will appear empty until persistence is repaired") }
        }
    }

    private func saveGalleries() {
        let data: Data
        do {
            data = try JSONEncoder().encode(galleries)
        } catch {
            Task { await DCLogger.shared.log("[PERSIST] galleries encode failed: \(error) — library mutation not persisted; restart will revert") }
            return
        }
        defaults.set(data, forKey: galleriesKey)
    }

    // MARK: - Folder scanning

    /// Scans each folder in order, collecting comic files sorted alphabetically within
    /// each folder, then appending folder results in the order folders were added.
    private func resolveComics(from folders: [URL]) -> [URL] {
        let extensions: Set<String> = ["cbz", "cbr", "cbt", "cb7", "pdf"]
        var result: [URL] = []
        let fm = FileManager.default
        for folder in folders {
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var found: [URL] = []
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if extensions.contains(url.pathExtension.lowercased()) {
                    found.append(url.standardizedFileURL)
                }
            }
            found.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            result.append(contentsOf: found)
        }
        return result
    }

    // MARK: - Thumbnail helpers

    /// FNV-1a 64-bit hash — deterministic across processes and launches.
    /// Swift's built-in hashValue is randomised per-process (since Swift 4.2),
    /// which causes thumbnails saved in one session to be unfindable in the next.
    nonisolated static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037  // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211             // FNV prime
        }
        return hash
    }

    nonisolated static func thumbnailURL(for comicURL: URL) -> URL {
        let hash = stableHash(comicURL.path)
        return thumbnailCacheDir.appendingPathComponent("\(hash).jpg")
    }

    /// Disk-based lookup — loads from disk without touching the in-memory cache.
    /// Used by ComicCard as a fallback when the NSCache has evicted an entry.
    nonisolated static func loadThumbnail(for comicURL: URL) -> NSImage? {
        let url = thumbnailURL(for: comicURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Cache key used by both the pre-loader and the in-memory lookup.
    nonisolated static func thumbnailCacheKey(for comicURL: URL) -> String {
        return "\(stableHash(comicURL.path))"
    }

    /// Fast in-memory lookup — O(1), no disk I/O.
    /// Returns nil if NSCache has evicted the entry; callers should fall back to disk.
    func cachedThumbnail(for comicURL: URL) -> NSImage? {
        let key = LibraryViewModel.thumbnailCacheKey(for: comicURL) as NSString
        return thumbnailCache.object(forKey: key)
    }

    /// Re-insert an image into the NSCache and publish a refresh event on
    /// `thumbnailUpdates`. Used by ComicCard after a disk-fallback load.
    func insertIntoCache(_ image: NSImage, for comicURL: URL) {
        let key = LibraryViewModel.thumbnailCacheKey(for: comicURL) as NSString
        let isNew = thumbnailCache.object(forKey: key) == nil
        thumbnailCache.setObject(image, forKey: key)
        if isNew { thumbnailCacheCount += 1 }
        thumbnailUpdates.send(comicURL)
    }

    /// Save to disk, insert into the NSCache, and publish a refresh event
    /// on `thumbnailUpdates`.
    ///
    /// Uses ImageIO directly (CGImageDestination) instead of the old
    /// NSImage → lockFocus → TIFF → NSBitmapImageRep → JPEG roundtrip.
    /// On Apple Silicon this routes through the hardware JPEG encoder.
    /// The CGImage is cached directly — no disk reload needed.
    func saveThumbnailAndCache(_ image: NSImage, for comicURL: URL) {
        let diskURL = LibraryViewModel.thumbnailURL(for: comicURL)
        guard let cgImage = LibraryViewModel.scaledCGImage(from: image) else { return }

        // Write to disk via ImageIO — hardware-accelerated on Apple Silicon.
        LibraryViewModel.saveCGImage(cgImage, to: diskURL)

        // Cache the CGImage directly — no disk reload.
        let thumb = NSImage(cgImage: cgImage, size: .zero)
        let key = LibraryViewModel.thumbnailCacheKey(for: comicURL) as NSString
        let isNew = thumbnailCache.object(forKey: key) == nil
        thumbnailCache.setObject(thumb, forKey: key)
        if isNew { thumbnailCacheCount += 1 }

        thumbnailUpdates.send(comicURL)
    }

    // MARK: - Cache management

    /// The explicit set of UserDefaults keys that belong to reading progress.
    /// Using a static list (rather than a blanket wipe) ensures future keys
    /// like "bookmarks" survive unless explicitly added here.
    nonisolated static let readingProgressKeys: [String] = [
        "readingPositions", "scrollOffsets", "readingModes",
        "pageCounts", "scrollPagesPerRow", "recentComics"
    ]

    /// Removes all reading-progress keys from `defaults`. Injectable for testing.
    nonisolated static func removeReadingProgress(from defaults: UserDefaults = .standard) {
        for k in readingProgressKeys { defaults.removeObject(forKey: k) }
    }

    /// Deletes extracted page caches and thumbnail caches, clears the in-memory
    /// thumbnail NSCache, and kicks off thumbnail regeneration. Reading progress
    /// (positions, modes, recents) is untouched.
    func clearImageCaches() {
        // 1. Disk: extracted CBR/CB7 pages
        let pagesDir = ComicLoader.pageCacheDir
        if let files = try? FileManager.default.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            Task { await DCLogger.shared.log("[CACHE] Cleared \(files.count) extracted page cache(s).") }
        }
        // 2. Disk: thumbnails
        let thumbDir = LibraryViewModel.thumbnailCacheDir
        if let files = try? FileManager.default.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            Task { await DCLogger.shared.log("[CACHE] Cleared \(files.count) thumbnail(s).") }
        }
        // 3. In-memory thumbnail NSCache
        thumbnailCache.removeAllObjects()
        thumbnailCacheCount = 0
        // 6. Kick off thumbnail regeneration from scratch
        Task.detached(priority: .utility) { [weak self] in
            await self?.generateMissingThumbnails()
        }
        Task { await DCLogger.shared.log("[CACHE] Image caches cleared; thumbnails regenerating.") }
    }

    /// Removes all reading-progress UserDefaults keys (explicit list only — keys
    /// like "bookmarks" are unaffected) and clears the in-memory recents list.
    /// Image caches on disk are untouched.
    func resetReadingProgress() {
        // 4. UserDefaults: reading positions, scroll offsets, modes, page counts, recents
        Self.removeReadingProgress()
        // 5. Clear in-memory recents list
        recentComics = []
        Task { await DCLogger.shared.log("[CACHE] Reading progress reset.") }
    }

    /// Scales the source NSImage to the 200×280 thumbnail canvas and returns a CGImage.
    /// Uses CGContext directly — no NSImage lockFocus, no TIFF intermediate.
    nonisolated static func scaledCGImage(from image: NSImage) -> CGImage? {
        let w = 200, h = 280
        guard let cgSrc = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgSrc, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Writes a CGImage to disk as JPEG using ImageIO.
    /// On Apple Silicon, CGImageDestination routes through the hardware JPEG encoder.
    nonisolated static func saveCGImage(_ cgImage: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { return }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

}
