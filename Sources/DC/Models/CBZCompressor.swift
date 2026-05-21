import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure-logic CBZ compressor — no UI, no `@MainActor`. Mirrors CompyUI's
/// `container.py` + `image_engine.py` algorithm (ported 2026-05-19):
///
///   1. JPEG entries → decode via ImageIO, resize to fit `maxDim`,
///      re-encode at `jpegQuality` / `grayQuality`. Skip if the new bytes
///      aren't at least `(1 - skipThreshold)` smaller than the source.
///   2. PNG and other entries → passed through unchanged
///      (CompyUI's "format-preservation contract" — never replace a PNG
///      with JPEG bytes).
///
/// Heavy I/O. Callers should invoke from a background `Task`.
enum CBZCompressor {

    // MARK: - Public: single-image recompression

    /// Decode `data` as an image, resize it to fit `maxDim` on the longer
    /// edge, re-encode as JPEG. Returns the new bytes IFF they're at
    /// least `(1 - skipThreshold)` smaller than `data`; otherwise `nil`
    /// (caller leaves the original entry untouched).
    ///
    /// Returns `nil` for:
    /// - Undecodable input
    /// - 1-bit / bitonal images (mode == .grayscale && bpc == 1)
    /// - Outputs that wouldn't shrink past the threshold
    static func recompressJPEG(
        data: Data,
        maxDim: Int,
        jpegQuality: CGFloat,
        grayQuality: CGFloat,
        skipThreshold: Double
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        // Bitonal protection: 1-bit-per-component grayscale stays in
        // its original encoding (re-encode as lossy JPEG would balloon).
        let bpc = (props[kCGImagePropertyDepth] as? Int) ?? 8
        let model = (props[kCGImagePropertyColorModel] as? String) ?? ""
        let isGray = (model == (kCGImagePropertyColorModelGray as String))
        if isGray && bpc == 1 { return nil }

        // Decode-with-resize via ImageIO thumbnail API — efficient
        // (skips full-res decode when source is much larger than maxDim).
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else { return nil }

        let quality = isGray ? grayQuality : jpegQuality
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let destProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let newBytes = outData as Data
        if Double(newBytes.count) >= Double(data.count) * skipThreshold {
            return nil
        }
        return newBytes
    }
}
