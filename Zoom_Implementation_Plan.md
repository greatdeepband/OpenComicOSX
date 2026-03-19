# Implementation Plan: Option C (NSScrollView Magnification)

This document outlines the exact code changes required to implement Option C. The goal is to replace the expensive `buildPages()` rebuild-on-scale approach with native `NSScrollView` magnification, fixing both the broken scroll-wheel zoom and the performance flash in vertical modes.

## 1. `VerticalComicScrollView` (The Core Fix)

The `NSViewRepresentable` wrapper for the vertical reader needs to stop rebuilding pages when `scale` changes, and instead delegate scaling to the `NSScrollView`.

**Changes in `makeNSView`:**
- Enable native magnification:
  ```swift
  scrollView.allowsMagnification = true
  scrollView.minMagnification = 0.1
  scrollView.maxMagnification = 8.0
  ```
- Set the initial magnification:
  ```swift
  scrollView.magnification = scale
  ```
- Add an observer for magnification changes (so trackpad pinch updates the view model):
  ```swift
  NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.magnificationDidChange(_:)),
      name: NSScrollView.didEndLiveMagnifyNotification,
      object: scrollView
  )
  ```

**Changes in `updateNSView`:**
- Remove `scale` from the `needsRebuild` condition. The stack view should only be rebuilt if `containerWidth` or `pagesPerRow` changes.
- If `scale` has changed (e.g., from toolbar buttons), apply it directly to the scroll view without rebuilding:
  ```swift
  if abs(scrollView.magnification - scale) > 0.001 {
      scrollView.magnification = scale
  }
  ```

**Changes in `buildPages`:**
- Remove `scale` from the layout math. Pages should always be built at `scale = 1.0`.
  ```swift
  let totalWidth = containerWidth // (no longer multiplied by scale)
  ```

**Changes in `Coordinator`:**
- Add a new callback: `var onMagnificationChanged: (CGFloat) -> Void`
- Add the notification handler:
  ```swift
  @objc func magnificationDidChange(_ notification: Notification) {
      guard let sv = scrollView else { return }
      onMagnificationChanged(sv.magnification)
  }
  ```

## 2. `ReaderViewModel` (State Management)

The view model needs a way to receive magnification updates from the scroll view without triggering a feedback loop.

**Changes:**
- Add a new method to handle incoming scale updates from the scroll view:
  ```swift
  func setScaleFromScrollView(_ newScale: CGFloat) {
      // Update the published property so the toolbar UI reflects the new scale,
      // but do it in a way that doesn't cause updateNSView to fight the scroll view.
      self.scale = newScale.clamped(to: minScale...maxScale)
  }
  ```
- Fix the `fitToWidth` bug for Double Page mode (currently it only looks at the left page):
  ```swift
  func fitToWidth(containerWidth: CGFloat) {
      // In Double Page mode, the layout already forces the spread to fill the container width.
      // So "Fit to Width" simply means scale = 1.0.
      if readingMode == .doublePage {
          withAnimation(.easeOut(duration: 0.2)) {
              scale = 1.0
              offset = .zero
          }
          return
      }
      // ... existing single-page logic ...
  }
  ```

## 3. `ReaderView` (Wiring)

The SwiftUI view needs to wire the new callback and remove the broken scroll-wheel modifier.

**Changes in `verticalScrollView`:**
- Remove the `.onScrollWheel { ... }` modifier entirely. `NSScrollView` will now handle scroll-wheel zoom natively.
- Add the new callback to the `VerticalComicScrollView` initializer:
  ```swift
  onMagnificationChanged: { newScale in
      vm.setScaleFromScrollView(newScale)
  }
  ```

## Summary of Impact

1. **Performance:** Zooming in vertical modes will no longer tear down and recreate `NSView` instances. It will be perfectly smooth.
2. **Scroll-wheel:** Will work natively in vertical modes without being intercepted by the scroll view's vertical scrolling logic.
3. **Double Page:** "Fit to Width" will correctly fit the entire spread rather than just the left page.
4. **Global State:** The `vm.scale` property remains the single source of truth for the toolbar UI, but rendering is delegated to AppKit.
