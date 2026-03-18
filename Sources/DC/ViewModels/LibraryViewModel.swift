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

    /// Incremented whenever a thumbnail is saved — cards observe this to reload.
    @Published var thumbnailGeneration: Int = 0

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
        Task.detached(priority: .background) { [weak self] in
            await self?.generateMissingThumbnails()
        }
    }

    // MARK: - Background thumbnail generation on launch

    private func generateMissingThumbnails() async {
        // Recents
        let recents = await recentComics
        for recent in recents {
            await generateThumbnailIfNeeded(for: recent.url)
        }
        // Galleries
        let allGalleries = await galleries
        for gallery in allGalleries {
            for url in gallery.comics {
                await generateThumbnailIfNeeded(for: url)
            }
        }
    }

    private func generateThumbnailIfNeeded(for url: URL) async {
        let thumbURL = LibraryViewModel.thumbnailURL(for: url)
        guard !FileManager.default.fileExists(atPath: thumbURL.path) else { return }
        let cover = await Task.detached(priority: .background) {
            ComicLoader.loadCover(url: url)
        }.value
        guard let cover else { return }
        LibraryViewModel.saveThumbnail(cover, to: thumbURL)
        await MainActor.run { self.thumbnailGeneration += 1 }
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
            addRecent(url: url)
            // Generate thumbnail in background if not already cached.
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                let thumbURL = LibraryViewModel.thumbnailURL(for: url)
                if !FileManager.default.fileExists(atPath: thumbURL.path),
                   let cover = comic.pages.first?.image {
                    LibraryViewModel.saveThumbnail(cover, to: thumbURL)
                    await MainActor.run { self.thumbnailGeneration += 1 }
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
        // Cache thumbnails in background
        Task.detached(priority: .background) { [weak self, comics = gallery.comics] in
            for url in comics {
                await self?.generateThumbnailIfNeeded(for: url)
            }
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
            for url in comics {
                await self?.generateThumbnailIfNeeded(for: url)
            }
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

    /// Scans each folder in order, collecting comic files sorted alphabetically within each folder.
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

    nonisolated static func loadThumbnail(for comicURL: URL) -> NSImage? {
        let url = thumbnailURL(for: comicURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
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
