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
