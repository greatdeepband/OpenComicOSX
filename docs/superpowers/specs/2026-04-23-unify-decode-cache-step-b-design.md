# Unify Reader Decode Cache (Step B) — Design

**Date:** 2026-04-23
**Scope:** Retire `PageImageCache`. Route single-page and double-page reading modes through `MetalPageManager` so there is one shared decode cache across all four reading modes.
**Predecessor:** v0.8.3 (backup at `/Volumes/Media/DC_dev_lib_backup_20260423_234635`).
**Successor:** Step A (future session) — replace `ZoomableImageView` with a Metal-rendered single/double page view.

## Goal

Eliminate the two-cache reality (NSImage cache for single/double + CVPixelBuffer cache for vertical) and land a single decode pipeline that serves every reading mode.

**Out of scope for this step.** Rendering. `ZoomableImageView` keeps using SwiftUI `Image(nsImage:)` for display; only the **source** of the NSImage changes.

## Current architecture

### Decode caches (two, parallel)

**`PageImageCache`** (`ReaderViewModel.swift`) — actor with an `NSCache<NSNumber, NSImage>`. Serves single + double page.
- `image(for: Int) -> NSImage?` — nonisolated fast path.
- `prefetch(around: Int, pages: [ComicPage])` — kicks decoding in `[center - 1 … center + 3]`, evicts outside.
- `prefetch(visible: ClosedRange<Int>, lookahead: Int, pages: [ComicPage])` — viewport-aware variant (legacy vertical API).
- `onPageReady(Int, NSImage)` callback — fires on `@MainActor` after each decode.
- `onPageReadySwiftUI(Int, NSImage)` callback — the hook `ReaderViewModel` uses to bump `cacheVersion` so SwiftUI re-renders.

**`MetalPageManager`** (`ViewModels/MetalPageManager.swift`) — actor with a `[Int: CVPixelBuffer]` dict + `lastAccessTimes`, 10-page LRU. Serves vertical + vertical-double.
- `decodePage(pageIndex:from: PageSource) async -> CVPixelBuffer?` — decodes every `PageSource` variant (v0.8.2 fixed CBR/CB7/CBT/PDF coverage).
- `page(for: Int) -> CVPixelBuffer?` — touches LRU.
- `evictOutside(_: ClosedRange<Int>)`, `isPending(_: Int)`.
- No notification hooks — the `MetalPageView.Coordinator` polls on scroll + render-on-upload via its own `prefetchTask`.

### Reader consumption sites

- `ReaderViewModel.currentImage: NSImage?` — reads `imageCache.image(for: currentPage)`.
- `ReaderViewModel.image(for index: Int) -> NSImage?` — reads `imageCache.image(for: index)`.
- `ReaderView.singlePageView` — reads `vm.cacheVersion` + `vm.currentImage`, hands NSImage to `ZoomableImageView`.
- `ReaderView.doublePageView` — reads `vm.cacheVersion` + `vm.currentImage` + `vm.image(for: currentPage + 1)`, hands both NSImages to `SpreadView`.
- `MetalPageView(imageCache: vm.imageCache, …)` — passed in but only used by the vertical-mode loupe (fast-path cache check before the CVPixelBuffer convert).

### Existing CVPixelBuffer → NSImage converter

`MetalPageView.Coordinator.nsImage(from: CVPixelBuffer)` (nonisolated static, in `MetalPageView.swift`) — locks the buffer, wraps it in a `CGContext`, makes a `CGImage`, returns `NSImage(cgImage:size:)`. Already battle-tested by the loupe. Cost roughly 5–20 ms for a 1500×2300 page.

## Target architecture

### Single decode source

`MetalPageManager` becomes the sole decoded-image supplier. It gains:

1. **An NSImage view on top of the CVPixelBuffer cache.** A parallel nonisolated `NSCache<NSNumber, NSImage>` keyed by page index. Populated lazily on first `nsImage(for:)` call; evicted when the corresponding CVPixelBuffer is evicted from the 10-page LRU. Cap: 10 entries (countLimit). This is the value-add — callers don't re-convert on every SwiftUI render pass.
2. **Synchronous fast-path read.** `nonisolated func nsImage(for: Int) -> NSImage?` — O(1) NSCache lookup, returns whatever's been decoded so far. Matches `PageImageCache.image(for:)`'s signature. The actor's CVPixelBuffer dict stays authoritative; the NSImage cache is a derived view.
3. **Prefetch API mirroring `PageImageCache`.** `nonisolated func prefetch(around center: Int, pages: [ComicPage])` kicks decoding for `[center - 1 … center + 3]` on the actor, populates both the CVPixelBuffer cache and the NSImage cache, fires callbacks.
4. **Callback hooks.** `nonisolated(unsafe) var onPageReadyNSImage: ((Int, NSImage) -> Void)?`. Fires on `@MainActor` after a decode + NSImage conversion completes. ReaderViewModel uses this to bump `cacheVersion`, identical to today's `onPageReadySwiftUI` wiring.

### Reader consumption (unchanged public behaviour)

- `ReaderViewModel.currentImage` reads `pageManager.nsImage(for: currentPage)`.
- `ReaderViewModel.image(for:)` reads `pageManager.nsImage(for: index)`.
- `ReaderViewModel.triggerPrefetch()` calls `pageManager.prefetch(around: currentPage, pages: comic.pages)`.
- `cacheVersion` + its SwiftUI dependencies in `singlePageView` / `doublePageView` unchanged.
- `MetalPageView(…)` stops taking `imageCache:`; the loupe fast-path inside its coordinator uses `pageManager.nsImage(for:)` directly — simpler than today's two-cache fallback chain.

### Eviction coupling

When the actor evicts a CVPixelBuffer (LRU, 10-entry cap), it also evicts the NSImage from the parallel NSCache via `removeObject(forKey:)`. No two-source-of-truth drift. NSCache's own countLimit = 10 catches any edge case where the couplings diverge.

### Memory math

Before: up to 15 pages in memory (`PageImageCache` 5-page window + `MetalPageManager` 10-page CVPixelBuffer ring).

After: 10 CVPixelBuffers + **at most** 10 NSImages backed by the same decoded pixel data via `CGImage` wrapping. The CGImage returned by `CGContext.makeImage()` owns a copy of the pixel bytes, so yes, the NSImage is a second copy — but it's the *one and only* NSImage copy (the old `PageImageCache` held 5 of them independently of the Metal path). Net: 10 pixel buffers + 10 NSImages ≈ 10 × 2 = ~20 page-equivalents max, slightly up from today's 15 but with a hard cap and consistent across all modes. No surprise 5+10 = 15-ceiling behaviour when the user switches modes.

If post-ship measurement shows memory pressure, downgrade to on-demand conversion with a 3-entry NSImage LRU (center + two neighbours). Defer this decision until we measure.

## Component contracts

### `MetalPageManager` additions

```
nonisolated func nsImage(for: Int) -> NSImage?
// O(1). Returns the already-converted NSImage if present. nil otherwise.

nonisolated func prefetch(around center: Int, pages: [ComicPage])
// Fire-and-forget. Schedules decodes for [center-1 ... center+3], then calls
// `evictOutside(…)` on that closed range. On each successful decode+convert,
// fires onPageReadyNSImage on the main actor.

// (existing) evictOutside(_ range: ClosedRange<Int>)
//   — unchanged; now also drops the NSImage from the NSCache when it drops
//     the CVPixelBuffer, keeping the two-layer cache coherent.

nonisolated(unsafe) var onPageReadyNSImage: ((Int, NSImage) -> Void)?
```

### `ReaderViewModel` changes

- `let imageCache = PageImageCache()` → replaced by a reference to the same `MetalPageManager` used by `MetalPageView`. Created once per `ReaderViewModel` session; injected into `MetalPageView` via the existing initializer.
- `currentImage` and `image(for:)` body unchanged shape — just swap the cache.
- Prefetch triggers swap to the new API.
- The `imageCache.onPageReady` / `onPageReadySwiftUI` wiring is replaced by a single `onPageReadyNSImage` handler that bumps `cacheVersion`.

### `MetalPageView` changes

- Drop the `imageCache: PageImageCache?` parameter. The coordinator already owns a `pageManager` internally; use that for loupe lookups.
- The coordinator's loupe fast-path becomes: `if let img = pageManager.nsImage(for: seqIdx) { show }`, else the existing async-decode fallback.

### `PageImageCache` removal

- Entire actor class deleted from `ReaderViewModel.swift`.
- `LibraryViewModel` reference removed if any (there was `vm.imageCache` pass-through — verify).

## Risks and guards

**Memory** — doubles NSImage count in cache compared to single-cache-of-5 days. Mitigation: NSCache autoevicts under pressure; 10-entry cap; fall back to 3-entry LRU if measurement warrants.

**Double decode** — the convert from CVPixelBuffer to NSImage copies bytes. If it fires on the SwiftUI render path (fast-path cache miss), there's a 5–20 ms stall. Guard: `nsImage(for:)` must never block on convert — it returns nil if not already cached and lets the next `onPageReadyNSImage` callback trigger a re-render. Convert happens on the decode Task (background), then dispatches callback to main.

**Race on mode switch** — user switches from single-page to vertical mid-session; vertical's `MetalPageView.Coordinator` has its own prefetch loop that may race with `ReaderViewModel`'s. Guard: both end up populating the same actor's cache; no corruption, just some redundant decode starts (skipped by existing `pendingPages` dedup). Acceptable.

**Removal of `onPageReady`** — today `PageImageCache` has TWO callbacks (`onPageReady` for direct NSView injection by the now-defunct `VerticalComicScrollView`, and `onPageReadySwiftUI` for SwiftUI refresh). Only `onPageReadySwiftUI` is alive post-v0.4.0. We remove both during migration; collapse to `onPageReadyNSImage`.

**`cacheVersion` granularity** — today `onPageReadySwiftUI` bumps cacheVersion for every decoded page, even far-off lookahead. That triggers a full `singlePageView` re-render for pages the user isn't viewing. Guard: filter in the callback — only bump `cacheVersion` when `index == currentPage || index == currentPage + 1` (double-page's second slot).

**Gallery-open regression** — thumbnail loader uses `LibraryViewModel.thumbnailCache`, distinct from `PageImageCache` and `MetalPageManager`. Untouched. Sanity check: grep for `PageImageCache` call sites shows only `ReaderViewModel` and `MetalPageView`.

**Backup** — `/Volumes/Media/DC_dev_lib_backup_20260423_234635/` is the rollback point. Revert via the rsync-plus-rebuild recipe in the CHANGELOG's Unreleased entry.

## Testing / verification

1. `swift build -c release` clean (no new warnings beyond the pre-existing Swift 6 concurrency list).
2. `./build_app.sh` produces a `.app` that launches.
3. Open a **CBZ** in single-page mode → first page appears within 100 ms; next → prev works; double-page flip works.
4. Open a **CBR** in single-page mode → same smoke test (CBR uses `.file` source — MetalPageManager handles it per v0.8.2).
5. Open a **PDF** in single-page mode → white background shows, pages render, no transparency artifact.
6. Switch between **single → vertical → single** during a session → pages remain decoded, no duplicate decode storms, `/tmp/dc_debug.log` clean.
7. Loupe works in all four modes.
8. Memory: open a ~100-page CBZ, scroll through all pages in vertical, switch to single-page, flip through a few pages → RSS should stabilise at pre-change levels (no runaway growth from double-cached NSImages).

## Non-goals / deferred

- Replacing `ZoomableImageView` with a Metal-rendered view — that's step A.
- Changing the prefetch window shape (`[center-1 … center+3]`). Keep it.
- Changing the 10-page cap. Keep it.
- Changing gesture behaviour (zoom, pan, loupe activation). None touched.
- Refactoring `MetalPageView`'s own prefetch pipeline. Left alone.

## Rollback plan

If the change bricks the reader:

```
rsync -a --delete --exclude='.build/' \
  /Volumes/Media/DC_dev_lib_backup_20260423_234635/ \
  /Volumes/Media/DC_dev_lib/
cd /Volumes/Media/DC_dev_lib && swift build -c release && ./build_app.sh
```

Should restore v0.8.3 binaries byte-identically.
