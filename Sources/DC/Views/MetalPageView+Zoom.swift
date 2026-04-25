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
    /// event is passed through so NSScrollView handles it natively.
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
            case .singlePage, .doubleSpread: break
            case .verticalStack: return event
            }
            // Apply a proportional step to our own `scale` state (flows
            // through ReaderViewModel → SwiftUI → rebuildLayout). We do
            // NOT touch scrollView.magnification in single/double modes.
            let step: CGFloat = 1 + CGFloat(event.scrollingDeltaY) * 0.01
            let newScale = self.scale * step
            let clamped = min(max(newScale, ReaderConstants.wheelZoomMin), ReaderConstants.nativeMagnificationMax)
            self.onMagnificationChanged?(clamped)
            return nil // consume the event
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
            // Reset zoom via the scale binding rather than magnification.
            self.onMagnificationChanged?(1.0)
            return nil
        }
    }

    /// Trackpad pinch gesture → updates `vm.scale` via the onMagnificationChanged
    /// callback. Replaces the NSScrollView.magnification pinch path for
    /// single/double layouts, which don't use NSScrollView magnification.
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
            case .singlePage, .doubleSpread: break
            case .verticalStack: return event
            }
            let step: CGFloat = 1 + event.magnification
            let newScale = self.scale * step
            let clamped = min(max(newScale, ReaderConstants.wheelZoomMin), ReaderConstants.nativeMagnificationMax)
            self.onMagnificationChanged?(clamped)
            return nil
        }
    }
}
