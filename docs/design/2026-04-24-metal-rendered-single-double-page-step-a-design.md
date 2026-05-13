# Metal-Rendered Single & Double Page (Step A) — Design

**Date:** 2026-04-24
**Scope:** Replace `ZoomableImageView` (single-page) and `SpreadView` (double-page) with Metal-rendered views that share the vertical-mode pipeline. Every reading mode now renders through `MetalPageRenderer` + a shared `MetalPageManager`.
**Predecessor:** v0.9.0 (step B — decode-cache unification). Backup at `/Volumes/Media/DC_dev_lib_backup_20260424_001822/`.

## Goal

One renderer, one decode cache, one loupe, one gesture model across all four reading modes. Delete the SwiftUI Image + MouseCatcher + Canvas-loupe path that single/double page modes have used since v0.2.

**In scope:** single-page mode migration; double-page mode migration; deletion of `ZoomableImageView`, `SpreadView`, `MouseCatcher`, the `ScrollWheelModifier` family, and all SwiftUI-side loupe code.

**Out of scope:** shader changes (current vertex/fragment shaders already handle document-space projection correctly). `MetalPageManager` changes beyond existing APIs (the step-B work is sufficient).

## Current architecture (after step B)

| Reading mode | Display | Gesture model | Loupe |
|---|---|---|---|
| Single page | `ZoomableImageView` → SwiftUI `Image(nsImage:)` + `.scaleEffect` + `.offset` | `MagnifyGesture`, `onScrollWheel`, `MouseCatcher` (left→loupe, right→pan) | `MagnifierView` (Canvas) as SwiftUI overlay |
| Double page | `SpreadView` → two SwiftUI `Image` children in `HStack` | Same as single-page, plus `computeLoupe(at:)` that routes per-page | `MagnifierView` (Canvas) via separate `@State` per spread |
| Vertical | `MetalPageView` → `NSScrollView` + `MetalCanvasView` + Metal render | `NSScrollView.magnification` for zoom; scroll for pan; `NSEvent` monitor for left-click loupe | `MagnifierView` in a child `NSPanel` |
| Vertical double | Same `MetalPageView` with `pagesPerRow == 2` | Same | Same |

All four modes fetch NSImages from the same `MetalPageManager` (step B) but render through two unrelated stacks.

## Target architecture

One `MetalPageView` configuration drives every mode. The `pagesPerRow` + a new `ReadingLayout` enum decide whether the content is a vertical stack (existing behaviour) or a single page / spread that the user pans + zooms.

### Layout model

Introduce `ReadingLayout` inside `MetalPageView`:

- `.verticalStack(pagesPerRow: 1)` — current vertical-scroll mode.
- `.verticalStack(pagesPerRow: 2)` — current vertical-double mode.
- `.singlePage` — one page, fits to viewport width by default, user zooms + pans with `NSScrollView.magnification`.
- `.doubleSpread` — two pages side-by-side (or one "natural spread" full-width if `ComicPage.isSpread`), same zoom/pan model.

`MetalPageView`'s coordinator keeps its existing `pages`, `pagePositions`, `pageYOffsets`, `sequentialToID` fields. `rebuildLayout()` branches on `ReadingLayout`:

- `.verticalStack`: existing top-to-bottom positioning unchanged.
- `.singlePage`: produces exactly **one** page rect for the active `currentPage`. Document bounds = the page rect's size. `pageYOffsets` has one entry.
- `.doubleSpread`: produces one or two page rects (spread or pair) for `currentPage` + optionally `currentPage + 1`. Document bounds = the combined rect. `pageYOffsets` has one entry per page (shared Y).

Navigation (next/prev page) in single/double modes triggers `coordinator.rebuildForCurrentPage(newPage: …)` — a new method that recomputes `pagePositions` for the new page and resets the scroll view to fit the new document. Zoom/pan state is preserved or reset per user's reading-mode convention (see *Zoom/pan lifecycle* below).

### NSScrollView configuration per mode

`.verticalStack`:
- `hasVerticalScroller = true`, `hasHorizontalScroller = false`, `scrollView.autohidesScrollers = true` (unchanged from today).
- `allowsMagnification = true`, `minMagnification = 0.1`, `maxMagnification = 8.0` (unchanged).

`.singlePage` / `.doubleSpread`:
- `hasVerticalScroller = true`, `hasHorizontalScroller = true`, `autohidesScrollers = true` — a zoomed-in page is pannable both axes.
- `allowsMagnification = true`, `minMagnification = 0.25`, `maxMagnification = 8.0` — min 0.25 so the user can zoom out past fit-to-viewport for overview (matches current `ZoomableImageView` range implied by `ReaderViewModel.minScale`).
- On `rebuildLayout` completion, call `scrollView.magnifyToFit()` equivalent — programmatic fit-to-width by setting `magnification` from the page's natural AR vs the viewport's.

### Zoom/pan lifecycle

Today: `ReaderViewModel.scale` + `.offset` are shared across reading modes — a user who zooms in single-page mode and switches to double sees the same scale. That's a footgun (a spread is twice as wide, so the same scale crops the first half). Step A honours the existing behaviour but **documents** that zoom state is shared. If future work wants per-mode zoom state, that's a follow-up.

Concrete mapping:
- `vm.scale` → `scrollView.magnification`. Bidirectional: pinch updates `magnification` → notification → `vm.setScaleFromScrollView(_:)`; toolbar zoom-in/out → `scrollView.animator().magnification = …`. Already works for vertical modes; extends trivially to single/double.
- `vm.offset` → `scrollView.contentView.scroll(to:)`. Pan is handled by NSScrollView natively when the user drags or uses the scrollers. For programmatic recentre (e.g. double-tap `fitToWidth`), call `scrollView.animator().magnification = 1.0; scrollView.contentView.animator().scroll(to: .zero)`.

**Behaviour change: pan clamping.** `ZoomableImageView` today clamps pan to half-overhang (image never fully leaves the viewport). NSScrollView clamps pan to edge (content edge never leaves the viewport past the far side). Step A accepts this change — it matches macOS conventions and every other zoom-pan app the user is familiar with (Preview, Books). The removal of `clampedOffset` is intentional.

### Gestures

| Gesture | Today (single/double) | After step A |
|---|---|---|
| Pinch zoom | `MagnifyGesture` → `vm.scale` binding | `NSScrollView.magnification` (trackpad pinch → magnification notification → VM) |
| Scroll-wheel zoom | Custom `onScrollWheel` → `vm.scale` binding | NSScrollView eats scroll-wheel events at magnifications > 1 (for pan) — we bind ⌘+scroll for zoom via an `NSEvent.addLocalMonitorForEvents(.scrollWheel)` similar to the loupe monitor |
| Left-click drag | `MouseCatcher` → loupe | `NSEvent` local monitor → loupe (same pattern as vertical modes) |
| Right-click drag | `MouseCatcher` → pan | NSScrollView's natural drag-to-pan (NSScrollView handles this for free when `hasHorizontalScroller`/`hasVerticalScroller` are on) |
| Double-tap | SwiftUI `TapGesture(count: 2)` above the view | Handled by the view's Coordinator via `NSClickGestureRecognizer` or `NSEvent` monitor tracking clicks. Double-click on body toggles `resetZoom()` ↔ `fitToWidth()` |
| Keyboard arrows / WASD | `KeyMonitor` (already global) | Unchanged |
| Q / E (prev/next comic) | Same | Unchanged |

`NSScrollView` captures left-mouse drag for its own native scroll-to-pan, but only when `hasScroller`/`horizontalScroller` are enabled. We keep those enabled but `autohidesScrollers = true` so the chrome stays clean. Pan via scroller-drag + trackpad-scroll are both free; single-finger click-drag pan is what the `NSScrollView` natively binds.

### Loupe — unified path

Single-path implementation:

1. `NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])` in `MetalPageView.Coordinator.installLoupeMonitor()` (already exists for vertical).
2. Event arrives → compute `docPt` from `documentView.convert(windowPt, from: nil)` (works for any layout because `documentView` is `MetalCanvasView`).
3. `findSequentialIndex(at: docPt)` returns the page under cursor (handles single, spread, double-page, and vertical-multi-page all the same way because it's just a binary search over `pageYOffsets` + horizontal bounds check).
4. Fetch NSImage via `pageManager.nsImage(for: seqIdx)` (step B's shared API).
5. Host `MagnifierView` in a child `NSPanel` (existing code).

The Coordinator already does all of this for vertical modes. Step A's contribution is simply: use the same coordinator for single/double modes, and stop constructing the SwiftUI Canvas loupe.

### Coordinate-system concerns

`MetalCanvasView.isFlipped = true` (document-space top-origin). The vertex shader (Shaders.metal) projects doc-space page rects into NDC relative to `scrollOriginY` (the viewport's top in doc coords). Works for any layout — single-page just has `scrollOriginY = scrollView.contentView.bounds.origin.y`, which is 0 when the page fits, non-zero when zoomed in and panned. **No shader changes needed.**

### Back-pressure: prefetch

Vertical mode's `triggerPrefetch(first:last:)` decodes `[first - 3 … last + 3]` as the visible range slides. Single-page mode doesn't "slide" — it snaps from page N to page N+1. Behaviour:
- Single-page `.singlePage`: on `rebuildForCurrentPage(newPage:)`, call `pageManager.prefetch(around: newPage, pages: pages)` which uses the step-B `[center-1 … center+3]` window. That's 5 pages prefetched per page turn, same as today.
- Double-page `.doubleSpread`: call the same prefetch with the spread's leading page as centre.

No new prefetch logic. We reuse `MetalPageManager.prefetch(around:pages:)` (introduced in step B commit `2fc7346`) — that's the whole point of step B.

## Component contracts

### `MetalPageView`

New initializer parameter:

```swift
enum ReadingLayout {
    case verticalStack(pagesPerRow: Int)
    case singlePage
    case doubleSpread
}

let layout: ReadingLayout
```

Keep `pagesPerRow: Int` as a convenience property computed from `layout` for backward compatibility during migration, delete afterward.

### `MetalPageView.Coordinator`

- New method: `func rebuildForCurrentPage(newPage: Int)` — in `.singlePage` / `.doubleSpread`, updates `pagePositions` / `pageYOffsets` / `sequentialToID` for the newly-active page, resets `scrollView.magnification` (optional) and `scrollView.contentView.bounds.origin` to zero, triggers `render(visibleRange:)`, triggers prefetch.
- `rebuildLayout()` branches on `layout`. The vertical-stack branch is untouched. New `.singlePage` / `.doubleSpread` branches compute a one-page or two-page document.
- `updateVisibleRange()` in `.singlePage` / `.doubleSpread` always produces `visibleRange = 0 ... (pages.count - 1)` for the tiny 1–2-page document — we render every page in the document because it's already only 1–2 pages.

### `ReaderView`

- `singlePageView(containerSize:)` becomes a thin wrapper around `MetalPageView(layout: .singlePage, …)`.
- `doublePageView(containerSize:)` becomes `MetalPageView(layout: .doubleSpread, …)`.
- The `TapGesture(count: 2)` attached above is replaced by a click-detector inside `MetalPageView.Coordinator` (toggle fit-to-width ↔ reset).
- `vm.currentPage` changes → call `coordinator.rebuildForCurrentPage(newPage: vm.currentPage)` via an `updateNSView` hook.

### `ReaderViewModel`

Unchanged API surface. `currentImage` / `image(for:)` / `triggerPrefetch` stay — they're still used by anyone who asks the VM for a decoded image (the loupe's fast-path, potentially code outside the reader).

- `scale` / `offset` / `setScaleFromScrollView(_:)` are reused — NSScrollView drives them.
- `fitToWidth(containerWidth:)` / `zoomToActualSize()` / `resetZoom()` are retained but reimplemented to set `scrollView.magnification` (via a delegate / binding exposed by `MetalPageView`) instead of updating SwiftUI `.scaleEffect`.

### Deletions (at end of step A)

- `ZoomableImageView.swift` entirely.
- `SpreadView` struct from `ReaderView.swift`.
- `MouseCatcher` + `_MouseCatcherView` (in `ZoomableImageView.swift`).
- `ScrollWheelModifier` + `ScrollWheelView` + `_SWView` (in `ZoomableImageView.swift`).
- `ReaderViewModel.setScaleFromScrollView` stays (vertical modes still use it); extend to be called by single/double modes too.

## Implementation phases

**Phase A-1 — single-page mode.**

1. Add `ReadingLayout` enum + `layout` parameter to `MetalPageView`. Default to `.verticalStack(pagesPerRow: pagesPerRow)` from the current `pagesPerRow` param for backward compat.
2. Add `Coordinator.rebuildForCurrentPage(newPage:)`.
3. Extend `Coordinator.rebuildLayout()` with a `.singlePage` branch.
4. Update `ReaderView.singlePageView(…)` to construct `MetalPageView(layout: .singlePage, …)` behind a feature flag or a new branch in `modeContent` switch.
5. Wire `currentPage` changes to `rebuildForCurrentPage`.
6. Wire `vm.scale` ← → `NSScrollView.magnification` (extend existing vertical wiring).
7. Verify: build clean, launch, single-page mode renders via Metal, pinch/zoom/pan work, navigation works.

**Phase A-2 — double-page mode.**

1. Extend `Coordinator.rebuildLayout()` with a `.doubleSpread` branch (handles `leftIsSpread`).
2. Update `ReaderView.doublePageView(…)` to construct `MetalPageView(layout: .doubleSpread, …)`.
3. Re-wire `currentPage` changes: double-page advances by 2 when the left page isn't a spread, 1 when it is — already handled by `ReaderViewModel.nextPage()`.
4. Verify.

**Phase A-3 — delete legacy.**

1. Delete `ZoomableImageView.swift`.
2. Remove `SpreadView` from `ReaderView.swift`.
3. Remove any unreferenced helpers in `ReaderViewModel` (if any).
4. Trim the `pagesPerRow` convenience once the `layout` param is everywhere.
5. Update CHANGELOG with v0.10.0.

Phases A-1 and A-2 commit separately; A-3 is its own cleanup commit. Each phase ends at a green build + manual verification gate.

## Risks and mitigations

**Pan clamping change** — today: half-overhang; after: edge clamp. Behaviour change is intentional. If users complain, we can implement a custom NSClipView subclass to restore half-overhang, but default native behaviour is the preferred state.

**Mode-switch zoom preservation** — `vm.scale` is shared across single/double/vertical modes. Switching from a zoomed single-page into vertical-double at the same scale may render oddly. This already happens today with SwiftUI `.scaleEffect`, so we're not making it worse. Fix is deferred (per-mode zoom state).

**Scroll-wheel zoom** — NSScrollView consumes scroll events for pan when scrollers are enabled. ⌘+scroll-wheel for zoom requires a local `NSEvent` monitor that intercepts and routes to `scrollView.magnifyToSmooth(delta)` or sets magnification directly. We add this monitor alongside the loupe monitor — similar code shape.

**Double-tap detection on NSView** — SwiftUI's `TapGesture(count: 2)` is replaced. Options: `NSClickGestureRecognizer(numberOfClicksRequired: 2)` attached to the `MetalCanvasView`, or the `NSEvent.mouseDown` handler tracking click timestamps. The gesture recognizer is cleaner.

**SwiftUI rebuild triggers on `vm.currentPage` change** — today SwiftUI reacts to `@Published` changes and re-renders. `updateNSView` on `MetalPageView` doesn't naturally know about `currentPage`. We thread `currentPage` in through the `MetalPageView` struct's `let` parameters; SwiftUI `updateNSView` compares current vs previous and calls `rebuildForCurrentPage` when it changes. This pattern already works for `pagesPerRow` and `scale` in vertical modes.

**Loupe panel not dismissing on page turn** — if a user left-click-holds the loupe AND presses next-page, the loupe shows stale content briefly while the new page decodes. Mitigation: on `rebuildForCurrentPage`, call `coordinator.hideLoupe()` to force-dismiss. Cheap.

**Memory** — unchanged. `MetalPageManager` already caps at 10 CVPixelBuffers + 10 NSImages. `TextureRingBuffer` caps at 10 MTLTextures. Single/double modes only ever reference 1–2 of those, so they're within budget by a huge margin.

**Reader-open → reader-closed cycles** — today, opening and closing a comic creates/destroys the SwiftUI `ReaderView`. Each cycle creates a new `ReaderViewModel` and its own `MetalPageManager`. That's also fine. After step A, the same lifecycle applies; no long-lived state.

## Testing / verification

Project has no unit-test harness. Per-phase smoke tests:

**Phase A-1 verification:**
1. `swift build -c release` clean.
2. `./build_app.sh` produces a `.app`.
3. Open CBZ → single-page mode → first page renders.
4. Pinch-zoom on trackpad → page scales smoothly.
5. Scroll-wheel (no modifier) pans when zoomed; ⌘+scroll zooms.
6. Double-click → toggles fit-to-width ↔ reset.
7. Arrow keys / WASD advance pages — rebuild triggers, new page renders.
8. Q / E switch comics — new page renders.
9. Left-click-hold loupe works; cursor hidden; tracks cursor; releases correctly.
10. Switch to double-page (mode switch UX unchanged). Verify old `SpreadView` still handles it (phase A-2 replaces this).
11. Open CBR → single-page renders (regression anchor for v0.8.2's per-source decode fix).
12. Open PDF → single-page renders with white background.
13. RSS stable after flipping through 20+ pages.

**Phase A-2 verification:**
1. All of A-1 above, still passing.
2. Double-page mode renders via Metal. Two pages side-by-side.
3. A natural spread page (isSpread) renders full-width.
4. Loupe works on both halves of a spread.
5. Pinch-zoom the whole spread.
6. Advance two pages via arrow keys; spread shifts.

**Phase A-3 verification:**
1. `grep -r "ZoomableImageView\|SpreadView\|MouseCatcher\|ScrollWheelView" Sources/ --include="*.swift"` returns only the deletion result (no residual references).
2. Build clean.
3. Re-run all phase A-1 and A-2 smoke tests.

## Non-goals

- Per-mode zoom state (today is shared; that's unchanged).
- New reading modes or new zoom/pan features.
- Refactoring `MetalPageManager` further — it's stable after step B.
- Refactoring the shader — it already handles document-space projection correctly.
- Touching the library view.

## Rollback

If phase A-1 breaks, revert the single commit and `swift build -c release && ./build_app.sh`. If phase A-2 breaks, revert the A-2 commit(s). Full rollback to pre-step-A state:

```
rsync -a --delete --exclude='.build/' \
  /Volumes/Media/DC_dev_lib_backup_20260424_001822/ \
  /Volumes/Media/DC_dev_lib/
cd /Volumes/Media/DC_dev_lib && swift build -c release && ./build_app.sh
```

## Deferred follow-ups

- **Per-mode zoom state**: `vm.scale` shared across modes is a usability footgun, worth a focused design session.
- **Stale doc comments**: `Sources/DC/Models/Comic.swift:13` and `Sources/DC/ViewModels/MetalPageManager.swift:20` reference the retired `PageImageCache`. Trim during step A-3 if convenient.
- **Half-overhang pan**: if users miss the old clamp, a custom NSClipView can restore it.
