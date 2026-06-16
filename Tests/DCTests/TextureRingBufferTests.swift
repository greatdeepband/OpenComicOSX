import XCTest
import Metal
@testable import DC

/// Tests for the LRU eviction semantics of `TextureRingBuffer`.
///
/// Needs a real MTLDevice because MTLTexture is opaque — we can't synthesize
/// fakes. macOS-14 CI runners support Metal; if a device isn't available
/// (headless test environment), each test skips gracefully via XCTSkipIf.
final class TextureRingBufferTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this host")
        }
        device = dev
    }

    /// Create a minimal 1x1 BGRA texture for ring-buffer testing.
    private func makeTexture() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("MTLDevice could not make a 1×1 texture — bail rather than fail")
        }
        return tex
    }

    func testInsertAndLookup() throws {
        var ring = TextureRingBuffer(maxSize: 3)
        let t0 = try makeTexture()
        ring.insert(t0, for: 7)
        XCTAssertNotNil(ring[7])
        XCTAssertNil(ring[8])
    }

    func testInsertOverwritesOnSameKey() throws {
        var ring = TextureRingBuffer(maxSize: 3)
        let t0 = try makeTexture()
        let t1 = try makeTexture()
        ring.insert(t0, for: 5)
        ring.insert(t1, for: 5)
        XCTAssertEqual(ring.touch(pageIndex: 5)?.label, t1.label,
                       "Re-insert on same key should overwrite the texture")
        XCTAssertNotNil(ring[5])
    }

    func testEvictsLeastRecentlyUsedAtCap() throws {
        var ring = TextureRingBuffer(maxSize: 3)
        let t0 = try makeTexture()
        let t1 = try makeTexture()
        let t2 = try makeTexture()
        ring.insert(t0, for: 0)
        // Spread inserts in time so LRU has unambiguous ordering.
        Thread.sleep(forTimeInterval: 0.002)
        ring.insert(t1, for: 1)
        Thread.sleep(forTimeInterval: 0.002)
        ring.insert(t2, for: 2)
        XCTAssertNotNil(ring[0])
        XCTAssertNotNil(ring[1])
        XCTAssertNotNil(ring[2])

        // Touching 0 makes it the most recently used; the next insert should
        // evict 1 (now LRU), not 0.
        Thread.sleep(forTimeInterval: 0.002)
        _ = ring.touch(pageIndex: 0)
        Thread.sleep(forTimeInterval: 0.002)
        let t3 = try makeTexture()
        ring.insert(t3, for: 3)

        XCTAssertNotNil(ring[0], "0 was just touched — should survive")
        XCTAssertNil(ring[1], "1 was LRU — should have been evicted")
        XCTAssertNotNil(ring[2])
        XCTAssertNotNil(ring[3])
    }

    func testTouchReturnsTextureAndUpdatesAccess() throws {
        var ring = TextureRingBuffer(maxSize: 2)
        let t0 = try makeTexture()
        let t1 = try makeTexture()
        ring.insert(t0, for: 0)
        Thread.sleep(forTimeInterval: 0.002)
        ring.insert(t1, for: 1)

        Thread.sleep(forTimeInterval: 0.002)
        _ = ring.touch(pageIndex: 0)  // 0 is now MRU

        Thread.sleep(forTimeInterval: 0.002)
        let t2 = try makeTexture()
        ring.insert(t2, for: 2)  // should evict 1

        XCTAssertNotNil(ring[0])
        XCTAssertNil(ring[1])
        XCTAssertNotNil(ring[2])
    }

    func testTouchOnMissReturnsNil() {
        var ring = TextureRingBuffer(maxSize: 2)
        XCTAssertNil(ring.touch(pageIndex: 99))
    }
}
