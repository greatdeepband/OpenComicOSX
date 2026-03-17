import Foundation
import AppKit

/// Represents a single comic book loaded into the reader.
struct Comic: Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let format: ComicFormat
    /// All page images, lazily decoded by the loader.
    var pages: [ComicPage]

    init(url: URL, format: ComicFormat, pages: [ComicPage]) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.format = format
        self.pages = pages
    }
}

/// A single page in a comic — holds a reference so we can lazy-load.
struct ComicPage: Identifiable {
    let id: Int          // page index (0-based)
    let image: NSImage
}

enum ComicFormat: String, CaseIterable {
    case cbz = "cbz"
    case cbr = "cbr"
    case cb7 = "cb7"
    case cbt = "cbt"
    case pdf = "pdf"
    case epub = "epub"

    static func from(url: URL) -> ComicFormat? {
        let ext = url.pathExtension.lowercased()
        return ComicFormat(rawValue: ext)
    }

    var displayName: String { rawValue.uppercased() }
}
