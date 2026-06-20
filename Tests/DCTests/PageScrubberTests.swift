import XCTest
@testable import DC

/// Tests for the pure mapping helpers in `PageScrubber.swift`.
/// These functions have no side-effects and no dependency on the view hierarchy
/// so they can be exercised directly as free functions.
final class PageScrubberTests: XCTestCase {

    // MARK: - pageForScrubberPosition — LTR

    func testLTR_leftEdge() {
        XCTAssertEqual(
            pageForScrubberPosition(x: 0, width: 100, pageCount: 10, isRTL: false),
            0
        )
    }

    func testLTR_rightEdge() {
        XCTAssertEqual(
            pageForScrubberPosition(x: 100, width: 100, pageCount: 10, isRTL: false),
            9
        )
    }

    func testLTR_midpoint() {
        // x=50 → f=0.5 → p = round(0.5 * 9) = round(4.5) = 5  (Swift rounds to even = 4... wait)
        // In Swift, 4.5.rounded() == 5.0 (rounds to even rounding: 4 is even, so 4.5 → 4)
        // Actually Swift uses .toNearestOrAwayFromZero by default in Int() conversion:
        // Int((4.5).rounded()) — .rounded() uses .toNearestOrEven → 4.5 rounds to 4 in IEEE 754
        // but (f * CGFloat(pageCount-1)).rounded() uses schoolbook half-up:
        // CGFloat(0.5 * 9.0) = 4.5; CGFloat.rounded() uses .toNearestOrAwayFromZero → 5
        // Let's just call the function and match the real implementation.
        let result = pageForScrubberPosition(x: 50, width: 100, pageCount: 10, isRTL: false)
        // 0.5 * 9 = 4.5 → rounded() (default .toNearestOrAwayFromZero) → 5
        XCTAssertEqual(result, 5)
    }

    func testLTR_clampNegativeX() {
        XCTAssertEqual(
            pageForScrubberPosition(x: -20, width: 100, pageCount: 10, isRTL: false),
            0
        )
    }

    func testLTR_clampOverWidth() {
        XCTAssertEqual(
            pageForScrubberPosition(x: 200, width: 100, pageCount: 10, isRTL: false),
            9
        )
    }

    // MARK: - pageForScrubberPosition — degenerate inputs

    func testPageCount1_returnsZero() {
        // Must not divide by zero
        XCTAssertEqual(
            pageForScrubberPosition(x: 50, width: 100, pageCount: 1, isRTL: false),
            0
        )
    }

    func testPageCount0_returnsZero() {
        XCTAssertEqual(
            pageForScrubberPosition(x: 50, width: 100, pageCount: 0, isRTL: false),
            0
        )
    }

    func testZeroWidth_returnsZero() {
        XCTAssertEqual(
            pageForScrubberPosition(x: 50, width: 0, pageCount: 10, isRTL: false),
            0
        )
    }

    // MARK: - pageForScrubberPosition — pageCount:2

    func testPageCount2_leftEdge() {
        XCTAssertEqual(
            pageForScrubberPosition(x: 0, width: 100, pageCount: 2, isRTL: false),
            0
        )
    }

    func testPageCount2_rightEdge() {
        XCTAssertEqual(
            pageForScrubberPosition(x: 100, width: 100, pageCount: 2, isRTL: false),
            1
        )
    }

    func testPageCount2_midpoint() {
        // f=0.5, p=round(0.5*1)=round(0.5)=1 (away from zero)
        XCTAssertEqual(
            pageForScrubberPosition(x: 50, width: 100, pageCount: 2, isRTL: false),
            1
        )
    }

    // MARK: - pageForScrubberPosition — RTL

    func testRTL_leftEdge_isLastPage() {
        // In RTL, x=0 (leading edge) → page 9 (last page)
        XCTAssertEqual(
            pageForScrubberPosition(x: 0, width: 100, pageCount: 10, isRTL: true),
            9
        )
    }

    func testRTL_rightEdge_isFirstPage() {
        // In RTL, x=100 (trailing edge) → page 0 (first page)
        XCTAssertEqual(
            pageForScrubberPosition(x: 100, width: 100, pageCount: 10, isRTL: true),
            0
        )
    }

    // MARK: - scrubberFraction — LTR

    func testFractionLTR_firstPage() {
        XCTAssertEqual(
            scrubberFraction(forPage: 0, pageCount: 10, isRTL: false),
            0.0, accuracy: 0.001
        )
    }

    func testFractionLTR_lastPage() {
        XCTAssertEqual(
            scrubberFraction(forPage: 9, pageCount: 10, isRTL: false),
            1.0, accuracy: 0.001
        )
    }

    func testFractionLTR_midPage() {
        // page 4 of 9 (0-indexed last = 9) → 4/9 ≈ 0.444
        XCTAssertEqual(
            scrubberFraction(forPage: 4, pageCount: 10, isRTL: false),
            4.0 / 9.0, accuracy: 0.001
        )
    }

    // MARK: - scrubberFraction — RTL

    func testFractionRTL_firstPage_isTrailingEdge() {
        // page 0 in RTL → fraction 1.0 (trailing / right edge)
        XCTAssertEqual(
            scrubberFraction(forPage: 0, pageCount: 10, isRTL: true),
            1.0, accuracy: 0.001
        )
    }

    func testFractionRTL_lastPage_isLeadingEdge() {
        // page 9 in RTL → fraction 0.0 (leading / left edge)
        XCTAssertEqual(
            scrubberFraction(forPage: 9, pageCount: 10, isRTL: true),
            0.0, accuracy: 0.001
        )
    }

    // MARK: - scrubberFraction — degenerate

    func testFractionPageCount1_returnsZero() {
        XCTAssertEqual(
            scrubberFraction(forPage: 0, pageCount: 1, isRTL: false),
            0.0, accuracy: 0.001
        )
    }

    func testFractionClampsNegativePage() {
        XCTAssertEqual(
            scrubberFraction(forPage: -5, pageCount: 10, isRTL: false),
            0.0, accuracy: 0.001
        )
    }

    func testFractionClampsPageBeyondCount() {
        XCTAssertEqual(
            scrubberFraction(forPage: 100, pageCount: 10, isRTL: false),
            1.0, accuracy: 0.001
        )
    }

    // MARK: - Round-trip: fraction → position → page

    func testRoundTripLTR() {
        let pageCount = 20
        for page in 0..<pageCount {
            let frac = scrubberFraction(forPage: page, pageCount: pageCount, isRTL: false)
            let x = frac * 200
            let recovered = pageForScrubberPosition(x: x, width: 200, pageCount: pageCount, isRTL: false)
            XCTAssertEqual(recovered, page, "LTR round-trip failed for page \(page)")
        }
    }

    func testRoundTripRTL() {
        let pageCount = 20
        for page in 0..<pageCount {
            let frac = scrubberFraction(forPage: page, pageCount: pageCount, isRTL: true)
            let x = frac * 200
            let recovered = pageForScrubberPosition(x: x, width: 200, pageCount: pageCount, isRTL: true)
            XCTAssertEqual(recovered, page, "RTL round-trip failed for page \(page)")
        }
    }
}
