import Foundation

enum NavStep { case next, prev }

/// Maps a "forward-ish" raw input (swipe offset > 0, or right-key) to a story step, honoring RTL.
func navStep(forwardInput: Bool, isRTL: Bool) -> NavStep { (forwardInput != isRTL) ? .next : .prev }

/// Double-spread slot page indices (left, right) for the pair starting at currentPage.
func spreadSlots(currentPage: Int, isRTL: Bool) -> (left: Int, right: Int) {
    isRTL ? (left: currentPage + 1, right: currentPage) : (left: currentPage, right: currentPage + 1)
}
