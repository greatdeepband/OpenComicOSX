import XCTest
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
@testable import DC

final class CBZCompressorTests: XCTestCase {

    /// Synthesizes an in-memory JPEG of size (w, h), filled with a horizontal
    /// gradient so the encoder produces a non-trivial bitstream (a flat fill
    /// compresses to a degenerate few-byte stream and breaks size assertions).
    private func makeJPEGData(width: Int, height: Int, quality: CGFloat = 0.95) -> Data {
        makeJPEGData(width: width, height: height, colorSpace: CGColorSpaceCreateDeviceRGB(), quality: quality)
    }

    /// Synthesizes a JPEG tagged with the given color space, so we can assert
    /// the profile survives recompression (the metadata-preservation fix).
    private func makeJPEGData(width: Int, height: Int, colorSpace cs: CGColorSpace, quality: CGFloat = 0.95) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        for x in 0..<width {
            let f = CGFloat(x) / CGFloat(width)
            ctx.setFillColor(CGColor(red: f, green: 1 - f, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Reads the embedded ICC profile name from JPEG bytes (e.g. "Display P3",
    /// "sRGB IEC61966-2.1"). Returns nil if no profile is embedded.
    private func profileName(of jpeg: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        return props[kCGImagePropertyProfileName] as? String
    }

    func test_recompressJPEG_preservesWideGamutProfile() throws {
        // Both wide-gamut profiles the audit flagged: Display P3 and AdobeRGB.
        for (space, expectedName) in [
            (CGColorSpace(name: CGColorSpace.displayP3)!, "Display P3"),
            (CGColorSpace(name: CGColorSpace.adobeRGB1998)!, "Adobe RGB (1998)")
        ] {
            let input = makeJPEGData(width: 3000, height: 4000, colorSpace: space, quality: 0.95)
            XCTAssertEqual(profileName(of: input), expectedName, "Sanity: synthetic input must be \(expectedName)")

            let result = CBZCompressor.recompressJPEG(
                data: input,
                maxDim: 2000,
                jpegQuality: 0.85,
                grayQuality: 0.80,
                skipThreshold: 0.95
            )
            let output = try XCTUnwrap(result, "Expected a shrunk JPEG for \(expectedName)")
            XCTAssertEqual(
                profileName(of: output), expectedName,
                "\(expectedName) profile must survive recompression (no silent sRGB shift)"
            )
        }
    }

    func test_recompressJPEG_largeImage_shrinks() throws {
        let input = makeJPEGData(width: 3000, height: 4000, quality: 0.95)
        let result = CBZCompressor.recompressJPEG(
            data: input,
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )
        XCTAssertNotNil(result, "Expected a shrunk JPEG")
        XCTAssertLessThan(result!.count, input.count, "Output must be smaller than input")
    }

    func test_recompressJPEG_smallImage_returnsNil() throws {
        // A 200x200 image at q=0.85 is already small — won't shrink past
        // the 0.95 threshold, so the function returns nil (skip rewrite).
        let input = makeJPEGData(width: 200, height: 200, quality: 0.85)
        let result = CBZCompressor.recompressJPEG(
            data: input,
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )
        XCTAssertNil(result, "Already-small input should be skipped")
    }

    func test_recompressJPEG_invalidData_returnsNil() {
        let result = CBZCompressor.recompressJPEG(
            data: Data([0x00, 0x01, 0x02, 0x03]),
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )
        XCTAssertNil(result, "Garbage input must produce nil, not crash")
    }

    // MARK: - compressCBZ integration test

    /// Builds a CBZ at `url` containing two entries:
    ///   - `001.jpg` — large JPEG that should recompress
    ///   - `002.png` — opaque PNG that should pass through unchanged
    private func makeSyntheticCBZ(at url: URL) throws -> (jpegSize: Int, pngSize: Int) {
        let jpegData = makeJPEGData(width: 3000, height: 4000, quality: 0.95)
        let pngData: Data = {
            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(data: nil, width: 100, height: 100,
                                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            let image = ctx.makeImage()!
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            return out as Data
        }()
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "001.jpg", type: .file, uncompressedSize: Int64(jpegData.count),
                             compressionMethod: .deflate) { pos, size in
            jpegData.subdata(in: Int(pos)..<Int(pos) + size)
        }
        try archive.addEntry(with: "002.png", type: .file, uncompressedSize: Int64(pngData.count),
                             compressionMethod: .deflate) { pos, size in
            pngData.subdata(in: Int(pos)..<Int(pos) + size)
        }
        return (jpegData.count, pngData.count)
    }

    func test_compressCBZ_shrinksJPEG_passesThroughPNG() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = try makeSyntheticCBZ(at: tmp)
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        let originalSize = (attrs[.size] as? Int) ?? 0

        let result = try CBZCompressor.compressCBZ(
            at: tmp,
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )

        XCTAssertEqual(result.jpegsRewritten, 1)
        XCTAssertEqual(result.pngsPassed, 1)
        XCTAssertLessThan(result.outputBytes, result.inputBytes)
        XCTAssertEqual(result.inputBytes, originalSize)

        let after = try Archive(url: tmp, accessMode: .read)
        guard let pngEntry = after["002.png"] else { return XCTFail("PNG entry missing") }
        var roundtripped = Data()
        _ = try after.extract(pngEntry) { roundtripped.append($0) }
        XCTAssertEqual(roundtripped.count, original.pngSize, "PNG must pass through unchanged")

        // The result URL must point at a real, readable archive (the fix that
        // forwards replaceItemAt's resulting URL instead of discarding it).
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path),
                      "result.url must point at an existing file")
        let resultAttrs = try FileManager.default.attributesOfItem(atPath: result.url.path)
        XCTAssertEqual((resultAttrs[.size] as? Int), result.outputBytes,
                       "result.url must be the compressed output of outputBytes")
    }

    func test_compressCBZ_sweepsOrphanedTmpFromCrashedRun() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try makeSyntheticCBZ(at: tmp)

        // Simulate a tmp file left behind by a prior crashed run: same stem,
        // a different (dead) PID suffix. Current cleanup only removes the
        // live PID's tmp, so this orphan would otherwise linger forever.
        let orphan = tmp.deletingPathExtension().appendingPathExtension("cbz.tmp.999999")
        try Data("stale".utf8).write(to: orphan)
        defer { try? FileManager.default.removeItem(at: orphan) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "Sanity: orphan planted")

        _ = try CBZCompressor.compressCBZ(
            at: tmp, maxDim: 2000, jpegQuality: 0.85, grayQuality: 0.80, skipThreshold: 0.95
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                       "Orphaned .cbz.tmp.<oldpid> from a crashed run must be swept")
    }
}
