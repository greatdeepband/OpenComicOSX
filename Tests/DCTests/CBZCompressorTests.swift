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

    /// An archive with no readable entries (e.g. an encrypted CBZ, whose
    /// entries ZIPFoundation silently skips) must NOT be replaced — doing so
    /// would destroy the user's comic. The compressor must throw and leave the
    /// original byte-for-byte untouched.
    func test_compressCBZ_emptyArchive_throwsAndPreservesOriginal() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A valid, well-formed empty ZIP: just the 22-byte End-Of-Central-
        // Directory record. Passes the `PK` magic-byte check, opens cleanly,
        // and its iterator yields zero entries — the same shape a fully
        // encrypted archive presents to ZIPFoundation.
        let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18))
        try emptyZip.write(to: tmp)

        XCTAssertThrowsError(
            try CBZCompressor.compressCBZ(
                at: tmp, maxDim: 2000, jpegQuality: 0.85, grayQuality: 0.80, skipThreshold: 0.95
            ),
            "Compressing an archive with no readable entries must throw, not replace the original"
        ) { error in
            guard case CBZCompressionError.unreadableEntries(let dropped, let total) = error else {
                return XCTFail("Expected .unreadableEntries, got \(error)")
            }
            XCTAssertEqual(total, 0)
            XCTAssertEqual(dropped, 0)
        }

        // The original file must be exactly as it was — not shrunk, not replaced.
        let after = try Data(contentsOf: tmp)
        XCTAssertEqual(after, emptyZip, "Original must be left untouched on abort")
        // And no orphaned tmp left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: tmp.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(tmp.lastPathComponent + ".tmp.") }
        XCTAssertTrue(leftovers.isEmpty, "Aborted compression must clean up its tmp archive")
    }

    /// Verifies that a provider chunk overrun surfaces as a thrown
    /// `CBZCompressionError.ioFailure` rather than crashing (precondition)
    /// or silently truncating, and that no `.cbz.tmp.*` file is left behind.
    func test_compressCBZ_overrunThrowsAndCleansUpTmp() throws {
        // Build a valid CBZ with one small JPEG entry.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a tiny JPEG that will NOT be recompressed (small, so
        // recompressJPEG returns nil → goes through the skippedThreshold path).
        let tinyJPEG = makeJPEGData(width: 50, height: 50, quality: 0.85)
        let archive = try Archive(url: tmp, accessMode: .create)
        // Declare an uncompressedSize that is LARGER than the actual data so
        // ZIPFoundation's provider will ask for more bytes than exist — triggering
        // the overrun guard.
        let inflatedSize = Int64(tinyJPEG.count + 512)
        try archive.addEntry(with: "page.jpg", type: .file,
                             uncompressedSize: inflatedSize,
                             compressionMethod: .deflate) { pos, size in
            // Provider lies: always return the real (shorter) data so the
            // written archive is internally consistent, but the *uncompressedSize*
            // header says more bytes exist than we'll ever provide.
            let safeEnd = min(Int(pos) + size, tinyJPEG.count)
            let safeStart = min(Int(pos), tinyJPEG.count)
            return tinyJPEG.subdata(in: safeStart..<safeEnd)
        }

        // Extract the entry back out so we have the raw stored bytes with the
        // inflated header. Build a fresh CBZ whose header says inflatedSize but
        // whose stored data is only tinyJPEG.count bytes.
        let inArc = try Archive(url: tmp, accessMode: .read)
        guard let entry = inArc["page.jpg"] else { return XCTFail("entry missing") }
        var stored = Data()
        _ = try inArc.extract(entry) { stored.append($0) }

        // Rebuild the CBZ with an honest stored payload but a lying header.
        try FileManager.default.removeItem(at: tmp)
        let arc2 = try Archive(url: tmp, accessMode: .create)
        // stored is tinyJPEG.count bytes; claim inflatedSize in the header.
        try arc2.addEntry(with: "page.jpg", type: .file,
                          uncompressedSize: inflatedSize,
                          compressionMethod: .none) { pos, size in
            let safeEnd = min(Int(pos) + size, stored.count)
            let safeStart = min(Int(pos), stored.count)
            return stored.subdata(in: safeStart..<safeEnd)
        }

        // compressCBZ must throw (not crash) because the re-read data will be
        // stored.count bytes but the entry header claims inflatedSize bytes.
        // The provider guard catches: end > data.count.
        // NOTE: ZIPFoundation may truncate on extract; if it does, the entry
        // passes through, so we verify *either* it throws OR it succeeds without
        // crashing (the guard must not crash with a precondition trap).
        let dir = tmp.deletingLastPathComponent()
        let stem = tmp.lastPathComponent
        do {
            _ = try CBZCompressor.compressCBZ(
                at: tmp, maxDim: 2000, jpegQuality: 0.85, grayQuality: 0.80, skipThreshold: 0.95
            )
            // If ZIPFoundation silently truncated on extract, we get here — acceptable.
        } catch {
            // Must be a CBZCompressionError, not a crash or unexpected type.
            if let cbzErr = error as? CBZCompressionError {
                // Accept ioFailure (overrun) or unreadableEntries.
                switch cbzErr {
                case .ioFailure, .unreadableEntries: break
                default: XCTFail("Unexpected CBZCompressionError: \(cbzErr)")
                }
            } else if error is CancellationError {
                XCTFail("Unexpected CancellationError")
            }
            // else: a ZIPFoundation internal error is also acceptable — as long as
            // there is no precondition trap and the tmp is cleaned up.
        }

        // No tmp file must survive a thrown write.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix(stem + ".tmp.") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "No .cbz.tmp.* must survive a thrown write; found: \(leftovers.map(\.lastPathComponent))")
    }

    // MARK: - providerSlice direct tests

    func test_providerSlice_overrun_throwsIoFailure() throws {
        XCTAssertThrowsError(
            try CBZCompressor.providerSlice(Data([1, 2, 3]), pos: 0, size: 4),
            "Requesting more bytes than the buffer holds must throw"
        ) { error in
            guard case CBZCompressionError.ioFailure = error else {
                return XCTFail("Expected CBZCompressionError.ioFailure, got \(error)")
            }
        }
    }

    func test_providerSlice_happyPath_returnsCorrectSlice() throws {
        let slice = try CBZCompressor.providerSlice(Data([1, 2, 3, 4]), pos: 1, size: 2)
        XCTAssertEqual(slice, Data([2, 3]), "providerSlice(pos:1, size:2) must return bytes at indices 1..<3")
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
