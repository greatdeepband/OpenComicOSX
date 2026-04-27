# Workspace

## Current task
**v0.10.3 shipped.** Loupe behaviour restored to pre-Metal `ZoomableImageView` feel across all four reading modes — sticky `loupeActivePage` so the loupe never disappears mid-drag, raw cursor coords (no clamping), `MagnifierView` Canvas paints solid black before the visible-rect guard so off-page cursors render as a black circle instead of a transparent ring. CHANGELOG + README updated.

## What shipped in v0.10.3 (2026-04-27)
- `MetalPageView.Coordinator.loupeActivePage: Int?` added; sticky across cursor excursions into row/column gaps and side/top margins.
- `MetalPageView+Loupe.swift:updateLoupe` — falls back to `loupeActivePage` when `findSequentialIndex` returns `-1`; only emits `nil` to the SwiftUI overlay when there are no pages at all (no mid-drag hides). Initial fallback (no active page yet) uses `currentPage` for `.singlePage`/`.doubleSpread` and `lastVisibleRange.lowerBound` for `.verticalStack`.
- `MetalPageView+Loupe.swift:hideLoupe` — resets `loupeActivePage = nil` in lockstep with `loupeImage` and the cursor-restore.
- `MagnifierView.loupeContent` — black-fill moved out of the visible-rect guard; the Canvas always paints opaque black before attempting any image draw.
- Diagnosed live via per-event DCLogger instrumentation (`[loupe-evt] / [loupe-upd] / [loupe-emit] / [loupe-canvas]`); root cause was `srcRect.intersection(ivBounds)` becoming null once `cursorInImage.x < -halfW` (≈ -186pt). Instrumentation removed before final build.

## What shipped in v0.10.0 (2026-04-25)

## What shipped in v0.10.0 (2026-04-25)
- All four reading modes now route through `MetalPageView`.
- `SpreadView`, `ZoomableImageView`, `MouseCatcher`, `ScrollWheelModifier`, and `View.onScrollWheel` deleted.
- `ReaderViewModel` cleaned: `currentImage`, `image(for:)`, `cacheVersion`, `offset`, and `pageManager.onPageReadyNSImage` callback removed (the SwiftUI Image rendering plumbing is no longer needed).
- Mode-switch fixes: `prefetchInFlightRange` dedupe, 3-stage render retry, `magnification` reset on layout change, `layoutSubtreeIfNeeded` after `rebuildLayout`, scroll-position restore via `restoreOffset`/`restorePage` in `updateNSView`.
- Loupe rewritten to a SwiftUI overlay (`LoupeOverlayState` + `onLoupeOverlay` callback), naturally clipped by ZStack bounds.
- Top-bar bleed fixed (carve `topInset` from `visible` before intersecting `docFrame`).
- Shader uniforms now use `metalLayer.frame` directly (added `viewportOriginX`).

## Known limitations to revisit if needed
- The 3-stage render retry on layout change (1ms / 50ms / 150ms) is a pragmatic workaround for a CAMetalLayer drawable-rotation race. Principled alternative: `CAMetalLayer.presentsWithTransaction = true`. Try if the retry approach ever feels janky.
- SwiftUI reuses the Coordinator across mode switches (same struct type at same view-tree position). State that should reset on mode change must be reset explicitly in `updateNSView` (we do this for `magnification`, scroll position, etc.).

## Files touched in 2026-04-25 session (full scope)
- `Sources/DC/Views/MetalPageView.swift` — major; phases A-1/A-2 + many follow-up fixes.
- `Sources/DC/Views/MetalPageRenderer.swift` — uniforms now `(originX, originY, width, height)`.
- `Sources/DC/Shaders.metal` — `viewportOriginX` added; `viewX` subtracts it.
- `Sources/DC/Views/ReaderView.swift` — `metalLoupe @State`, all four modes Metal, SpreadView struct deleted.
- `Sources/DC/ViewModels/ReaderViewModel.swift` — dead Image-rendering plumbing removed.
- `Sources/DC/Views/ZoomableImageView.swift` — deleted.
- `CHANGELOG.md` — consolidated five "Unreleased" entries into v0.10.0.
- `README.md` — updated to reflect Metal-everywhere architecture.

## Next step
Decide whether to commit + tag v0.10.0, or hold for additional polish (loupe edge cases, the brief render-retry burst that fires on every mode switch, etc.).

## v0.10.1 shipped (2026-04-25)
- **Single-page off-centre after switching from double-page** — fixed via doc-padding in `rebuildSinglePage` / `rebuildDoubleSpread`. Pad documentView to `max(scaledSize, usableViewport)`, place pageRect centred within the doc. NSClipView no longer needs to accept negative bounds origins. Centring block in `updateNSView` simplified to a single non-negative scroll-origin computation.
- **Vertical-single ↔ vertical-double scroll-position jump** — fixed by tracking `vm.scrollOffsetPagesPerRow` alongside `scrollOffsetFraction`. When the count differs from the current vertical mode, fall through to page-based restore (a fraction saved against one doc height is meaningless against another).
- Diagnostic SWITCH-tagged DCLogger calls added during debugging — removed before final build.

## v0.10.2 shipped (2026-04-25)
- **Named constants** — new `Sources/DC/ReaderConstants.swift` gathers every previously-bare numeric constant (top-bar height, page gap, spread gutter, magnification range, wheel-zoom step + clamp, scale epsilon, aspect-ratio floor, render-retry delays, initial-render retry budget, Metal max-texture-dim, prefetch lookahead). Each value carries the *why*. Replaces ~15 magic numbers across MetalPageView, ReaderView, ReaderViewModel.
- **MetalPageView file split** — 1500-line monolith carved into MetalPageView.swift (NSViewRepresentable + MetalCanvasView + Coordinator class declaration), MetalPageView+Layout.swift (rebuild/scroll/visible-range/recentre/hit-test), +Render.swift (render/prefetch), +Loupe.swift (loupe monitor/updateLoupe), +Zoom.swift (wheel/double-click/pinch). Coordinator stored properties bumped from private to internal so sibling extensions can reach them; encapsulation otherwise unchanged.
- Hard-backup of pre-refactor v0.10.1: `/Volumes/Media/DC_dev_lib_backups/DC_dev_lib_v0.10.1_2026-04-25_1938.tar.gz` (147 MB, sha256 16d6f37d640a776ac75f34296d3133c93c62ab8611e3014d711d4aa6e5867e18).
