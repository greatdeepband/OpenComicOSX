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
    /// A page inside a ZIP archive (CBZ) — streamed on demand via file path (disk IO).
    case zip(URL, String)   // archiveURL, entryPath
    /// A page inside a ZIP archive whose entire content is pre-loaded in RAM.
    /// No disk IO during scroll — the `data` is the raw compressed CBZ bytes.
    case zipData(Data, String)  // compressedCBZData, entryPath

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
            guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
                Task { await DCLogger.shared.log("DECODE FAIL   zip:\(label) — could not open archive at \(archiveURL.path)") }
                return nil
            }
            guard let entry = archive[entryPath] else {
                Task { await DCLogger.shared.log("DECODE FAIL   zip:\(label) — entry '\(entryPath)' not found in archive") }
                return nil
            }
            // Decompression-bomb guard — same shared cap as the .zipData path.
            let accumulated: Data
            do {
                accumulated = try archive.extractEntryData(
                    entry, cap: ReaderConstants.maxUncompressedBytes)
            } catch Archive.CappedExtractError.entryTooLarge {
                Task { await DCLogger.shared.log("DECODE FAIL   zip:\(label) — entry exceeded \(ReaderConstants.maxUncompressedBytes)B uncompressed cap (decompression bomb), aborted") }
                return nil
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
            guard let src = CGImageSourceCreateWithData(accumulated as CFData, nil),
                  let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                Task { await DCLogger.shared.log("DECODE FAIL   zip:\(label) — CGImageSource thumbnail failed") }
                return nil
            }
            let image = NSImage(cgImage: cgImg, size: .zero)
            Task { await DCLogger.shared.log("DECODE OK     zip:\(label) size=\(image.size.width)x\(image.size.height)") }
            return image
        case .zipData(let archiveData, let entryPath):
            let label = (entryPath as NSString).lastPathComponent
            guard let archive = try? Archive(data: archiveData, accessMode: .read) else {
                Task { await DCLogger.shared.log("DECODE FAIL   zipData:\(label) — could not open in-memory archive (\(archiveData.count)B)") }
                return nil
            }
            guard let entry = archive[entryPath] else {
                Task { await DCLogger.shared.log("DECODE FAIL   zipData:\(label) — entry '\(entryPath)' not found in archive") }
                return nil
            }
            // Decompression-bomb guard (second of two layers; the first is
            // ComicLoader's pre-flight central-directory sum). Route through the
            // shared capped-extract helper — `extractEntryData` is the single
            // implementation of the streaming byte counter. A lying central
            // directory that under-declares `uncompressedSize` trips this cap
            // at first decode before the inflated data reaches RAM.
            let accumulated: Data
            do {
                accumulated = try archive.extractEntryData(
                    entry, cap: ReaderConstants.maxUncompressedBytes)
            } catch Archive.CappedExtractError.entryTooLarge {
                Task { await DCLogger.shared.log("DECODE FAIL   zipData:\(label) — entry exceeded \(ReaderConstants.maxUncompressedBytes)B uncompressed cap (decompression bomb), aborted") }
                return nil
            } catch {
                Task { await DCLogger.shared.log("DECODE FAIL   zipData:\(label) — extract error: \(error)") }
                return nil
            }
            let maxPx = 2048
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPx,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let src = CGImageSourceCreateWithData(accumulated as CFData, nil),
                  let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                Task { await DCLogger.shared.log("DECODE FAIL   zipData:\(label) — CGImageSource thumbnail failed") }
                return nil
            }
            let image = NSImage(cgImage: cgImg, size: .zero)
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
                  let entry = archive[entryPath] else {
                Task { await DCLogger.shared.log("NATURAL_SIZE FAIL  zip:\((entryPath as NSString).lastPathComponent) — archive open or entry lookup failed, falling back to 1×1") }
                return CGSize(width: 1, height: 1)
            }
            return imageSizeFromArchiveEntry(archive, entry)
        case .zipData(let archiveData, let entryPath):
            guard let archive = try? Archive(data: archiveData, accessMode: .read),
                  let entry = archive[entryPath] else {
                Task { await DCLogger.shared.log("NATURAL_SIZE FAIL  zipData:\((entryPath as NSString).lastPathComponent) — archive open or entry lookup failed, falling back to 1×1") }
                return CGSize(width: 1, height: 1)
            }
            return imageSizeFromArchiveEntry(archive, entry)
        }
    }

    /// Sentinel thrown to abort `archive.extract` once enough header bytes are
    /// buffered. A dedicated type (not `CancellationError`) so a generic
    /// `catch is CancellationError` elsewhere can never conflate this early-exit
    /// I/O optimization with a real user-initiated task cancellation.
    private enum HeaderReadComplete: Error { case enoughBytes }

    /// Extract just the image header bytes to determine dimensions — no full decode.
    private func imageSizeFromArchiveEntry(_ archive: Archive, _ entry: Entry) -> CGSize {
        var headerData = Data()
        let headerSize = min(entry.uncompressedSize, 65536)
        do {
            try archive.extract(entry, bufferSize: UInt32(headerSize)) { chunk in
                headerData.append(chunk)
                if headerData.count >= Int(headerSize) { throw HeaderReadComplete.enoughBytes }
            }
        } catch HeaderReadComplete.enoughBytes { /* expected — we only want the header */ }
        catch {
            Task { await DCLogger.shared.log("NATURAL_SIZE FAIL  \((entry.path as NSString).lastPathComponent) — header extract error: \(error), falling back to 1×1") }
            return CGSize(width: 1, height: 1)
        }
        guard let src = CGImageSourceCreateWithData(headerData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else {
            Task { await DCLogger.shared.log("NATURAL_SIZE FAIL  \((entry.path as NSString).lastPathComponent) — could not read dimensions from \(headerData.count)B header, falling back to 1×1") }
            return CGSize(width: 1, height: 1)
        }
        return CGSize(width: w, height: h)
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

    /// - Parameter naturalSize: when supplied, the page uses this precomputed
    ///   size instead of deriving it from `source.naturalSize`. For `.pdf`
    ///   sources the size MUST be precomputed via `PDFKitGate` and injected
    ///   here so the (non-thread-safe) `source.naturalSize`'s `.pdf` branch is
    ///   never hit off the gate's serial executor. Non-PDF call sites can keep
    ///   passing `nil` and rely on the synchronous metadata read.
    init(id: Int, source: PageSource, naturalSize: CGSize? = nil) {
        self.id = id
        self.source = source
        self.naturalSize = naturalSize ?? source.naturalSize
    }

    /// Testing-only initializer that lets callers supply an explicit
    /// `naturalSize` (and therefore control `isSpread`) without needing a
    /// real image file or archive.  Not intended for production call-sites.
    init(id: Int, source: PageSource, naturalSize: CGSize) {
        self.id = id
        self.source = source
        self.naturalSize = naturalSize
    }
}

enum ComicFormat: String, CaseIterable {
    case cbz = "cbz"
    case cbr = "cbr"
    case cb7 = "cb7"
    case cbt = "cbt"
    case pdf = "pdf"

    static func from(url: URL) -> ComicFormat? {
        let ext = url.pathExtension.lowercased()
        return ComicFormat(rawValue: ext)
    }

    var displayName: String { rawValue.uppercased() }
}
