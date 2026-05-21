import XCTest
import ImageIO
import UniformTypeIdentifiers
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
}
