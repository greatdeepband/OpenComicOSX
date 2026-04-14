import Foundation
import AppKit
import SwiftUI

// MARK: - Gallery model

/// A named, ordered collection of comic files sourced from one or more folders.
struct Gallery: Identifiable, Codable {
    var id: UUID
    var name: String
    /// Source folders, in the order the user added them.
    var sourceFolders: [URL]
    /// Resolved comic URLs — folder order first, then alphabetically within each folder.
    var comics: [URL]

    init(id: UUID = UUID(), name: String, sourceFolders: [URL] = [], comics: [URL] = []) {
        self.id = id
        self.name = name
        self.sourceFolders = sourceFolders
        self.comics = comics
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

    /// True after the first cold launch — survives LibraryView re-creation.
    var hasLaunched: Bool = false

    /// Collapsed gallery section keys — survives LibraryView re-creation.
    @Published var collapsedSections: Set<String> = []

    /// Set of URLs whose thumbnails were just updated.
    /// Cards observe this and re-render only when their own URL is present,
    /// eliminating the O(n) full-grid re-render caused by a global counter.
    /// Cleared on the next run loop tick after publishing.
    @Published var updatedThumbnailURLs: Set<URL> = []

    /// Pending URLs not yet flushed to updatedThumbnailURLs.
    private var pendingURLs: Set<URL> = []
    private var flushScheduled = false

    /// Current search query — empty string means no filter.
    @Published var searchQuery: String = ""

    /// Ordered list of favorited comic URLs (most recently favorited first).
    @Published var favoriteURLs: [URL] = []

    /// Recent comics filtered by searchQuery (case-insensitive substring match on title).
    var filteredRecentComics: [RecentComic] {
        guard !searchQuery.isEmpty else { return recentComics }
        return recentComics.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    /// Flat deduplicated list of all comics matching searchQuery across recents and all galleries.
    var searchResults: [URL] {
        guard !searchQuery.isEmpty else { return [] }
        var seen = Set<URL>()
        var results: [URL] = []
        let allURLs = recentComics.map { $0.url }
            + galleries.flatMap { $0.comics }
        for url in allURLs {
            guard !seen.contains(url) else { continue }
            let title = url.deletingPathExtension().lastPathComponent
            if title.localizedCaseInsensitiveContains(searchQuery) {
                seen.insert(url)
                results.append(url)
            }
        }
        return results
    }

    /// Galleries filtered by searchQuery — each gallery's comic list is also filtered.
    var filteredGalleries: [Gallery] {
        guard !searchQuery.isEmpty else { return galleries }
        return galleries.compactMap { gallery in
            let filtered = gallery.comics.filter {
                $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(searchQuery)
            }
            // Only include the gallery if it has matching comics.
            guard !filtered.isEmpty else { return nil }
            var copy = gallery
            copy.comics = filtered
            return copy
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

    /// Disk cache directory for cover thumbnails.
    static let thumbnailCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("DC/Thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadRecents()
        loadGalleries()
        loadFavorites()
        // One-time migration: wipe the entire thumbnail cache on first launch after
        // switching from Swift's non-deterministic hashValue to FNV-1a.
        // All old files have names that don't match any FNV-1a key, so purgeOrphanedThumbnails
        // would delete them anyway — but doing it upfront avoids a false "all missing" state
        // that triggers a full regeneration pass on every launch until the purge runs.
        let migrationKey = "thumbnailScheme_fnv1a_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            let dir = LibraryViewModel.thumbnailCacheDir
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files { try? FileManager.default.removeItem(at: file) }
                Task { await DCLogger.shared.log("[THUMB] Migration: cleared \(files.count) old hashValue thumbnail(s).") }
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
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
        await MainActor.run { flushThumbnailGeneration() }
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
                    guard let cgImage = ComicLoader.loadCoverCGImage(url: url) else { return }
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
                            // Notify only this card — no full-grid re-render.
                            self.pendingURLs.insert(url)
                            self.scheduleFlush()
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
                    // Notify only this card — no full-grid re-render.
                    self.pendingURLs.insert(comicURL)
                    self.scheduleFlush()
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
        panel.allowedContentTypes = []
        panel.message = "Choose a CBZ, PDF, CBR, CB7, or CBT file"

        if panel.runModal() == .OK, let url = panel.url {
            Task { await load(url: url) }
        }
    }

    // MARK: - Loading

    func load(url: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let comic = try await Task.detached(priority: .userInitiated) {
                try ComicLoader.load(url: url)
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
                   let cover = ComicLoader.loadCover(url: url) {
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
            // Remove this URL from updatedThumbnailURLs so that when the card
            // reappears and requestThumbnail fires scheduleFlush, the Set value
            // genuinely changes and onChange triggers a re-render on the card.
            // Without this, the URL stays in the Set from the background thumbnail
            // generation that ran while the reader was open, and the subsequent
            // scheduleFlush produces no Set change — so onChange never fires.
            updatedThumbnailURLs.remove(url)
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

    // MARK: - Favorites

    func isFavorite(url: URL) -> Bool {
        favoriteURLs.contains(url)
    }

    func toggleFavorite(url: URL) {
        if isFavorite(url: url) {
            favoriteURLs.removeAll { $0 == url }
        } else {
            favoriteURLs.insert(url, at: 0)
        }
        saveFavorites()
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        favoriteURLs = paths.compactMap { URL(string: $0) }
    }

    private func saveFavorites() {
        let paths = favoriteURLs.map { $0.absoluteString }
        guard let data = try? JSONEncoder().encode(paths) else { return }
        UserDefaults.standard.set(data, forKey: favoritesKey)
    }

    // MARK: - Recents

    private func addRecent(url: URL) {
        let entry = RecentComic(url: url)
        recentComics.removeAll { $0.url == url }
        recentComics.insert(entry, at: 0)
        if recentComics.count > 20 { recentComics = Array(recentComics.prefix(20)) }
        saveRecents()
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let decoded = try? JSONDecoder().decode([RecentComic].self, from: data)
        else { return }
        recentComics = decoded
    }

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recentComics) else { return }
        UserDefaults.standard.set(data, forKey: recentsKey)
    }

    // MARK: - Galleries

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
        // Re-scan all source folders but only append comics not already present.
        // This preserves manual removals and custom ordering.
        let existingComics = Set(galleries[idx].comics)
        let newComics = resolveComics(from: galleries[idx].sourceFolders)
            .filter { !existingComics.contains($0) }
        galleries[idx].comics.append(contentsOf: newComics)
        saveGalleries()
        Task.detached(priority: .background) { [weak self, newComics] in
            await self?.generateThumbnailsParallel(for: newComics)
        }
    }

    func deleteGallery(id: UUID) {
        galleries.removeAll { $0.id == id }
        saveGalleries()
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

    /// Remove specific comic URLs from a gallery.
    func removeComics(_ urls: Set<URL>, from galleryID: UUID) {
        guard let idx = galleries.firstIndex(where: { $0.id == galleryID }) else { return }
        galleries[idx].comics.removeAll { urls.contains($0) }
        saveGalleries()
    }

    /// Reset a gallery's comic order back to folder-first, then alphabetical.
    func resetGalleryOrder(id: UUID) {
        guard let idx = galleries.firstIndex(where: { $0.id == id }) else { return }
        galleries[idx].comics = resolveComics(from: galleries[idx].sourceFolders)
        saveGalleries()
    }

    private func loadGalleries() {
        guard let data = UserDefaults.standard.data(forKey: galleriesKey),
              let decoded = try? JSONDecoder().decode([Gallery].self, from: data)
        else { return }
        galleries = decoded
    }

    private func saveGalleries() {
        guard let data = try? JSONEncoder().encode(galleries) else { return }
        UserDefaults.standard.set(data, forKey: galleriesKey)
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
                    found.append(url)
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

    /// Re-insert an image into the NSCache (used by ComicCard after a disk fallback load).
    func insertIntoCache(_ image: NSImage, for comicURL: URL) {
        let key = LibraryViewModel.thumbnailCacheKey(for: comicURL) as NSString
        let isNew = thumbnailCache.object(forKey: key) == nil
        thumbnailCache.setObject(image, forKey: key)
        if isNew { thumbnailCacheCount += 1 }
    }

    /// Save to disk and insert into the NSCache.
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

        // Notify only this card — no full-grid re-render.
        pendingURLs.insert(comicURL)
        scheduleFlush()
    }

    /// Schedules a single run-loop flush of pendingURLs → updatedThumbnailURLs.
    /// Multiple insertions within the same run loop are coalesced into one publish.
    ///
    /// The set is never cleared — SwiftUI's onChange only fires when the value
    /// actually changes (i.e. when a new URL is inserted), so idempotent calls
    /// are free. Clearing on the next tick caused a race where onChange fired
    /// after the set was already empty, leaving cards permanently blank.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Assign (not union) so value always transitions {} -> {batch},
            // guaranteeing onChange fires even if URL was in a prior flush.
            let batch = self.pendingURLs
            self.pendingURLs = []
            self.flushScheduled = false
            self.updatedThumbnailURLs = []
            self.updatedThumbnailURLs = batch
        }
    }

    // MARK: - Cache management

    /// Wipes all disk caches (extracted pages + thumbnails) and all reading-state UserDefaults.
    /// Galleries and favorites are preserved. Thumbnails regenerate automatically.
    func clearAllCache() {
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
        // 4. UserDefaults: reading positions, scroll offsets, modes, page counts, recents
        for key in ["readingPositions", "scrollOffsets", "readingModes", "pageCounts", recentsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // 5. Clear in-memory recents list
        recentComics = []
        // 6. Kick off thumbnail regeneration from scratch
        Task.detached(priority: .utility) { [weak self] in
            await self?.generateMissingThumbnails()
        }
        Task { await DCLogger.shared.log("[CACHE] Full cache clear complete.") }
    }

    /// Called at the end of generateThumbnailsParallel to ensure the last batch is shown.
    private func flushThumbnailGeneration() {
        if !pendingURLs.isEmpty {
            scheduleFlush()
        }
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
