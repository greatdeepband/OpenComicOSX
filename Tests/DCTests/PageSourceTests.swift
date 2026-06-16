import XCTest
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
@testable import DC

final class PageSourceTests: XCTestCase {

    private func makeJPEGData(width: Int, height: Int) -> Data {
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
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func makeCBZData(entry name: String, image: Data) throws -> Data {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(image.count),
                             compressionMethod: .deflate) { pos, size in
            image.subdata(in: Int(pos)..<Int(pos) + size)
        }
        return try Data(contentsOf: url)
    }

    /// naturalSize reads only the image header from the ZIP entry, aborting the
    /// extraction early once enough bytes are buffered. This test guards that
    /// early-abort path (the sentinel error that stops the read) still yields
    /// the correct dimensions — not the 1×1 failure placeholder.
    func test_zipDataNaturalSize_readsDimensionsFromHeader() throws {
        let jpeg = makeJPEGData(width: 1200, height: 1600)
        let cbz = try makeCBZData(entry: "001.jpg", image: jpeg)

        let size = PageSource.zipData(cbz, "001.jpg").naturalSize

        XCTAssertEqual(size.width, 1200, "width must come from the JPEG header, not the 1×1 placeholder")
        XCTAssertEqual(size.height, 1600, "height must come from the JPEG header, not the 1×1 placeholder")
    }

    func test_zipDataNaturalSize_missingEntry_returnsPlaceholder() throws {
        let jpeg = makeJPEGData(width: 1200, height: 1600)
        let cbz = try makeCBZData(entry: "001.jpg", image: jpeg)

        let size = PageSource.zipData(cbz, "does-not-exist.jpg").naturalSize

        XCTAssertEqual(size, CGSize(width: 1, height: 1), "missing entry falls back to 1×1")
    }

    func test_zipDataDecode_missingEntry_returnsNil() throws {
        let jpeg = makeJPEGData(width: 1200, height: 1600)
        let cbz = try makeCBZData(entry: "001.jpg", image: jpeg)

        let image = PageSource.zipData(cbz, "does-not-exist.jpg").decode()

        XCTAssertNil(image, "decode of a missing entry must return nil")
    }

    func test_zipDataDecode_presentEntry_decodes() throws {
        let jpeg = makeJPEGData(width: 1200, height: 1600)
        let cbz = try makeCBZData(entry: "001.jpg", image: jpeg)

        let image = PageSource.zipData(cbz, "001.jpg").decode()

        XCTAssertNotNil(image, "decode of a present entry must succeed")
    }
}
