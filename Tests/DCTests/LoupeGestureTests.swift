import XCTest
@testable import DC

/// Tests for the pure predicates in `LoupeGesture.swift`.
/// These functions have no AppKit dependencies and run on any platform.
final class LoupeGestureTests: XCTestCase {

    // MARK: - tapTurnDirection

    func testTapTurnPrevious() {
        XCTAssertEqual(tapTurnDirection(downX: 10, viewportWidth: 100), .previous)
    }

    func testTapTurnNext() {
        XCTAssertEqual(tapTurnDirection(downX: 90, viewportWidth: 100), .next)
    }

    func testTapTurnExactMidpoint() {
        // downX == viewportWidth/2: not strictly less than half → .next
        XCTAssertEqual(tapTurnDirection(downX: 50, viewportWidth: 100), .next)
    }

    // MARK: - shouldEscalateToLoupe

    func testEscalateOnHold() {
        // elapsed >= hold threshold → escalate even with no movement
        XCTAssertTrue(shouldEscalateToLoupe(elapsed: 0.2, movement: 0, hold: 0.15, tolerance: 5))
    }

    func testEscalateOnMovement() {
        // movement > tolerance → escalate even before hold threshold
        XCTAssertTrue(shouldEscalateToLoupe(elapsed: 0.05, movement: 10, hold: 0.15, tolerance: 5))
    }

    func testNoEscalateOnQuickTap() {
        // short hold, small movement → still a tap
        XCTAssertFalse(shouldEscalateToLoupe(elapsed: 0.05, movement: 1, hold: 0.15, tolerance: 5))
    }

    func testEscalateExactlyAtThreshold() {
        // elapsed == hold → escalate (>= is inclusive)
        XCTAssertTrue(shouldEscalateToLoupe(elapsed: 0.15, movement: 0, hold: 0.15, tolerance: 5))
    }

    func testNoEscalateExactlyAtTolerance() {
        // movement == tolerance is NOT > tolerance → no escalation
        XCTAssertFalse(shouldEscalateToLoupe(elapsed: 0.05, movement: 5, hold: 0.15, tolerance: 5))
    }
}
