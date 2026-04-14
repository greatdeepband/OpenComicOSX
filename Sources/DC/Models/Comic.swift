import Foundation
import AppKit
import PDFKit
import ZIPFoundation

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
    /// A file on disk (extracted from CBR/CBT into the persistent page cache).
    case file(URL)
    /// A page inside a PDF document.
    case pdf(PDFDocument, Int)
    /// A page inside a ZIP archive (CBZ) — streamed on demand, no disk extraction.
    case zip(URL, String)   // archiveURL, entryPath

    /// Decodes and returns the image at screen resolution. Called on a background thread.
    ///
    /// Uses CGImageSourceCreateThumbnailAtIndex to decode at a maximum of 2048px on the
    /// long axis. This avoids loading the full print-resolution bitmap (e.g. 1988×3056,
    /// ~23 MB) into RAM — the OS scales during decode, keeping each page at ~10 MB.
    func decode() -> NSImage? {
        switch self {
        case .file(let url):
            let label = url.lastPathComponent
            Task { await DCLogger.shared.log("DECODE START  file:\(label)") }

            // Screen-resolution decode: max 2048px on the long axis covers all
            // current Mac displays at full window width without quality loss.
            let maxPx = 2048
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPx,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                let image = NSImage(cgImage: cgImg, size: .zero)
                Task { await DCLogger.shared.log("DECODE OK     file:\(label) size=\(image.size.width)x\(image.size.height)") }
                return image
            }

            // Fallback for formats CGImageSource cannot thumbnail (rare).
            Task { await DCLogger.shared.log("DECODE FALLBACK file:\(label) — CGImageSource failed, using NSImage") }
            guard let image = NSImage(contentsOf: url) else {
                Task { await DCLogger.shared.log("DECODE FAIL   file:\(label) — NSImage(contentsOf:) also returned nil") }
                let exists = FileManager.default.fileExists(atPath: url.path)
                let size   = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                Task { await DCLogger.shared.log("              exists=\(exists) size=\(size)B path=\(url.path)") }
                return nil
            }
            image.lockFocus()
            image.unlockFocus()
            Task { await DCLogger.shared.log("DECODE OK     file:\(label) size=\(image.size.width)x\(image.size.height)") }
            return image

        case .pdf(let doc, let pageIndex):
            Task { await DCLogger.shared.log("DECODE START  pdf:page\(pageIndex)") }
            guard let page = doc.page(at: pageIndex) else {
                Task { await DCLogger.shared.log("DECODE FAIL   pdf:page\(pageIndex) — doc.page(at:) returned nil") }
                return nil
            }
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
            Task { await DCLogger.shared.log("DECODE OK     pdf:page\(pageIndex) size=\(size.width)x\(size.height)") }
            return image
        case .zip(let archiveURL, let entryPath):
            let label = (entryPath as NSString).lastPathComponent
            Task { await DCLogger.shared.log("DECODE START  zip:\(label)") }
            guard let archive = try? Archive(url: archiveURL, accessMode: .read),
                  let entry = archive[entryPath] else {
                Task { await DCLogger.shared.log("DECODE FAIL   zip:\(label) — entry not found") }
                return nil
            }
            let imageSource = CGImageSourceCreateIncremental(nil)
            var accumulated = Data()
            do {
                try archive.extract(entry) { chunk in
                    accumulated.append(chunk)
                    CGImageSourceUpdateData(imageSource, accumulated as CFData, false)
                }
                CGImageSourceUpdateData(imageSource, accumulated as CFData, true)
            } catch {
                Task { await DCLogger.shared.log("DECODE FAIL   zip:\(label) — extract error: \(error)") }
                return nil
            }
            let maxPx = 2048
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPx,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImg = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                Task { await DCLogger.shared.log("DECODE FAIL   zip:\(label) — CGImageSource thumbnail failed") }
                return nil
            }
            let image = NSImage(cgImage: cgImg, size: .zero)
            Task { await DCLogger.shared.log("DECODE OK     zip:\(label) size=\(image.size.width)x\(image.size.height)") }
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
            // Metadata read failed — page will get 1×1 placeholder size.
            Task { await DCLogger.shared.log("NATURAL_SIZE FAIL  file:\(url.lastPathComponent) — CGImageSource metadata unavailable, falling back to 1×1") }
            return CGSize(width: 1, height: 1)
        case .pdf(let doc, let pageIndex):
            guard let page = doc.page(at: pageIndex) else { return CGSize(width: 1, height: 1) }
            let b = page.bounds(for: .mediaBox)
            return CGSize(width: b.width * 2, height: b.height * 2)
        case .zip(let archiveURL, let entryPath):
            // Stream just the image metadata from the ZIP entry — no full decode.
            guard let archive = try? Archive(url: archiveURL, accessMode: .read),
                  let entry = archive[entryPath] else { return CGSize(width: 1, height: 1) }
            var headerData = Data()
            let headerSize = min(entry.uncompressedSize, 65536)
            do {
                try archive.extract(entry, bufferSize: UInt32(headerSize)) { chunk in
                    headerData.append(chunk)
                    if headerData.count >= Int(headerSize) { throw CancellationError() }
                }
            } catch is CancellationError { /* expected — we only want the header */ }
            catch { return CGSize(width: 1, height: 1) }
            guard let src = CGImageSourceCreateWithData(headerData as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
                  let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
                  w > 0, h > 0 else { return CGSize(width: 1, height: 1) }
            return CGSize(width: w, height: h)
        }
    }
}

/// A single page in a comic — stores the source reference, not the decoded image.
struct ComicPage: Identifiable {
    let id: Int          // page index (0-based)
    let source: PageSource
    /// Natural size (width/height) used for layout before the image is decoded.
    let naturalSize: CGSize

    /// True when the page is a double-page spread scanned as a single wide image.
    /// Detected by aspect ratio: width/height > 1.2 (landscape).
    /// Normal portrait pages are ~0.65; double scans are typically 1.3–1.6.
    var isSpread: Bool {
        naturalSize.width / max(naturalSize.height, 1) > 1.2
    }

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
