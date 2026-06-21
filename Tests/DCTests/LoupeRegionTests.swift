import XCTest
@testable import DC

/// Tests for the pure predicate in `LoupeRegion.swift`.
/// These functions have no AppKit dependencies and run on any platform.
final class LoupeRegionTests: XCTestCase {

    func testTopBarYIsInBand() {
        // y=590 in a 600pt window with 64pt bar → in the top band
        XCTAssertTrue(isInTopBarBand(locationInWindowY: 590, windowHeight: 600, topBarHeight: 64))
    }

    func testPageMiddleYIsNotInBand() {
        // y=300 is well below the top band
        XCTAssertFalse(isInTopBarBand(locationInWindowY: 300, windowHeight: 600, topBarHeight: 64))
    }

    func testBottomYIsNotInBand() {
        // y=10 is near the bottom — the OLD inverted test (svLocal.y < topBarHeight)
        // wrongly treated this as "in the strip". Confirm fixed.
        XCTAssertFalse(isInTopBarBand(locationInWindowY: 10, windowHeight: 600, topBarHeight: 64))
    }

    func testBoundaryIsNotInBand() {
        // y == windowHeight - topBarHeight is exactly on the boundary → not in band (strict >)
        XCTAssertFalse(isInTopBarBand(locationInWindowY: 536, windowHeight: 600, topBarHeight: 64))
    }

    // MARK: - Bottom bar band

    func testBottomBarBandInsideRange() {
        // pad=10, barH=22 → band=[10,32); y=20 is inside
        XCTAssertTrue(isInBottomBarBand(locationInWindowY: 20, bottomPadding: 10, barHeight: 22))
    }

    func testBottomBarBandLowerBoundary() {
        // y == bottomPadding → inside (>= is inclusive)
        XCTAssertTrue(isInBottomBarBand(locationInWindowY: 10, bottomPadding: 10, barHeight: 22))
    }

    func testBottomBarBandUpperBoundary() {
        // y == bottomPadding + barHeight → NOT inside (< is exclusive)
        XCTAssertFalse(isInBottomBarBand(locationInWindowY: 32, bottomPadding: 10, barHeight: 22))
    }

    func testBottomBarBandAboveBar() {
        // y=300 is well above the bottom bar → false
        XCTAssertFalse(isInBottomBarBand(locationInWindowY: 300, bottomPadding: 10, barHeight: 22))
    }

    func testBottomBarBandBelowSill() {
        // y < bottomPadding → below the bar (sill/resize zone) → false
        XCTAssertFalse(isInBottomBarBand(locationInWindowY: 5, bottomPadding: 10, barHeight: 22))
    }
}
