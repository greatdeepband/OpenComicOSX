# Zoom Inconsistency — Diagnosis & Fix Proposal

## 1. What the user experiences

In **Double Page** and **Vertical Double** modes, zoom does not behave as a single global control. Each page appears to have its own independent zoom state, so the user must interact with each page separately to get a consistent zoom level across the spread or column.

## 2. Root cause analysis

### Double Page mode (`SpreadView`)

`SpreadView` is a single SwiftUI view that receives `$vm.scale` and `$vm.offset` as bindings from `ReaderViewModel`. On the surface this looks correct — there is one shared `scale` value. The problem is in how the layout uses it:

```swift
let scaledTotal = containerSize.width * scale
let pageW = (scaledTotal - 2) / 2
let pageH = containerSize.height * scale
```

Both pages are sized from the same `scale` value, so the **layout** is global. However, `SpreadView` also contains its own internal `MagnifyGesture` and `onScrollWheel` handler that write directly back to the `scale` binding. This means the spread-level gesture correctly updates the shared scale.

The real issue is the **per-page interaction model**. The pages are rendered as two separate `Image(nsImage:)` views inside an `HStack`. There is no hit-testing on the individual images — a single `MouseCatcher` covers the whole spread. However, the `MagnifyGesture` is attached to the outer `ZStack`, not the individual images. This is fine for trackpad pinch. The problem surfaces with the **toolbar zoom buttons** and **keyboard shortcuts**:

- `vm.zoomIn()` / `vm.zoomOut()` modify `vm.scale` ✓ — this propagates to `SpreadView` correctly.
- `vm.fitToWidth()` calls `currentImage` (the **left** page only) to compute the target scale. If the left and right pages have different aspect ratios, "Fit to Width" will fit the left page but leave the right page slightly over- or under-scaled.
- `vm.resetZoom()` resets to `scale = 1.0` globally ✓ — this is fine.

**Verdict for Double Page:** The zoom level itself is already global (one `vm.scale`). The bug is that `fitToWidth` and `zoomToActualSize` compute their target scale from `currentImage` (the left page only), producing a scale that is "correct" for one page but not the other.

### Vertical Double mode (`VerticalComicScrollView`)

This mode is architecturally different. `VerticalComicScrollView` is an `NSViewRepresentable` backed by an `NSScrollView`. It receives `scale` as a plain `let` (not a binding):

```swift
struct VerticalComicScrollView: NSViewRepresentable {
    let scale: CGFloat
    ...
}
```

In `updateNSView`, a rebuild is triggered whenever `scale` changes:

```swift
let needsRebuild = context.coordinator.lastScale != scale
    || context.coordinator.lastContainerWidth != containerWidth
    || context.coordinator.lastPagesPerRow != pagesPerRow
```

When a rebuild fires, `buildPages()` tears down and recreates **all** `NSView` instances for every page. Each `ComicPageView` is a plain `NSView` with a fixed `widthAnchor` and `heightAnchor` computed from `containerWidth * scale`. So the scale **is** applied globally — all pages get the same width.

**The actual problem in Vertical Double:** The scroll-wheel zoom handler in `ReaderView` writes to `vm.scale`:

```swift
.onScrollWheel { event in
    let factor: CGFloat = event.deltaY > 0 ? 0.95 : 1.05
    vm.scale = (vm.scale * factor).clamped(to: vm.minScale...vm.maxScale)
}
```

This is attached to the `VerticalComicScrollView` wrapper in SwiftUI. However, `NSScrollView` intercepts scroll events for its own scrolling before they reach the SwiftUI scroll-wheel modifier. The result: **scroll events that land on the NSScrollView's content area are consumed by the scroll view for vertical scrolling, and never reach the SwiftUI `onScrollWheel` modifier.** Only scroll events that land on the narrow border area outside the content reach the zoom handler.

The toolbar buttons (`vm.zoomIn()`, `vm.zoomOut()`) do work globally, but they trigger a full `buildPages()` rebuild — tearing down and recreating every `NSView` — which is expensive and causes a visible flash/relayout.

**Verdict for Vertical Double:** The zoom level is global in principle, but the scroll-wheel zoom path is broken (events eaten by NSScrollView), and the rebuild-on-scale approach is heavy.

## 3. Summary table

| Mode | Zoom level | Toolbar buttons | Scroll-wheel zoom | Fit to Width | Rebuild cost |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Single Page | Global (`vm.scale`) | ✓ | ✓ | ✓ (uses current page) | None (scaleEffect) |
| Double Page | Global (`vm.scale`) | ✓ | ✓ | Partial (left page only) | None (frame math) |
| Vertical Scroll | Global (`vm.scale`) | ✓ | Broken (NSScrollView eats events) | N/A | Full rebuild |
| Vertical Double | Global (`vm.scale`) | ✓ | Broken (NSScrollView eats events) | N/A | Full rebuild |

## 4. Fix approaches

### Option A: NSScrollView `magnification` property (native AppKit zoom)

`NSScrollView` has a built-in `magnification` property and `setMagnification(_:centeredAt:)` method. When enabled with `allowsMagnification = true`, it handles pinch-to-zoom natively and scales the entire document view as a unit — no rebuild required.

**Pros:** Native, smooth, no rebuild on zoom, scroll events are not confused with zoom events.  
**Cons:** Requires syncing `NSScrollView.magnification` ↔ `vm.scale` bidirectionally. The coordinator must observe magnification changes and push them back to the view model. Moderately complex.

### Option B: `NSScrollView` scroll event interception in the coordinator

Keep the current architecture but override `scrollWheel` in the `NSScrollView` subclass (or a wrapper `NSView`). Inspect each event: if it has a `phase` of `.changed` with a non-zero `deltaY` and the modifier key (e.g., Cmd or Option) is held, treat it as zoom; otherwise pass it to `super` for scrolling.

**Pros:** Minimal changes to the existing layout model.  
**Cons:** Requires a modifier key for zoom (changes UX), or requires heuristic disambiguation (fragile). Does not fix the rebuild-on-scale cost.

### Option C: `NSScrollView.magnification` + remove rebuild-on-scale

The cleanest solution. Replace the current `buildPages()` rebuild path with `NSScrollView`'s native magnification:

1. Set `scrollView.allowsMagnification = true`, `scrollView.minMagnification = 0.1`, `scrollView.maxMagnification = 8.0`.
2. In `makeNSView`, set `scrollView.magnification = scale` from the initial value.
3. In `updateNSView`, instead of rebuilding pages when `scale` changes, call `scrollView.setMagnification(scale, centeredAt: ...)`.
4. In the coordinator, observe `NSScrollView.didEndLiveMagnifyNotification` and push the new magnification back to `vm.scale` via the `onOffsetChanged` callback (or a new dedicated callback).
5. Pages are built once at `scale = 1.0` and the scroll view handles all zoom rendering — no `buildPages()` on zoom.

For `fitToWidth` in Double Page mode, compute the target scale from the **wider** of the two pages (or the average), not just `currentImage`.

**Pros:** Eliminates the rebuild-on-scale entirely. Scroll-wheel zoom works naturally (NSScrollView distinguishes scroll from magnify). Global zoom is guaranteed because the entire document view scales as one unit. Smooth and native.  
**Cons:** Requires a new `onMagnificationChanged` callback from the coordinator to the view model. The `scale` sync must be one-way (SwiftUI → NSScrollView for toolbar/keyboard, NSScrollView → SwiftUI for trackpad pinch), which requires careful handling to avoid feedback loops.

## 5. Recommendation

**Option C** is the right fix. It addresses both the broken scroll-wheel zoom and the expensive rebuild, and it makes zoom genuinely global by delegating to the platform's own mechanism.

The `fitToWidth` bug in Double Page mode is a one-line fix: use `max(leftImage.size.width, rightImage?.size.width ?? 0)` when computing the target scale, or simply use the container width directly (since both pages always fill the container width in the current layout).

**Scope of changes:**
- `VerticalComicScrollView`: replace `buildPages()` rebuild-on-scale with `scrollView.magnification` sync; add `onMagnificationChanged` callback.
- `ReaderViewModel`: add a `setScaleFromScrollView(_ s: CGFloat)` method that updates `scale` without triggering a rebuild loop.
- `ReaderView.verticalScrollView`: wire the new callback.
- `ReaderViewModel.fitToWidth`: fix the single-page assumption.
