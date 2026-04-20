import Foundation
import CoreVideo
import ImageIO

/// Actor that manages async page decoding and the decoded CVPixelBuffer cache.
/// Pages are decoded from raw CBZ entry bytes via CGImageSource.
/// Only `maxCachedPages` (10) are kept in memory at once.
actor MetalPageManager {
    private var decodedPages: [Int: CVPixelBuffer] = [:]
    private var pendingPages: Set<Int> = []
    private var lastAccessTimes: [Int: Date] = [:]
    private let maxCachedPages = 10

    /// Decode a single page from raw CBZ data (Data containing the compressed image bytes).
    /// Returns a CVPixelBuffer suitable for Metal upload.
    func decodePage(pageIndex: Int, from archiveData: Data, entryIndex: Int) async -> CVPixelBuffer? {
        if decodedPages[pageIndex] != nil { return decodedPages[pageIndex] }
        if pendingPages.contains(pageIndex) { return nil }
        pendingPages.insert(pageIndex)
        defer { pendingPages.remove(pageIndex) }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false
        ]

        guard let imageSource = CGImageSourceCreateWithData(archiveData as CFData, options as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, entryIndex, options as CFDictionary) else {
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

    func page(for pageIndex: Int) -> CVPixelBuffer? {
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