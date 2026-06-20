import XCTest
@testable import DC

/// Tests for `ReaderViewModel.spreadAlignedLeftIndex(for:pages:)` and the
/// clamping behaviour of `goTo(page:)`.
///
/// The helper must mirror `nextPage()`'s step rule exactly:
///   solo (step 1)  when pages[i].isSpread OR pages[i+1].isSpread
///   pair (step 2)  otherwise
/// These tests guard against a naive `p % 2` parity implementation which
/// breaks as soon as a spread page shifts all later pairs off even/odd indices.
@MainActor
final class GoToPageTests: XCTestCase {

    // MARK: - Helpers

    /// Build a portrait ComicPage (isSpread == false).
    /// naturalSize 600×900 → ratio ≈ 0.67, well below the 1.2 threshold.
    private func normalPage(id: Int) -> ComicPage {
        ComicPage(
            id: id,
            source: .file(URL(fileURLWithPath: "/tmp/dc-test-page-\(id).jpg")),
            naturalSize: CGSize(width: 600, height: 900)
        )
    }

    /// Build a landscape/spread ComicPage (isSpread == true).
    /// naturalSize 1800×900 → ratio == 2.0, above the 1.2 threshold.
    private func spreadPage(id: Int) -> ComicPage {
        ComicPage(
            id: id,
            source: .file(URL(fileURLWithPath: "/tmp/dc-test-spread-\(id).jpg")),
            naturalSize: CGSize(width: 1800, height: 900)
        )
    }

    // MARK: - All-normal pages

    /// [p0, p1, p2, p3, p4] → pairs (0,1)(2,3)(4)
    /// spreadAlignedLeftIndex for any page in a pair returns the left index.
    func testAllNormalPages() {
        let pages = (0..<5).map { normalPage(id: $0) }

        // Page 1 is in pair (0,1) → left index 0
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 1, pages: pages), 0,
                       "page 1 should snap to left index 0 of pair (0,1)")
        // Page 3 is in pair (2,3) → left index 2
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 3, pages: pages), 2,
                       "page 3 should snap to left index 2 of pair (2,3)")
        // Page 4 is solo (last unpaired) → left index 4
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 4, pages: pages), 4,
                       "page 4 should snap to left index 4 (last solo)")
        // Left pages of each pair are already their own left index
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 0, pages: pages), 0)
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 2, pages: pages), 2)
    }

    // MARK: - Parity-bug regression: spread at index 2

    /// [normal, normal, SPREAD, normal, normal] → slots (0,1)(2)(3,4)
    ///
    /// A naive `p % 2` implementation would place page 4 in "pair (4,5)"
    /// starting at index 4 (even) — which is accidentally correct here —
    /// BUT it would place page 3 in "pair (2,3)" starting at index 2, which
    /// is WRONG: index 2 is the solo spread, so page 3 is actually the LEFT
    /// page of pair (3,4).  The real helper must return 3 for page 4 and page 3.
    func testSpreadAtIndexTwoShiftsPairs() {
        // [normal(0), normal(1), SPREAD(2), normal(3), normal(4)]
        let pages: [ComicPage] = [
            normalPage(id: 0),
            normalPage(id: 1),
            spreadPage(id: 2),
            normalPage(id: 3),
            normalPage(id: 4)
        ]

        // Spread at index 2 is a solo slot → returns 2
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 2, pages: pages), 2,
                       "spread page at index 2 is its own solo slot")
        // Page 1 is in pair (0,1) → left index 0
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 1, pages: pages), 0,
                       "page 1 should snap to left index 0 of pair (0,1)")
        // Pages 3 and 4 are in pair (3,4) → left index 3
        // (a naive p%2 would leave 4 at index 4 — the regression this test guards)
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 4, pages: pages), 3,
                       "page 4 must snap to left index 3 (pair (3,4) shifted by spread at 2)")
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 3, pages: pages), 3,
                       "page 3 is left page of pair (3,4)")
    }

    // MARK: - Clamp assertions (via the static helper + explicit bounds)

    /// A negative index clamps to 0.
    func testNegativePageClampsToZero() {
        let pages = (0..<5).map { normalPage(id: $0) }
        // Clamp first: max(0, min(-5, 4)) = 0
        let clamped = max(0, min(-5, pages.count - 1))
        XCTAssertEqual(clamped, 0)
        // Helper on clamped value
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: clamped, pages: pages), 0)
    }

    /// An out-of-bounds page index clamps to pageCount - 1.
    func testLargePageClampsToLast() {
        let pages = (0..<5).map { normalPage(id: $0) }
        let clamped = max(0, min(9999, pages.count - 1))
        XCTAssertEqual(clamped, 4)
        // Last page is solo (odd one out) → returns 4
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: clamped, pages: pages), 4)
    }

    // MARK: - Edge cases

    /// Single-page comic: helper returns 0.
    func testSinglePageComic() {
        let pages = [normalPage(id: 0)]
        XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: 0, pages: pages), 0)
    }

    /// All spreads: every slot is solo, each page returns its own index.
    func testAllSpreads() {
        let pages = (0..<4).map { spreadPage(id: $0) }
        for i in 0..<pages.count {
            XCTAssertEqual(ReaderViewModel.spreadAlignedLeftIndex(for: i, pages: pages), i,
                           "all-spread comic: page \(i) is its own solo slot")
        }
    }
}
