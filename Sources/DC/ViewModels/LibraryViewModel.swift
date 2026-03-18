import Foundation
import AppKit
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var recentComics: [RecentComic] = []
    @Published var openComic: Comic? = nil
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    private let recentsKey = "recentComics"

    /// Disk cache directory for cover thumbnails.
    static let thumbnailCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("DC/Thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadRecents()
    }

    // MARK: - File Picker

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

    // MARK: - Thumbnail helpers

    nonisolated static func thumbnailURL(for comicURL: URL) -> URL {
        // Use a stable hash of the file path as the filename.
        let hash = abs(comicURL.path.hashValue)
        return thumbnailCacheDir.appendingPathComponent("\(hash).jpg")
    }

    nonisolated static func loadThumbnail(for comicURL: URL) -> NSImage? {
        let url = thumbnailURL(for: comicURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    nonisolated private static func saveThumbnail(_ image: NSImage, to url: URL) {
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

struct RecentComic: Identifiable, Codable {
    let id: UUID
    let url: URL
    var title: String { url.deletingPathExtension().lastPathComponent }
    /// Computed from ReadingPositionStore — not stored in Codable (no page count available here).
    var readingProgress: Double? {
        // We don't know total pages without loading the file, so return nil here.
        // LibraryView can show a badge only when progress > 0 (page > 0).
        let page = ReadingPositionStore.page(for: url)
        return page > 0 ? Double(page) / 100.0 : nil  // rough indicator, refined when opened
    }

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}
