import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

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

    /// Decode PNG `data`, composite onto white if it has alpha, resize to
    /// fit `maxDim`, and re-encode as JPEG. Used when the user opts in to
    /// PNG → JPEG conversion (off by default — CompyUI's "format-preservation
    /// contract" passes PNGs through unchanged, but for PNG-heavy CBZs that
    /// means ~0 % compression). Returns `nil` if the JPEG output wouldn't
    /// shrink past `skipThreshold` (rare for PNG → JPEG, which is typically
    /// 5–20× smaller; the threshold mostly guards weird inputs).
    ///
    /// Alpha is composited onto white before JPEG encoding because JPEG
    /// doesn't support transparency and ImageIO's default behavior produces
    /// black backgrounds where the alpha was. Comic pages rarely have
    /// meaningful transparency at the page-image level — they're scans of
    /// printed pages — so flattening on white is the safe choice.
    static func recompressPNGAsJPEG(
        data: Data,
        maxDim: Int,
        jpegQuality: CGFloat,
        grayQuality: CGFloat,
        skipThreshold: Double
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else { return nil }

        let csModel = cgImage.colorSpace?.model
        let isGray = (csModel == .monochrome)

        let alpha = cgImage.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst)

        let opaqueImage: CGImage
        if hasAlpha {
            let width = cgImage.width
            let height = cgImage.height
            let colorSpace: CGColorSpace = isGray
                ? CGColorSpaceCreateDeviceGray()
                : CGColorSpaceCreateDeviceRGB()
            let bitmapInfo: UInt32 = isGray
                ? CGImageAlphaInfo.none.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue
            guard let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return nil }
            ctx.setFillColor(
                isGray
                    ? CGColor(gray: 1, alpha: 1)
                    : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            )
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let composited = ctx.makeImage() else { return nil }
            opaqueImage = composited
        } else {
            opaqueImage = cgImage
        }

        let quality = isGray ? grayQuality : jpegQuality
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, opaqueImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let newBytes = outData as Data
        if Double(newBytes.count) >= Double(data.count) * skipThreshold {
            return nil
        }
        return newBytes
    }
}

// MARK: - Public: full-file CBZ compression

struct CBZCompressionResult {
    let url: URL
    let inputBytes: Int
    let outputBytes: Int
    let jpegsSeen: Int
    let jpegsRewritten: Int
    let jpegsSkippedBitonal: Int
    let jpegsSkippedThreshold: Int
    let jpegsFailed: Int
    let pngsPassed: Int       // PNG entries passed through unchanged
    let pngsConverted: Int    // PNG entries converted to JPEG (when convertPNGs=true)
    let othersPassed: Int
}

enum CBZCompressionError: Error {
    case notACBZ
    case invalidArchive
    case ioFailure(String)
}

extension CBZCompressor {

    /// Recompresses every JPEG entry inside the CBZ at `url`, writes a new
    /// CBZ to a sibling `.tmp` file, then atomic-renames it back over the
    /// original (so a crash mid-compression never destroys the source).
    ///
    /// PNG and other entries pass through unchanged (format-preservation
    /// contract). Throws `CBZCompressionError.notACBZ` for non-CBZ inputs.
    /// Reports per-image progress via `progress("entry", current, total)`.
    /// Honors `Task.isCancelled` between entries.
    static func compressCBZ(
        at url: URL,
        maxDim: Int,
        jpegQuality: CGFloat,
        grayQuality: CGFloat,
        skipThreshold: Double,
        convertPNGs: Bool = false,
        progress: ((String, Int, Int) -> Void)? = nil
    ) throws -> CBZCompressionResult {
        guard url.pathExtension.lowercased() == "cbz" else {
            throw CBZCompressionError.notACBZ
        }
        let fh = try FileHandle(forReadingFrom: url)
        let header = fh.readData(ofLength: 2)
        try fh.close()
        guard header == Data([0x50, 0x4B]) else {
            throw CBZCompressionError.notACBZ
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let inputBytes = (attrs[.size] as? Int) ?? 0
        let inArchive: Archive
        do {
            inArchive = try Archive(url: url, accessMode: .read)
        } catch {
            throw CBZCompressionError.invalidArchive
        }

        let tmpURL = url.deletingPathExtension()
            .appendingPathExtension("cbz.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: tmpURL)
        let outArchive: Archive
        do {
            outArchive = try Archive(url: tmpURL, accessMode: .create)
        } catch {
            throw CBZCompressionError.ioFailure("create tmp archive: \(error)")
        }

        var seenJPEG = 0, rewrote = 0, skippedBitonal = 0, skippedThreshold = 0, failedJPEG = 0
        var passedPNG = 0, convertedPNG = 0, passedOther = 0

        let entries = Array(inArchive.makeIterator())
        let total = entries.count
        for (idx, entry) in entries.enumerated() {
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tmpURL)
                throw CancellationError()
            }
            progress?("entry", idx + 1, total)
            let name = entry.path.lowercased()
            var data = Data()
            do {
                _ = try inArchive.extract(entry) { data.append($0) }
            } catch {
                continue
            }
            let isJPEG = name.hasSuffix(".jpg") || name.hasSuffix(".jpeg")
            let isPNG  = name.hasSuffix(".png")
            if isJPEG {
                seenJPEG += 1
                if let newBytes = recompressJPEG(
                    data: data,
                    maxDim: maxDim,
                    jpegQuality: jpegQuality,
                    grayQuality: grayQuality,
                    skipThreshold: skipThreshold
                ) {
                    do {
                        try outArchive.addEntry(
                            with: entry.path, type: .file,
                            uncompressedSize: Int64(newBytes.count),
                            compressionMethod: .deflate
                        ) { pos, size in
                            newBytes.subdata(in: Int(pos)..<Int(pos) + size)
                        }
                        rewrote += 1
                    } catch {
                        failedJPEG += 1
                        try outArchive.addEntry(
                            with: entry.path, type: .file,
                            uncompressedSize: Int64(data.count),
                            compressionMethod: .deflate
                        ) { pos, size in
                            data.subdata(in: Int(pos)..<Int(pos) + size)
                        }
                    }
                } else {
                    skippedThreshold += 1
                    try outArchive.addEntry(
                        with: entry.path, type: .file,
                        uncompressedSize: Int64(data.count),
                        compressionMethod: .deflate
                    ) { pos, size in
                        data.subdata(in: Int(pos)..<Int(pos) + size)
                    }
                }
            } else if isPNG {
                if convertPNGs,
                   let newBytes = recompressPNGAsJPEG(
                    data: data,
                    maxDim: maxDim,
                    jpegQuality: jpegQuality,
                    grayQuality: grayQuality,
                    skipThreshold: skipThreshold
                   ) {
                    // Rename `foo.png` → `foo.jpg` inside the archive so
                    // the file extension matches the new bytes. Readers
                    // (including OpenComic) dispatch on extension.
                    let originalPath = entry.path
                    let renamedPath: String = {
                        let lower = originalPath.lowercased()
                        if lower.hasSuffix(".png") {
                            return String(originalPath.dropLast(4)) + ".jpg"
                        }
                        return originalPath
                    }()
                    try outArchive.addEntry(
                        with: renamedPath, type: .file,
                        uncompressedSize: Int64(newBytes.count),
                        compressionMethod: .deflate
                    ) { pos, size in
                        newBytes.subdata(in: Int(pos)..<Int(pos) + size)
                    }
                    convertedPNG += 1
                    continue
                }
                passedPNG += 1
                try outArchive.addEntry(
                    with: entry.path, type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate
                ) { pos, size in
                    data.subdata(in: Int(pos)..<Int(pos) + size)
                }
            } else {
                passedOther += 1
                try outArchive.addEntry(
                    with: entry.path, type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate
                ) { pos, size in
                    data.subdata(in: Int(pos)..<Int(pos) + size)
                }
            }
        }

        let tmpAttrs = try? FileManager.default.attributesOfItem(atPath: tmpURL.path)
        let outputBytes = (tmpAttrs?[.size] as? Int) ?? 0
        if outputBytes >= inputBytes {
            try? FileManager.default.removeItem(at: tmpURL)
            return CBZCompressionResult(
                url: url, inputBytes: inputBytes, outputBytes: inputBytes,
                jpegsSeen: seenJPEG, jpegsRewritten: 0,
                jpegsSkippedBitonal: skippedBitonal,
                jpegsSkippedThreshold: skippedThreshold + rewrote,
                jpegsFailed: failedJPEG,
                pngsPassed: passedPNG, pngsConverted: convertedPNG, othersPassed: passedOther
            )
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)

        return CBZCompressionResult(
            url: url, inputBytes: inputBytes, outputBytes: outputBytes,
            jpegsSeen: seenJPEG, jpegsRewritten: rewrote,
            jpegsSkippedBitonal: skippedBitonal,
            jpegsSkippedThreshold: skippedThreshold,
            jpegsFailed: failedJPEG,
            pngsPassed: passedPNG, pngsConverted: convertedPNG, othersPassed: passedOther
        )
    }
}
