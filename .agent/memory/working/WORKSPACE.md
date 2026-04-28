# Workspace

## Current task
**v0.11.1 shipped.** Gallery thumbnail refresh decoupled from `@Published` — `PassthroughSubject<URL, Never>` replaces the dual-assignment `updatedThumbnailURLs` Set. Per-URL invalidation only; no full-grid re-render on cache writes. CHANGELOG + README updated.

## What shipped in v0.11.1 (2026-04-28)
- `LibraryViewModel.thumbnailUpdates = PassthroughSubject<URL, Never>()` added; `insertIntoCache`, `saveThumbnailAndCache`, and the visible branch of `generateThumbnailsParallel` send per-URL events.
- `ComicCard` and `ContinueReadingHero` subscribe via `.onReceive(library.thumbnailUpdates)` instead of `.onChange(of: library.updatedThumbnailURLs)`.
- Removed: `@Published updatedThumbnailURLs`, `pendingURLs`, `flushScheduled`, `scheduleFlush()`, `flushThumbnailGeneration()`, and the `updatedThumbnailURLs.remove(url)` workaround in `closeComic`.
- Diagnosed via live `[gthumb]` event log at 2026-04-28 11:15:43–11:16:46 (cache warmed from 25 to 1210 entries; 20+ `render NIL` per flush across uninvolved cards). Instrumentation removed before final build.
- Code commit: `ed15f53 fix(library): decouple per-card thumbnail refresh from @Published`.

## What shipped in v0.11.0 (2026-04-28)
- New `Sources/DC/Views/ReaderToolbar.swift` (~250 lines): top-level `ReaderToolbar` view + private `ToolbarCapsule` (availability-gated `.glassEffect` / `.ultraThinMaterial` wrapper) + `SegmentDivider` + `LeadingCapsule` / `TransportCapsule` / `TrailingCapsule`. macOS 26+ uses real Liquid Glass inside one `GlassEffectContainer`; macOS 14–25 collapses the container to a `Group` and renders each capsule independently with `.ultraThinMaterial`.
- `ReaderConstants`: `topBarHeight 38 → 52`, plus two new tunables `toolbarCapsuleHeight = 36` and `toolbarSegmentDividerOpacity = 0.12`.
- `ReaderView.readerTopBar` reduced from a 116-line inline ZStack to a one-line call site. Inline `backButton` / `transportCluster` / `trailingCluster` deleted. `TitlebarEffectView` struct + its `.background()` on the strip both removed — the strip is fully transparent now.
- `ReaderView` body gains `.ignoresSafeArea(.container, edges: .top)` and `.background(FullSizeTitleBarConfigurator())` so the title-bar area is transparent and the toolbar overlays the traffic-light row in one unified strip.
- `FullSizeTitleBarConfigurator` re-asserts `window.standardWindowButton(...)?.isHidden = false` for close / miniaturize / zoom — `.windowStyle(.hiddenTitleBar)` was hiding the traffic lights on macOS 26 until the user hovered.
- `DCApp.swift`: removed `.windowStyle(.hiddenTitleBar)`. Default `.windowStyle(.titleBar)` keeps the controls visible always; the configurator handles transparency.
- `MetalPageView.Coordinator`: added `loupeDragActive: Bool` so the navbar's strip-skip only gates the INITIAL `.leftMouseDown`. Once a drag has started below the strip, all `.leftMouseDragged` events flow through regardless of cursor position — the loupe fades to black at the page top edge same as left/right/bottom.
- `MetalPageView+Loupe.swift:handleLoupeEvent`: top-strip guard rewritten — NSScrollView's effective coords here are top-origin (documentView `isFlipped = true` propagates through clipView), confirmed via per-event live debug. Strip is `[0, topBarHeight]`, not `[bounds.maxY - topBarHeight, bounds.maxY]`.
- Spec: `docs/superpowers/specs/2026-04-27-reader-liquid-glass-toolbar-design.md` (committed in `bfabf59`).

## What shipped in v0.10.3 (2026-04-27)

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
