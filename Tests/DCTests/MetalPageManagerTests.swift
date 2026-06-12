import XCTest
@testable import DC

final class MetalPageManagerTests: XCTestCase {

    private let cap = 16384  // mirrors ReaderConstants.maxTextureDimension

    func test_cappedSize_withinLimit_isUnchanged() {
        let r = MetalPageManager.cappedSize(width: 4000, height: 6000, maxDimension: cap)
        XCTAssertEqual(r.width, 4000)
        XCTAssertEqual(r.height, 6000)
    }

    func test_cappedSize_atLimit_isUnchanged() {
        let r = MetalPageManager.cappedSize(width: cap, height: 1000, maxDimension: cap)
        XCTAssertEqual(r.width, cap)
        XCTAssertEqual(r.height, 1000)
    }

    /// The webtoon-strip case that would otherwise SIGABRT in makeTexture:
    /// a tall thin page taller than the Metal limit must be scaled so the
    /// long edge lands exactly at the cap, preserving aspect ratio.
    func test_cappedSize_tallStrip_scalesLongEdgeToCap() {
        let r = MetalPageManager.cappedSize(width: 1080, height: 21600, maxDimension: cap)
        XCTAssertEqual(r.height, cap, "Long edge must be clamped to the cap")
        XCTAssertLessThanOrEqual(r.width, cap)
        // Aspect ratio preserved: 1080/21600 = 0.05 → width ≈ 0.05 * 16384 = 819.
        XCTAssertEqual(Double(r.width) / Double(r.height), 1080.0 / 21600.0, accuracy: 0.01)
    }

    func test_cappedSize_wideStrip_scalesLongEdgeToCap() {
        let r = MetalPageManager.cappedSize(width: 30000, height: 2000, maxDimension: cap)
        XCTAssertEqual(r.width, cap)
        XCTAssertLessThanOrEqual(r.height, cap)
        XCTAssertEqual(Double(r.height) / Double(r.width), 2000.0 / 30000.0, accuracy: 0.01)
    }

    func test_cappedSize_bothAxesOverLimit_clampsToFit() {
        let r = MetalPageManager.cappedSize(width: 20000, height: 18000, maxDimension: cap)
        XCTAssertLessThanOrEqual(r.width, cap)
        XCTAssertLessThanOrEqual(r.height, cap)
        XCTAssertEqual(max(r.width, r.height), cap, "The longer axis lands at the cap")
    }

    func test_cappedSize_degenerateInput_doesNotCrash() {
        XCTAssertEqual(MetalPageManager.cappedSize(width: 0, height: 0, maxDimension: cap).width, 0)
        let neg = MetalPageManager.cappedSize(width: -5, height: 10, maxDimension: cap)
        XCTAssertGreaterThanOrEqual(neg.width, 0)
    }
}
