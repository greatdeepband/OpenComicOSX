import SwiftUI
import AppKit

// Zoom-input monitors for the MetalPageView Coordinator. Owns the
// scroll-wheel, double-click, and trackpad-pinch monitors that drive
// `vm.scale` via `onMagnificationChanged`. NSScrollView's native
// magnification handles vertical modes; single/double resize the
// documentView in `rebuildLayout` instead.

extension MetalPageView.Coordinator {

    /// ⌘+scroll-wheel adjusts zoom. In single/double layouts zoom is
    /// applied via `onMagnificationChanged` → `vm.scale` → frame-resize
    /// (never via scrollView.magnification, which causes CAMetalLayer
    /// compositing to bypass ancestor clipping). In vertical mode the
    /// event is consumed and translated into a ±10% window-resize
    /// step (see `applyVerticalZoomGestureDelta`).
    func installZoomWheelMonitor() {
        guard zoomWheelMonitor == nil else { return }
        zoomWheelMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            guard let self = self,
                  let scrollView = self.scrollView,
                  event.window === scrollView.window,
                  event.modifierFlags.contains(.command) else {
                return event
            }
            switch self.layout {
            case .singlePage, .doubleSpread:
                // Apply a proportional step to our own `scale` state
                // (flows through ReaderViewModel → SwiftUI →
                // rebuildLayout). We do NOT touch
                // scrollView.magnification in single/double modes.
                let step: CGFloat = 1 + CGFloat(event.scrollingDeltaY) * 0.01
                let newScale = self.scale * step
                let clamped = min(max(newScale, ReaderConstants.wheelZoomMin),
                                  ReaderConstants.nativeMagnificationMax)
                self.onMagnificationChanged?(clamped)
                return nil
            case .verticalStack:
                // Vertical: zoom is window-resize. Feed the wheel delta
                // (scaled to roughly match pinch.magnification's
                // typical range) into the gesture accumulator.
                self.applyVerticalZoomGestureDelta(CGFloat(event.scrollingDeltaY) / 100.0)
                return nil
            }
        }
    }

    /// Double-click inside the metal view resets zoom to 1.0.
    /// Drives scale via `onMagnificationChanged` → `vm.scale` → frame-resize
    /// rather than scrollView.magnification (single/double modes only).
    func installDoubleClickMonitor() {
        guard doubleClickMonitor == nil else { return }
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            guard let self = self,
                  let scrollView = self.scrollView,
                  event.clickCount == 2,
                  event.window === scrollView.window else {
                return event
            }
            switch self.layout {
            case .singlePage, .doubleSpread: break
            case .verticalStack: return event
            }
            // Ensure the click is inside the scroll area (not on toolbar).
            let svLocal = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(svLocal) else { return event }
            // Top-bar band guard (window coords, bottom-left origin):
            // a double-click on the scrubber or toolbar should not reset zoom.
            let winPt = event.locationInWindow
            guard let win = scrollView.window else { return event }
            if isInTopBarBand(locationInWindowY: winPt.y,
                              windowHeight: win.frame.height,
                              topBarHeight: ReaderConstants.topBarHeight) { return event }
            // Reset zoom via the scale binding rather than magnification.
            self.onMagnificationChanged?(1.0)
            return nil
        }
    }

    /// Trackpad pinch gesture → updates `vm.scale` via the onMagnificationChanged
    /// callback. Replaces the NSScrollView.magnification pinch path for
    /// single/double layouts, which don't use NSScrollView magnification.
    /// In vertical layouts the gesture is consumed and translated into a
    /// ±10% window-resize step (see `applyVerticalZoomGestureDelta`).
    func installPinchMonitor() {
        guard pinchMonitor == nil else { return }
        pinchMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .magnify
        ) { [weak self] event in
            guard let self = self,
                  let scrollView = self.scrollView,
                  event.window === scrollView.window else {
                return event
            }
            switch self.layout {
            case .singlePage, .doubleSpread:
                let step: CGFloat = 1 + event.magnification
                let newScale = self.scale * step
                let clamped = min(max(newScale, ReaderConstants.wheelZoomMin),
                                  ReaderConstants.nativeMagnificationMax)
                self.onMagnificationChanged?(clamped)
                return nil
            case .verticalStack:
                self.applyVerticalZoomGestureDelta(event.magnification)
                return nil
            }
        }
    }

    /// Vertical / vertical-double zoom-replaces-window-resize behaviour.
    /// Each pinch frame or ⌘+scroll tick contributes a small signed delta
    /// (positive = zoom in / grow; negative = zoom out / shrink). We
    /// accumulate the deltas across a single user gesture and only fire a
    /// discrete ±10% window-resize step when the accumulator crosses
    /// `verticalZoomGestureThreshold`. A separate `verticalZoomStepCooldown`
    /// rate-limits a fast continuous gesture so the window doesn't run
    /// away across the screen during a single pinch.
    func applyVerticalZoomGestureDelta(_ delta: CGFloat) {
        zoomGestureAccumulator += delta
        guard abs(zoomGestureAccumulator) >= ReaderConstants.verticalZoomGestureThreshold else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastZoomStepTime >= ReaderConstants.verticalZoomStepCooldown else { return }
        let direction: CGFloat = zoomGestureAccumulator > 0 ? 1 : -1
        zoomGestureAccumulator = 0
        lastZoomStepTime = now
        resizeWindowForVerticalZoom(direction: direction)
    }

    /// Resize the reader's window by ±`verticalZoomWindowFactor`, keeping
    /// the window centred on its current centre and clamping to the
    /// screen's visible frame on growth and to `verticalZoomMinSize` on
    /// shrink. Skips if the resulting size matches the current frame
    /// (already at a clamp).
    func resizeWindowForVerticalZoom(direction: CGFloat) {
        guard let window = scrollView?.window else { return }
        let factor: CGFloat = direction > 0
            ? ReaderConstants.verticalZoomWindowFactor
            : 1.0 / ReaderConstants.verticalZoomWindowFactor
        let oldFrame = window.frame
        var newSize = CGSize(width: oldFrame.width * factor, height: oldFrame.height * factor)
        // Clamp to screen visible frame (don't grow off-screen)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            newSize.width  = min(newSize.width,  visible.width)
            newSize.height = min(newSize.height, visible.height)
        }
        // Clamp to minimum readable size
        let minS = ReaderConstants.verticalZoomMinSize
        newSize.width  = max(newSize.width,  minS.width)
        newSize.height = max(newSize.height, minS.height)
        // No-op if we'd produce the same frame (already at a clamp)
        if abs(newSize.width  - oldFrame.width)  < 0.5 &&
           abs(newSize.height - oldFrame.height) < 0.5 { return }
        let dx = (newSize.width  - oldFrame.width)  / 2
        let dy = (newSize.height - oldFrame.height) / 2
        let newOrigin = CGPoint(x: oldFrame.origin.x - dx, y: oldFrame.origin.y - dy)
        window.setFrame(CGRect(origin: newOrigin, size: newSize), display: true, animate: false)
    }
}
