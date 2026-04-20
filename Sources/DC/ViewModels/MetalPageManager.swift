import Foundation
import CoreVideo
import ImageIO
import ZIPFoundation

/// Actor that manages async page decoding and the decoded CVPixelBuffer cache.
/// Pages are decoded from raw CBZ entry bytes via CGImageSource.
/// Only `maxCachedPages` (10) are kept in memory at once.
actor MetalPageManager {
    private var decodedPages: [Int: CVPixelBuffer] = [:]
    private var pendingPages: Set<Int> = []
    private var lastAccessTimes: [Int: Date] = [:]
    private let maxCachedPages = 10

    /// Decode a single page from a PageSource.
    /// For .zipData sources: extracts the specific entry from the CBZ archive,
    /// decompresses it, and decodes to a CVPixelBuffer suitable for Metal upload.
    /// For other sources: falls back to the source's own decode() method.
    func decodePage(pageIndex: Int, from source: PageSource) async -> CVPixelBuffer? {
        if decodedPages[pageIndex] != nil { return decodedPages[pageIndex] }
        if pendingPages.contains(pageIndex) { return nil }
        pendingPages.insert(pageIndex)
        defer { pendingPages.remove(pageIndex) }

        // Handle .zipData source: extract entry from archive and decode
        if case .zipData(let archiveData, let entryPath) = source {
            return decodeZipDataPage(pageIndex: pageIndex, archiveData: archiveData, entryPath: entryPath)
        }

        // For other source types, we can't decode to CVPixelBuffer directly
        // without going through NSImage/CGImage. Return nil and let the
        // existing pipeline handle these pages.
        return nil
    }

    /// Extract a specific entry from a CBZ archive and decode it to CVPixelBuffer.
    private func decodeZipDataPage(pageIndex: Int, archiveData: Data, entryPath: String) -> CVPixelBuffer? {
        guard let archive = try? Archive(data: archiveData, accessMode: .read) else {
            return nil
        }
        guard let entry = archive[entryPath] else {
            return nil
        }

        // Extract the decompressed data for this entry using the consumer pattern
        var entryData = Data()
        do {
            try archive.extract(entry) { chunk in
                entryData.append(chunk)
            }
        } catch {
            return nil
        }

        // Decode the image data to CGImage
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false
        ]

        guard let imageSource = CGImageSourceCreateWithData(entryData as CFData, options as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

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

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Ring buffer eviction - remove LRU page
        if decodedPages.count >= maxCachedPages {
            if let lruKey = lastAccessTimes.min(by: { $0.value < $1.value })?.key {
                decodedPages.removeValue(forKey: lruKey)
                lastAccessTimes.removeValue(forKey: lruKey)
            }
        }
        decodedPages[pageIndex] = buffer
        lastAccessTimes[pageIndex] = Date()
        return buffer
    }

    /// Legacy decode method for backward compatibility with existing callers
    /// that pass archiveData + entryIndex. Uses the entryPath from PageSource instead.
    func decodePage(pageIndex: Int, from archiveData: Data, entryPath: String) async -> CVPixelBuffer? {
        return await decodePage(pageIndex: pageIndex, from: .zipData(archiveData, entryPath))
    }

    func page(for pageIndex: Int) -> CVPixelBuffer? {
        lastAccessTimes[pageIndex] = Date()
        return decodedPages[pageIndex]
    }

    func evictOutside(_ range: ClosedRange<Int>) {
        decodedPages = decodedPages.filter { range.contains($0.key) }
        lastAccessTimes = lastAccessTimes.filter { range.contains($0.key) }
    }

    func isPending(_ pageIndex: Int) -> Bool {
        pendingPages.contains(pageIndex)
    }
}