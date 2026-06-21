import CoreGraphics

/// Returns true when the cursor is within `edgeZone` points of the top or bottom
/// of the window — the reveal zone for auto-hidden chrome.
/// Window coords are bottom-left origin; top edge is near windowHeight, bottom near 0.
func isInEdgeRevealZone(y: CGFloat, windowHeight: CGFloat, edgeZone: CGFloat) -> Bool {
    y < edgeZone || y > windowHeight - edgeZone
}

/// Returns true when the chrome SHOULD auto-hide (all suppression conditions are clear).
/// Any suppressor (popover open, hover active, VoiceOver running) keeps chrome visible.
func shouldAutoHide(chromeVisible: Bool, popoverOpen: Bool, hovering: Bool, voiceOver: Bool) -> Bool {
    chromeVisible && !popoverOpen && !hovering && !voiceOver
}
