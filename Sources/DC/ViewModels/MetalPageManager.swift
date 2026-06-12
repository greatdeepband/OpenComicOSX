import AppKit
import Foundation
import CoreVideo
import ImageIO
import PDFKit
import ZIPFoundation

/// Storage-only actor for the thumbnail dictionary, deliberately separate
/// from `MetalPageManager`'s decode actor so thumbnail work can run on
/// background CPU cores in parallel with the foreground full-res decoder
/// without contending at a single actor queue. Calls here are dict ops
/// only — the heavy decode work happens in `MetalPageManager`'s
/// nonisolated helpers BEFORE awaiting this actor to store the result.
private actor ThumbnailStore {
    private var thumbs: [Int: CGImage] = [:]

    func cached(_ pageIndex: Int) -> CGImage? { thumbs[pageIndex] }
    func store(_ image: CGImage, for pageIndex: Int) { thumbs[pageIndex] = image }
    func snapshot() -> [(pageIndex: Int, image: CGImage)] {
        thumbs.map { ($0.key, $0.value) }
    }
}

/// Actor that manages async page decoding and the decoded CVPixelBuffer cache
/// feeding the Metal vertical reader. Handles every `PageSource` variant
/// — `.zipData` (CBZ in-memory), `.file` (CBR/CB7/CBT extracted to disk, or
/// any standalone image), `.zip` (disk-backed archive), `.pdf` (PDF page).
/// Only `ReaderConstants.pageCacheCap` pages are kept in memory at once.
actor MetalPageManager {
    private var decodedPages: [Int: CVPixelBuffer] = [:]
    private var pendingPages: Set<Int> = []
    private var lastAccessTimes: [Int: Date] = [:]
    private let maxCachedPages = ReaderConstants.pageCacheCap

    /// Prefetch-window shape: how many pages behind and ahead of centre to
    /// decode. Matches the old `PageImageCache` window so the user-visible
    /// prefetch radius is unchanged.
    private let lookBehind = 1
    private let lookAhead  = 3

    /// Parallel NSImage cache derived from `decodedPages`. Populated lazily
    /// after each decode. Actor-state is the CVPixelBuffer dict; this is a
    /// nonisolated NSCache read from any context (SwiftUI render paths).
    /// Evicted in lockstep with the CVPixelBuffer when `store(...)` crosses
    /// the LRU cap or `evictOutside(_:)` runs.
    nonisolated let nsImageCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = ReaderConstants.pageCacheCap
        return cache
    }()

    /// Storage for per-page low-res thumbnails. Held on a separate actor
    /// (`ThumbnailStore`) so the thumbnail decode work — which is heavy
    /// CPU but doesn't touch any of this manager's full-res cache state —
    /// can run nonisolated and in parallel via `withTaskGroup`. Only the
    /// final dict insert serializes through this actor, and that's a
    /// microsecond op.
    fileprivate nonisolated let thumbnailStore = ThumbnailStore()

    /// Fires on the main actor after a thumbnail decode succeeds.
    /// Consumers (the reader's `Coordinator`) wire this to upload the
    /// `CGImage` into the renderer's `thumbnailRing` so the next render
    /// can use it as a placeholder.
    nonisolated(unsafe) var onThumbReady: ((Int, CGImage) -> Void)?

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
    /// or nil if nothing is decoded for that page yet.
    nonisolated func nsImage(for pageIndex: Int) -> NSImage? {
        nsImageCache.object(forKey: NSNumber(value: pageIndex))
    }

    // MARK: - Thumbnails

    /// Decode a low-resolution thumbnail for `pageIndex` and cache it.
    /// Returns the existing thumb if one is already decoded. Fires
    /// `onThumbReady` on the main actor after a successful new decode so
    /// consumers (the reader's Coordinator) can upload it into the
    /// renderer's `thumbnailRing` and use it as a render-path placeholder.
    ///
    /// `nonisolated`: the heavy decode work doesn't touch `MetalPageManager`
    /// state. Only the final store into `thumbnailStore` serializes
    /// through that small dedicated actor (microsecond op). This is what
    /// lets `preScanThumbnails`' `withTaskGroup` actually run multiple
    /// decodes in parallel.
    ///
    /// Decoding uses ImageIO's `CGImageSourceCreateThumbnailAtIndex` for
    /// raster sources (file / zip / zipData), which picks up embedded
    /// JPEG thumbnails when present and otherwise downscales without
    /// allocating a full-res buffer — typically 10–30 ms per page. PDF
    /// pages go through PDFKit's `PDFPage.thumbnail(of:for:)`.
    nonisolated func decodeThumb(pageIndex: Int, from source: PageSource) async -> CGImage? {
        if let cached = await thumbnailStore.cached(pageIndex) { return cached }

        let image: CGImage?
        switch source {
        case .file(let url):
            image = decodeThumbFromURL(url)
        case .zip(let archiveURL, let entryPath):
            image = decodeThumbFromZip(archiveURL: archiveURL, entryPath: entryPath)
        case .zipData(let data, let entryPath):
            image = decodeThumbFromZipData(archiveData: data, entryPath: entryPath)
        case .pdf(let doc, let pdfIndex):
            image = decodeThumbFromPDF(doc: doc, pageIndex: pdfIndex)
        }

        if let image {
            await thumbnailStore.store(image, for: pageIndex)
            if let cb = onThumbReady {
                await MainActor.run { cb(pageIndex, image) }
            }
        }
        return image
    }

    /// Snapshot of all currently-decoded thumbnails. Intended for renderer
    /// rebuild after a mode switch: the new `MetalPageRenderer` has an
    /// empty `thumbnailRing`, so the Coordinator iterates this snapshot
    /// and re-uploads each thumb instead of re-decoding from source.
    nonisolated func allThumbnails() async -> [(pageIndex: Int, image: CGImage)] {
        await thumbnailStore.snapshot()
    }

    /// Parallel pre-scan: spawns a child task per page in a `TaskGroup`,
    /// each decoding its thumbnail on whatever core the cooperative
    /// scheduler hands out. Total wall time is bounded by the
    /// `(ImageIO decode time × pageCount) / available cores` rather than
    /// the serial sum — typically ~1 s for a 200-page comic on M-series.
    ///
    /// Because thumb decode is `nonisolated`, this does NOT contend at
    /// `MetalPageManager`'s actor queue with the foreground per-visible-
    /// range prefetch — pre-scan progresses concurrently even during fast
    /// scroll, where the serial version stalled because foreground always
    /// held actor priority. Fire-and-forget from `ReaderViewModel` on
    /// comic open; cancellation propagates from the surrounding task.
    nonisolated func preScanThumbnails(pages: [ComicPage]) async {
        await withTaskGroup(of: Void.self) { group in
            for (idx, page) in pages.enumerated() {
                if Task.isCancelled { break }
                group.addTask { [self] in
                    if Task.isCancelled { return }
                    _ = await self.decodeThumb(pageIndex: idx, from: page.source)
                }
            }
        }
    }

    // MARK: - Thumbnail source decoders (nonisolated, pure functions over inputs)

    nonisolated private func decodeThumbFromURL(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return makeThumb(from: src)
    }

    nonisolated private func decodeThumbFromZip(archiveURL: URL, entryPath: String) -> CGImage? {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read),
              let entry = archive[entryPath],
              let data = extractEntry(archive: archive, entry: entry) else { return nil }
        return decodeThumbFromImageData(data)
    }

    nonisolated private func decodeThumbFromZipData(archiveData: Data, entryPath: String) -> CGImage? {
        guard let archive = try? Archive(data: archiveData, accessMode: .read),
              let entry = archive[entryPath],
              let data = extractEntry(archive: archive, entry: entry) else { return nil }
        return decodeThumbFromImageData(data)
    }

    nonisolated private func decodeThumbFromImageData(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return makeThumb(from: src)
    }

    nonisolated private func decodeThumbFromPDF(doc: PDFDocument, pageIndex: Int) -> CGImage? {
        guard let page = doc.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        // Preserve aspect: bound the longer edge to thumbMaxPixel.
        let maxEdge = CGFloat(ReaderConstants.thumbMaxPixel)
        let longer = max(bounds.width, bounds.height)
        let scale = longer > 0 ? maxEdge / longer : 1
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let nsImage = page.thumbnail(of: size, for: .mediaBox)
        var proposedRect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    nonisolated private func extractEntry(archive: Archive, entry: Entry) -> Data? {
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
        } catch {
            return nil
        }
        return data
    }

    nonisolated private func makeThumb(from src: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ReaderConstants.thumbMaxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
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

    /// Fire-and-forget prefetch for `[center - lookBehind … center + lookAhead]`.
    /// Safe to call from any context.
    ///
    /// Note: this is the legacy navigation-driven prefetch path. The reader's
    /// per-visible-range prefetch in `MetalPageView+Render.swift` already
    /// covers the active window with `prefetchLookahead` on each side; this
    /// path remains as a belt-and-suspenders trigger on explicit page
    /// navigation. Cache eviction is handled by `store(...)`'s LRU against
    /// `ReaderConstants.pageCacheCap` — this path no longer prunes via
    /// `evictOutside`, which under vertical-double fast scroll was wiping
    /// pages the new prefetch had just decoded.
    nonisolated func prefetch(around center: Int, pages: [ComicPage]) {
        Task { [weak self] in
            await self?._prefetchAround(center: center, pages: pages)
        }
    }

    private func _prefetchAround(center: Int, pages: [ComicPage]) async {
        let lo = max(0, center - lookBehind)
        let hi = min(pages.count - 1, center + lookAhead)
        guard lo <= hi else { return }
        let window = lo...hi

        for i in window {
            if decodedPages[i] != nil { continue }
            if pendingPages.contains(i) { continue }
            let source = pages[i].source
            guard let buffer = await decodePage(pageIndex: i, from: source) else { continue }
            _ = buffer  // buffer retained by decodedPages via store(); this ref keeps ARC honest
        }
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
        // single/double page path via `PageSource.decode()`. Clamp the result
        // to the Metal texture limit so an unusually large vector page can't
        // produce an oversized buffer/texture (which SIGABRTs in makeTexture).
        let baseScale: CGFloat = 2.0
        let rawW = Int((mediaBox.width * baseScale).rounded())
        let rawH = Int((mediaBox.height * baseScale).rounded())
        let capped = Self.cappedSize(width: rawW, height: rawH,
                                     maxDimension: Int(ReaderConstants.maxTextureDimension))
        let width = max(1, capped.width)
        let height = max(1, capped.height)
        // Effective scale after clamping — keeps the page drawn to fill the
        // (possibly reduced) buffer instead of being cropped.
        let scale = CGFloat(width) / max(mediaBox.width, 1)

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
        guard let src = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        // Cap the decode so neither axis exceeds the Metal texture limit. An
        // MTLTextureDescriptor larger than the device limit (16384) SIGABRTs in
        // makeTexture — reachable with very tall webtoon strips (e.g. 1080 ×
        // 20000+). When the source fits, decode at full resolution exactly as
        // before; only oversized pages take the downsampling thumbnail path
        // (which still carries the source color profile, like the compressor).
        let cap = Int(ReaderConstants.maxTextureDimension)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let srcW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let srcH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0

        let cgImage: CGImage?
        if srcW > cap || srcH > cap {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: cap,
                kCGImageSourceShouldCache: false
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary)
        }
        guard let cgImage else { return nil }
        return renderCGImageToBuffer(cgImage)
    }

    /// Scales a source pixel size down proportionally so neither axis exceeds
    /// `maxDimension`; returns it unchanged when it already fits. Pure helper,
    /// shared by the image and PDF decode paths and unit-tested directly.
    static func cappedSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        guard width > maxDimension || height > maxDimension, width > 0, height > 0 else {
            return (max(width, 0), max(height, 0))
        }
        let scale = Double(maxDimension) / Double(max(width, height))
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
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
