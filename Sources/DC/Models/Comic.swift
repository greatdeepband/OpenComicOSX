import Foundation
import AppKit
import PDFKit

/// Represents a single comic book loaded into the reader.
struct Comic: Identifiable, Equatable {
    static func == (lhs: Comic, rhs: Comic) -> Bool { lhs.id == rhs.id }
    let id: UUID
    let url: URL
    let title: String
    let format: ComicFormat
    /// All pages — images are loaded lazily on demand via PageImageCache.
    var pages: [ComicPage]

    init(url: URL, format: ComicFormat, pages: [ComicPage]) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.format = format
        self.pages = pages
    }
}

/// The backing source for a single comic page.
/// Images are never decoded at load time — only when the reader requests them.
enum PageSource {
    /// A file on disk (extracted from CBZ/CBR/CBT into the persistent page cache).
    case file(URL)
    /// A page inside a PDF document.
    case pdf(PDFDocument, Int)

    /// Decodes and returns the full-resolution NSImage. Called on a background thread.
    func decode() -> NSImage? {
        switch self {
        case .file(let url):
            guard let image = NSImage(contentsOf: url) else { return nil }
            // Force bitmap decode so the image is ready to draw immediately.
            image.lockFocus()
            image.unlockFocus()
            return image

        case .pdf(let doc, let pageIndex):
            guard let page = doc.page(at: pageIndex) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = NSImage(size: size)
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()
            return image
        }
    }

    /// Approximate natural size without full decode (used for layout before image is ready).
    var naturalSize: CGSize {
        switch self {
        case .file(let url):
            // Read image dimensions from metadata only — no full decode.
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
               let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
               w > 0, h > 0 {
                return CGSize(width: w, height: h)
            }
            return CGSize(width: 1, height: 1)
        case .pdf(let doc, let pageIndex):
            guard let page = doc.page(at: pageIndex) else { return CGSize(width: 1, height: 1) }
            let b = page.bounds(for: .mediaBox)
            return CGSize(width: b.width * 2, height: b.height * 2)
        }
    }
}

/// A single page in a comic — stores the source reference, not the decoded image.
struct ComicPage: Identifiable {
    let id: Int          // page index (0-based)
    let source: PageSource
    /// Natural size (width/height) used for layout before the image is decoded.
    let naturalSize: CGSize

    init(id: Int, source: PageSource) {
        self.id = id
        self.source = source
        self.naturalSize = source.naturalSize
    }
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
