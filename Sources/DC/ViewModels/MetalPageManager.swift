import AppKit
import Foundation
import CoreVideo
import ImageIO
import PDFKit
import ZIPFoundation

/// Actor that manages async page decoding and the decoded CVPixelBuffer cache
/// feeding the Metal vertical reader. Handles every `PageSource` variant
/// — `.zipData` (CBZ in-memory), `.file` (CBR/CB7/CBT extracted to disk, or
/// any standalone image), `.zip` (disk-backed archive), `.pdf` (PDF page).
/// Only `maxCachedPages` (10) are kept in memory at once.
actor MetalPageManager {
    private var decodedPages: [Int: CVPixelBuffer] = [:]
    private var pendingPages: Set<Int> = []
    private var lastAccessTimes: [Int: Date] = [:]
    private let maxCachedPages = 10

    /// Parallel NSImage cache derived from `decodedPages`. Populated lazily
    /// after each decode. Actor-state is the CVPixelBuffer dict; this is a
    /// nonisolated NSCache read from any context (SwiftUI render paths).
    /// Evicted in lockstep with the CVPixelBuffer when `store(...)` crosses
    /// the LRU cap or `evictOutside(_:)` runs.
    nonisolated let nsImageCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 10
        return cache
    }()

    /// Decode a single page from a PageSource into a BGRA CVPixelBuffer.
    /// Returns nil if decoding fails. Caches successful results and evicts
    /// LRU entries when over the cap.
    func decodePage(pageIndex: Int, from source: PageSource) async -> CVPixelBuffer? {
        if decodedPages[pageIndex] != nil { return decodedPages[pageIndex] }
        if pendingPages.contains(pageIndex) { return nil }
        pendingPages.insert(pageIndex)
        defer { pendingPages.remove(pageIndex) }

        let buffer: CVPixelBuffer?
        switch source {
        case .zipData(let archiveData, let entryPath):
            buffer = decodeZipDataPage(archiveData: archiveData, entryPath: entryPath)
        case .zip(let archiveURL, let entryPath):
            buffer = decodeZipFilePage(archiveURL: archiveURL, entryPath: entryPath)
        case .file(let fileURL):
            buffer = decodeFilePage(at: fileURL)
        case .pdf(let doc, let pdfIndex):
            buffer = decodePDFPage(doc: doc, pageIndex: pdfIndex)
        }

        if let buffer {
            store(buffer, for: pageIndex)
        }
        return buffer
    }

    /// Legacy decode for callers that pass archiveData + entryPath directly.
    func decodePage(pageIndex: Int, from archiveData: Data, entryPath: String) async -> CVPixelBuffer? {
        return await decodePage(pageIndex: pageIndex, from: .zipData(archiveData, entryPath))
    }

    func page(for pageIndex: Int) -> CVPixelBuffer? {
        lastAccessTimes[pageIndex] = Date()
        return decodedPages[pageIndex]
    }

    /// O(1) NSImage lookup — returns the pre-converted NSImage if present,
    /// or nil if nothing is decoded for that page yet. Intended for SwiftUI
    /// render paths that need to bail and wait for the `onPageReadyNSImage`
    /// callback to trigger a re-render.
    nonisolated func nsImage(for pageIndex: Int) -> NSImage? {
        nsImageCache.object(forKey: NSNumber(value: pageIndex))
    }

    func evictOutside(_ range: ClosedRange<Int>) {
        let survivors = decodedPages.keys.filter { range.contains($0) }
        let evicted = Set(decodedPages.keys).subtracting(survivors)
        decodedPages = decodedPages.filter { range.contains($0.key) }
        lastAccessTimes = lastAccessTimes.filter { range.contains($0.key) }
        for key in evicted {
            nsImageCache.removeObject(forKey: NSNumber(value: key))
        }
    }

    func isPending(_ pageIndex: Int) -> Bool {
        pendingPages.contains(pageIndex)
    }

    // MARK: - Per-source decoders

    private func decodeZipDataPage(archiveData: Data, entryPath: String) -> CVPixelBuffer? {
        guard let archive = try? Archive(data: archiveData, accessMode: .read),
              let entry = archive[entryPath] else { return nil }
        return decodeArchiveEntry(archive: archive, entry: entry)
    }

    private func decodeZipFilePage(archiveURL: URL, entryPath: String) -> CVPixelBuffer? {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read),
              let entry = archive[entryPath] else { return nil }
        return decodeArchiveEntry(archive: archive, entry: entry)
    }

    private func decodeArchiveEntry(archive: Archive, entry: Entry) -> CVPixelBuffer? {
        var entryData = Data()
        do {
            try archive.extract(entry) { chunk in entryData.append(chunk) }
        } catch {
            return nil
        }
        return decodeImageData(entryData)
    }

    private func decodeFilePage(at url: URL) -> CVPixelBuffer? {
        // CBR/CB7/CBT pages are extracted to disk by `unar`/`tar` and end
        // up as `.file` sources. `Data(contentsOf:)` is cheap here — the
        // files are already on local disk in the app's cache directory.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeImageData(data)
    }

    private func decodePDFPage(doc: PDFDocument, pageIndex: Int) -> CVPixelBuffer? {
        guard let page = doc.page(at: pageIndex) else { return nil }
        let mediaBox = page.bounds(for: .mediaBox)
        // Render at 2× for Retina clarity. Matches the PDF scale used by the
        // single/double page path via `PageSource.decode()`.
        let scale: CGFloat = 2.0
        let width = max(1, Int(mediaBox.width * scale))
        let height = max(1, Int(mediaBox.height * scale))

        guard let buffer = makePixelBuffer(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // White background (PDFs are opaque pages; the transparent pixel
        // buffer would otherwise show the reader's black behind clear areas).
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return buffer
    }

    // MARK: - Shared helpers

    /// Decodes arbitrary image data (JPEG/PNG/WebP/etc.) through ImageIO and
    /// renders the result into a fresh CVPixelBuffer.
    private func decodeImageData(_ data: Data) -> CVPixelBuffer? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return renderCGImageToBuffer(cgImage)
    }

    private func renderCGImageToBuffer(_ cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        guard let buffer = makePixelBuffer(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func store(_ buffer: CVPixelBuffer, for pageIndex: Int) {
        if decodedPages.count >= maxCachedPages {
            if let lruKey = lastAccessTimes.min(by: { $0.value < $1.value })?.key {
                decodedPages.removeValue(forKey: lruKey)
                lastAccessTimes.removeValue(forKey: lruKey)
                nsImageCache.removeObject(forKey: NSNumber(value: lruKey))
            }
        }
        decodedPages[pageIndex] = buffer
        lastAccessTimes[pageIndex] = Date()

        // Populate the parallel NSImage cache so SwiftUI render paths have a
        // synchronous hit on the next render pass.
        if let image = makeNSImageFromPixelBuffer(buffer) {
            nsImageCache.setObject(image, forKey: NSNumber(value: pageIndex))
        }
    }
}

/// Converts a 32BGRA `CVPixelBuffer` into an `NSImage` by snapshotting the
/// pixel memory into a `CGImage`. Shared between `MetalPageManager` (which
/// populates its NSImage cache after decode) and `MetalPageView.Coordinator`
/// (which uses it for the vertical-mode loupe fallback).
///
/// Safe to call from any actor — it reads locked CVPixelBuffer bytes and
/// produces a value-type NSImage that outlives the source buffer.
func makeNSImageFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> NSImage? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0 else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    guard let ctx = CGContext(
        data: baseAddress,
        width: width, height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ),
          let cgImage = ctx.makeImage() else { return nil }

    return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
}
