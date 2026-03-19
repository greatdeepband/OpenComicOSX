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
    /// Computed from ReadingPositionStore — not stored in Codable (no page count available here).
    var readingProgress: Double? {
        let page = ReadingPositionStore.page(for: url)
        return page > 0 ? Double(page) / 100.0 : nil
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

    /// Incremented whenever a thumbnail is saved or loaded — cards observe this to reload.
    @Published var thumbnailGeneration: Int = 0

    /// Current search query — empty string means no filter.
    @Published var searchQuery: String = ""

    /// Bound to ScrollView.scrollPosition(id:) — set to lastOpenedURL on reader close to restore position.
    @Published var libraryScrollID: URL? = nil

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

    private let recentsKey = "recentComics"
    private let galleriesKey = "galleries_v1"

    /// Disk cache directory for cover thumbnails.
    static let thumbnailCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("DC/Thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadRecents()
        loadGalleries()
        // Preload thumbnails for the current library, then generate any that are missing.
        Task.detached(priority: .utility) { [weak self] in
            await self?.preloadThumbnailCache()
            await self?.generateMissingThumbnails()
        }
    }

    // MARK: - Scoped cache pre-load

    /// Loads thumbnails from disk into the NSCache for every comic currently in the
    /// library (recents + all galleries). Thumbnails for comics that are no longer in
    /// the library are intentionally skipped — they stay on disk but are never decoded
    /// into RAM unless the user opens that comic again.
    private func preloadThumbnailCache() async {
        let recents = await recentComics
        let allGalleries = await galleries

        // Build the set of cache keys we actually need.
        var needed: [String] = recents.map { LibraryViewModel.thumbnailCacheKey(for: $0.url) }
        for gallery in allGalleries {
            for url in gallery.comics {
                needed.append(LibraryViewModel.thumbnailCacheKey(for: url))
            }
        }
        // Deduplicate (a comic can appear in multiple galleries).
        let uniqueKeys = Array(Set(needed))

        let dir = LibraryViewModel.thumbnailCacheDir
        for key in uniqueKeys {
            let fileURL = dir.appendingPathComponent("\(key).jpg")
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let img = NSImage(contentsOf: fileURL)
            else { continue }
            let nsKey = key as NSString
            await MainActor.run {
                self.thumbnailCache.setObject(img, forKey: nsKey)
            }
        }
        // Signal cards to re-render now that the cache is populated.
        await MainActor.run { self.thumbnailGeneration += 1 }
    }

    // MARK: - Background thumbnail generation on launch

    private func generateMissingThumbnails() async {
        let recents = await recentComics
        let allGalleries = await galleries
        var all: [URL] = recents.map { $0.url }
        for gallery in allGalleries { all.append(contentsOf: gallery.comics) }
        await generateThumbnailsParallel(for: all)
    }

    /// Extract and cache covers for a list of URLs, 8 at a time.
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
                }
                inFlight += 1
                group.addTask(priority: .background) { [weak self] in
                    guard let self else { return }
                    let cover = ComicLoader.loadCover(url: url)
                    guard let cover else { return }
                    await MainActor.run { self.saveThumbnailAndCache(cover, for: url) }
                }
            }
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
            addRecent(url: url)
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
        openComic = nil
    }

    func removeRecent(_ recent: RecentComic) {
        recentComics.removeAll { $0.id == recent.id }
        saveRecents()
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
        // Append only new folders
        let existing = Set(galleries[idx].sourceFolders.map { $0.path })
        let newFolders = folders.filter { !existing.contains($0.path) }
        galleries[idx].sourceFolders.append(contentsOf: newFolders)
        galleries[idx].comics = resolveComics(from: galleries[idx].sourceFolders)
        saveGalleries()
        Task.detached(priority: .background) { [weak self, comics = galleries[idx].comics] in
            await self?.generateThumbnailsParallel(for: comics)
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

    nonisolated static func thumbnailURL(for comicURL: URL) -> URL {
        let hash = abs(comicURL.path.hashValue)
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
        let hash = abs(comicURL.path.hashValue)
        return "\(hash)"
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
        thumbnailCache.setObject(image, forKey: key)
    }

    /// Save to disk and insert into the NSCache.
    /// The cache stores the 200×280 scaled thumbnail, NOT the original full-res image.
    func saveThumbnailAndCache(_ image: NSImage, for comicURL: URL) {
        let url = LibraryViewModel.thumbnailURL(for: comicURL)
        LibraryViewModel.saveThumbnail(image, to: url)
        let key = LibraryViewModel.thumbnailCacheKey(for: comicURL) as NSString
        // Re-load from disk so we store the compressed JPEG decode, not the raw bitmap.
        if let thumb = NSImage(contentsOf: url) {
            thumbnailCache.setObject(thumb, forKey: key)
        }
        thumbnailGeneration += 1
    }

    nonisolated static func saveThumbnail(_ image: NSImage, to url: URL) {
        let size = CGSize(width: 200, height: 280)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        thumb.unlockFocus()

        guard let tiff = thumb.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        try? jpeg.write(to: url)
    }
}
