import XCTest
@testable import DC

final class ChromeVisibilityTests: XCTestCase {

    // MARK: - isInEdgeRevealZone

    func testEdgeZoneBottomEdge() {
        // y=10 < edgeZone=72 → near bottom → true
        XCTAssertTrue(isInEdgeRevealZone(y: 10, windowHeight: 800, edgeZone: 72))
    }

    func testEdgeZoneTopEdge() {
        // y=780 > windowHeight(800) - edgeZone(72) = 728 → near top → true
        XCTAssertTrue(isInEdgeRevealZone(y: 780, windowHeight: 800, edgeZone: 72))
    }

    func testEdgeZoneExactBottomBoundary() {
        // y == edgeZone → NOT in zone (strict <)
        XCTAssertFalse(isInEdgeRevealZone(y: 72, windowHeight: 800, edgeZone: 72))
    }

    func testEdgeZoneExactTopBoundary() {
        // y == windowHeight - edgeZone → NOT in zone (strict >)
        XCTAssertFalse(isInEdgeRevealZone(y: 728, windowHeight: 800, edgeZone: 72))
    }

    func testEdgeZoneMidPage() {
        // y=400 is in the middle → false
        XCTAssertFalse(isInEdgeRevealZone(y: 400, windowHeight: 800, edgeZone: 72))
    }

    // MARK: - shouldAutoHide

    func testShouldAutoHideAllClear() {
        // All suppressors off and chrome visible → true
        XCTAssertTrue(shouldAutoHide(chromeVisible: true, popoverOpen: false, hovering: false, voiceOver: false))
    }

    func testShouldAutoHideWhenAlreadyHidden() {
        // Chrome already hidden → false (nothing to hide)
        XCTAssertFalse(shouldAutoHide(chromeVisible: false, popoverOpen: false, hovering: false, voiceOver: false))
    }

    func testShouldAutoHidePopoverOpen() {
        XCTAssertFalse(shouldAutoHide(chromeVisible: true, popoverOpen: true, hovering: false, voiceOver: false))
    }

    func testShouldAutoHideHovering() {
        XCTAssertFalse(shouldAutoHide(chromeVisible: true, popoverOpen: false, hovering: true, voiceOver: false))
    }

    func testShouldAutoHideVoiceOver() {
        XCTAssertFalse(shouldAutoHide(chromeVisible: true, popoverOpen: false, hovering: false, voiceOver: true))
    }

    func testShouldAutoHideMultipleSupressors() {
        XCTAssertFalse(shouldAutoHide(chromeVisible: true, popoverOpen: true, hovering: true, voiceOver: true))
    }
}
