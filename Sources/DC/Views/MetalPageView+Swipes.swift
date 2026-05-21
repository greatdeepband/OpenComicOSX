import SwiftUI
import AppKit

// Trackpad swipe navigation for single & double page modes:
//   - 2-finger horizontal swipe → next/prev page
//   - 3-finger horizontal swipe → next/prev comic
//
// Both gestures arrive as `.scrollWheel` events with `hasPreciseScrollingDeltas`
// (trackpad). The finger count is read from `event.allTouches().count` at the
// `.began` phase and latched for the rest of the gesture so a mid-swipe finger
// lift doesn't switch the action. `NSEvent.EventType.swipe` is NOT used —
// modern macOS only generates that event when the user has explicitly enabled
// "Swipe between pages: Swipe with three fingers" in Trackpad settings, which
// is off by default. Touch-counting on scroll events is the channel that
// actually fires under default preferences.
//
// Caveat: if the user has "Swipe between full-screen apps" set to 3-finger
// (default on macOS), the OS consumes 3-finger horizontal swipes before they
// reach the app. Changing that setting to 4-finger frees the 3-finger gesture
// for app use.
//
// Vertical-stack layouts are left alone — they use 2-finger scroll for
// the natural reading motion and shouldn't have it stolen for page nav.

extension MetalPageView.Coordinator {

    /// Unified trackpad-swipe monitor for single & double page modes.
    /// Detects 2-finger and 3-finger horizontal swipes via touch-counting on
    /// `.scrollWheel` events. Fires `onPageNavSwipe(±1)` for 2-finger and
    /// `onComicNavSwipe(±1)` for 3-finger when the horizontal accumulator
    /// crosses `ReaderConstants.pageSwipeThreshold` AND horizontal dominates
    /// vertical by `ReaderConstants.swipeHorizontalDominanceRatio`.
    ///
    /// Pass-through cases:
    ///   - non-trackpad scroll (no precise deltas) → never page-nav
    ///   - ⌘ held → reserved for zoom (`installZoomWheelMonitor`)
    ///   - scale > 1 + epsilon → user is zoomed, let NSScrollView pan
    ///   - vertical-stack layout → never intercept
    ///   - momentum-phase events → ignored so a flick can't double-fire
    func installPageSwipeMonitor() {
        guard pageSwipeMonitor == nil else { return }
        pageSwipeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            guard let self = self,
                  let scrollView = self.scrollView,
                  event.window === scrollView.window else { return event }
            switch self.layout {
            case .verticalStack:
                return event
            case .singlePage, .doubleSpread:
                break
            }
            if event.modifierFlags.contains(.command) { return event }
            guard event.hasPreciseScrollingDeltas else { return event }
            guard event.momentumPhase == [] else { return event }
            if self.scale > 1.0 + ReaderConstants.scaleEqualityEpsilon {
                return event
            }
            switch event.phase {
            case .began, .mayBegin:
                self.swipeAccumX = 0
                self.swipeAccumY = 0
                self.swipeFired = false
                // Latch the finger count for the duration of this gesture.
                // Mid-gesture lifts (going 3→2 or 2→3) won't switch the
                // intent — whatever the user started with is what fires.
                self.swipeFingerCount = event.allTouches().count
                return nil
            case .changed:
                self.swipeAccumX += CGFloat(event.scrollingDeltaX)
                self.swipeAccumY += CGFloat(event.scrollingDeltaY)
                if !self.swipeFired,
                   abs(self.swipeAccumX) >= ReaderConstants.pageSwipeThreshold,
                   abs(self.swipeAccumX) >= abs(self.swipeAccumY)
                                            * ReaderConstants.swipeHorizontalDominanceRatio {
                    self.swipeFired = true
                    // Natural-scrolling convention: swipe RIGHT (deltaX > 0)
                    // = drag page right = reveal PREVIOUS. Swipe LEFT = NEXT.
                    let direction = self.swipeAccumX > 0 ? -1 : 1
                    if self.swipeFingerCount >= 3 {
                        self.onComicNavSwipe?(direction)
                    } else {
                        self.onPageNavSwipe?(direction)
                    }
                }
                return nil
            case .ended, .cancelled:
                self.swipeAccumX = 0
                self.swipeAccumY = 0
                self.swipeFired = false
                self.swipeFingerCount = 0
                return nil
            default:
                return nil
            }
        }
    }

    /// Kept as a no-op stub so MetalPageView's `makeNSView` still compiles.
    /// The `.swipe` event type rarely fires on modern macOS — touch-counting
    /// in `installPageSwipeMonitor` handles both 2- and 3-finger gestures.
    func installComicSwipeMonitor() {
        // Intentionally empty. See file header.
    }
}
