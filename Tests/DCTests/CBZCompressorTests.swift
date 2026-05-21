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
        let cs = CGColorSpaceCreateDeviceRGB()
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
    }
}
