import Foundation
import CoreGraphics

// Pure predicates for the click-to-turn / hold-for-loupe state machine.
// No AppKit or SwiftUI imports — testable from DCTests without a running app.

/// Which page-turn direction a tap selects based on the horizontal click position.
enum TapTurn { case previous, next }

/// Returns `.previous` when `downX` is in the left half of the viewport,
/// `.next` otherwise.
func tapTurnDirection(downX: CGFloat, viewportWidth: CGFloat) -> TapTurn {
    downX < viewportWidth / 2 ? .previous : .next
}

/// Returns `true` when the gesture should escalate from a pending tap to
/// an active loupe — either because the hold threshold has been reached or
/// because the finger has moved beyond the movement tolerance.
func shouldEscalateToLoupe(
    elapsed: TimeInterval,
    movement: CGFloat,
    hold: TimeInterval,
    tolerance: CGFloat
) -> Bool {
    elapsed >= hold || movement > tolerance
}

/// Minimum hold duration (seconds) before a mouse-down escalates to a loupe.
let LoupeHoldThreshold: TimeInterval = 0.15

/// Maximum pixel movement that still qualifies as a stationary tap.
/// Movement beyond this threshold immediately escalates to the loupe.
/// Bumped 5→14 (Reader Immersion) — a slightly larger finger-drift still
/// counts as a page-turn tap rather than spawning the magnifier.
let LoupeMoveTolerance: CGFloat = 14
