import CoreGraphics

// Pure predicate for the top-bar exemption in the loupe / tap-turn monitor.
// No AppKit or SwiftUI imports — testable from DCTests without a running app.

/// True when a window-space click is within the top toolbar band.
/// Window coords are bottom-left origin → the TOP band has the LARGEST y.
/// Correct predicate: `y > windowHeight - topBarHeight`
/// (The inverted form `svLocal.y < topBarHeight` was wrong because it tested
/// scroll-view coords with top-origin, but used a bottom-left distance —
/// see `updateLoupe` at MetalPageView+Loupe.swift:240-243 for the proof.)
func isInTopBarBand(locationInWindowY y: CGFloat, windowHeight: CGFloat, topBarHeight: CGFloat) -> Bool {
    y > windowHeight - topBarHeight
}

/// True when a window-space click is within the floating bottom bar band.
/// Window coords are bottom-left origin → bottom bar occupies y in [bottomPadding, bottomPadding+barHeight).
/// bottomPadding: the gap between the window sill (y=0) and the bar's lower edge.
/// barHeight: the height of the floating bar (scrubberStripHeight).
/// y < bottomPadding → below the bar (sill/resize zone, handled by resize-margin guards) → false.
/// y >= bottomPadding+barHeight → above the bar → false.
func isInBottomBarBand(locationInWindowY y: CGFloat, bottomPadding: CGFloat, barHeight: CGFloat) -> Bool {
    y >= bottomPadding && y < bottomPadding + barHeight
}
