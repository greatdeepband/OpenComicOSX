# DC Reader — Changelog

## v0.3.0 — 2026-04-17

### Option C: NSScrollView Native Magnification (Zoom Fix)

**Problem:** Scroll-wheel zoom was broken in vertical modes (NSScrollView ate the events), and toolbar zoom buttons triggered a full page-layout rebuild on every zoom step — expensive and caused visible flash.

**Fix:** Delegate zoom rendering to NSScrollView's native `magnification` system.

- `VerticalComicScrollView`: enable `allowsMagnification = true`, set `minMagnification = 0.1`, `maxMagnification = 8.0`
- `updateNSView`: when `scale` changes from toolbar/keyboard, call `scrollView.magnification = scale` — NSScrollView renders the zoom natively, no rebuild
- `Coordinator`: add `magnificationDidChange` handler for `NSScrollView.didEndLiveMagnifyNotification`; new `onMagnificationChanged` callback pushes pinch-zoom values back to ReaderViewModel so the toolbar stays in sync
- `ReaderViewModel`: add `setScaleFromScrollView(_:)` — updates `vm.scale` from NSScrollView without feedback loop

Result: scroll-wheel pinch-zoom now works natively; toolbar zoom is instant with no flash; zoom is genuinely global (all pages scale as one unit).

**fitToWidth fix (Double Page):** The method now checks `readingMode == .doublePage` first and sets `scale = 1.0` directly — because the spread always fills container width, so "fit to width" means no scaling. Previously it computed scale from the left page only, which was wrong when right page was wider.

### Architecture Changes (pre-existing)

**VerticalComicScrollView:** Replaced `FlippedStackView` + manual `NSLayoutConstraint`-based layout with `NSCollectionView` + custom `ComicFlowLayout`. Handles multi-column vertical and spread pages natively via layout attributes rather than constraint math.

**In-memory CBZ streaming:** `PageSource.zipData` variant holds compressed CBZ bytes in RAM; `CGImageSourceCreateIncremental` streams images without disk I/O.

**PageImageCache:** Added `removeObjectsOutside(lo:hi:)` for synchronous direct eviction during fast scroll sweeps — keeps RAM hard-capped at ~5 decoded pages.

---

### Changes

**1. Vertical scroll position restoration: async race condition fixed**
`VerticalComicScrollView.makeNSView` scheduled `applyPendingRestore()` via `DispatchQueue.main.async`. SwiftUI synchronously called `updateNSView` before the async block fired, which cleared `pendingRestorePage`/`pendingRestoreOffset` to nil — so the restore closure found nothing to restore.

Fix: the async closure now captures the pending values *at schedule time* and writes them back before calling `applyPendingRestore`. This ensures `updateNSView` cannot wipe them before the restore fires.

**2. DCLogger: lazy file handle initialization**
`DCLogger` required an explicit `truncate()` call before writing, which never happened at startup. All `Task { await DCLogger.shared.log(...) }` calls silently failed. Fix: `ensureHandle()` opens the file on first write, and the file is truncated on first write so each app run starts a fresh log.

**3. Vertical view image loading: removed stale-image guard**
`VerticalComicScrollView.syncInitialImages` had `guard v.image == nil` — preventing cached images from being pushed into newly created page views on rebuild. Images stayed blank until a manual scroll. Fix: guard removed, stale images are always replaced.

**4. Vertical view: page-number restore via binary search**
`applyPendingRestore()` now tries page-number restore first (binary search over the `pageYOffsets` table), falls back to scroll fraction. Page-number restore is mode-agnostic — 50% in single-page (1 page wide) ≠ 50% in vertical (52 pages stacked).

**5. Debug logging**
`DCLogger` calls added throughout the restoration pipeline: `ReaderView.onAppear`, `makeNSView`, `updateNSView` (needsRebuild reason), `applyPendingRestore`, `RESTORE applying saved page/fraction`, `syncInitialImages`, `scrollDidChange`.

---

## v0.2.0 — 2026-04-14

### Changes

**1. DCLogger: DispatchQueue → Swift actor**
`DCLogger` converted from a class with `DispatchQueue` to a Swift `actor`. All call sites updated from `DCLogger.shared.log(...)` to `Task { await DCLogger.shared.log(...) }` or `await DCLogger.shared.log(...)` in async contexts. Write failures now print to console instead of crashing silently.

**2. PageImageCache: NSLock → Swift actor**
`PageImageCache` (in `ReaderViewModel`) converted from `final class` with `NSLock`-guarded `inFlight` set to a Swift `actor`. Actor-isolated state, async decode methods, `nonisolated` NSCache reads for zero-cost fast path.

**3. Cache staleness: mtime → content-based manifest**
Cache validation for CBR/CB7/CBT now uses a `CacheManifest.json` file storing `entryCount` and `totalUncompressedSize` (from ZIP central directory, lsar JSON, or tar listing). On next open, manifest is loaded and compared against current archive metadata — avoids false positives from clock skew or cross-volume copies. CBZ uses streaming incremental decode and is not cached to disk.

**4. Homebrew packaging**
`unar` and `lsar` are now bundled inside the app at `Contents/Resources/bin/`. The app falls back to Homebrew paths if the bundled versions are unavailable.

---

## Memory Architecture Refactor — 2026-03-21

**Backup:** `DC_backup_20260321_220316` (full copy of pre-refactor source)

**Goal:** Replace the passive NSCache-reliant memory model with a deterministic sliding-window architecture. Hard-cap reader peak RAM at ~50 MB regardless of comic length.

---

### Change 1: Asymmetric Sliding Window with Explicit Eviction
**Files:** `Sources/DC/ViewModels/ReaderViewModel.swift`

- `PageImageCache.prefetch(around:pages:onReady:)` now uses an asymmetric window: `[center - 1 ... center + 3]` instead of the previous symmetric `[center - 5 ... center + 5]`.
- Added `PageImageCache.evictOutside(window:)` which explicitly calls `cache.removeObject(forKey:)` for every page outside the current window. This removes the dependency on `NSCache`'s opaque eviction policy.
- `ReaderViewModel.triggerPrefetch()` now calls `evictOutside` immediately after scheduling the prefetch, ensuring the in-memory page count never exceeds 5.
- `PageImageCache.countLimit` reduced from `windowSize * 2 = 20` to `8` (safety headroom above the 5-page window).

**Before:** Up to 20 pages (~460 MB) held in RAM indefinitely.
**After:** Maximum 5 pages (~50–115 MB) held at any time, hard-capped.

---

### Change 2: Screen-Resolution Downsampling
**Files:** `Sources/DC/Models/Comic.swift`

- `PageSource.decode()` for `.file` sources now uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize: 2048` instead of `NSImage(contentsOf:)`.
- This decodes the image at screen resolution during the decode step itself — the full-resolution bitmap is never loaded into RAM.
- A fallback to `NSImage(contentsOf:)` is retained for formats `CGImageSource` cannot thumbnail.
- PDF decode path is unchanged (PDFKit renders at 2× scale, which is already screen-appropriate).

**Before:** Each page decoded at full print resolution (1988×3056 = ~23 MB per page).
**After:** Each page decoded at max 2048px on the long axis (~10 MB per page).

---

### Change 3: O(1) View Injection — Direct NSView Updates
**Files:** `Sources/DC/Views/VerticalComicScrollView.swift`, `Sources/DC/ViewModels/ReaderViewModel.swift`

- Removed `@Published var cacheVersion: Int` from `ReaderViewModel`. This property was used as a blunt trigger to cause SwiftUI to call `updateNSView`, which then ran a full O(n) scan of all page views.
- `PageImageCache` now accepts an `onReady: (Int, NSImage) -> Void` callback that passes both the page index and the decoded image.
- `VerticalComicScrollView.Coordinator` maintains a dictionary `pageViewsByIndex: [Int: ComicPageView]`. When a page finishes decoding, the callback looks up the view directly and sets its `.image` property — O(1), no SwiftUI re-render, no loop.
- `refreshImages()` in `updateNSView` is retained as a one-time sync pass on layout rebuild only, not on every cache update.
- The `REFRESH still nil pages` log line is removed from the hot path; it now only fires during the initial layout build if pages are missing.

**Before:** Every decoded page triggered a SwiftUI re-render + O(n) scan of all page views.
**After:** Each decoded page is injected directly into its `NSView` in O(1).

---

### Change 4: O(log n) Scroll Tracking
**Files:** `Sources/DC/Views/VerticalComicScrollView.swift`

- `Coordinator` now pre-computes a sorted array of cumulative page Y-offsets (`pageYOffsets: [CGFloat]`) when pages are built or layout changes.
- `scrollDidChange` uses binary search on `pageYOffsets` to find the current page in O(log n) instead of iterating all page views.

**Before:** O(n) linear scan of all page views on every scroll event.
**After:** O(log n) binary search on pre-computed offsets.

---

## CPU Optimization — Thumbnail Generation — 2026-03-21

**Goal:** Reduce thumbnail generation CPU usage from ~30% on M4 Max to under 10%.

---

### Fix 1: Direct ImageIO JPEG Encoding (no TIFF roundtrip)
**File:** `Sources/DC/ViewModels/LibraryViewModel.swift`

- Replaced `saveThumbnail` with `scaledCGImage(from:)` + `saveCGImage(_:to:)`.
- Old path: `NSImage → lockFocus/draw → unlockFocus → tiffRepresentation → NSBitmapImageRep → JPEG data → write`. Four intermediate representations.
- New path: `CGImage → CGContext(draw) → CGImageDestinationCreateWithURL → CGImageDestinationAddImage → finalize`. One step, routes through the hardware JPEG encoder on Apple Silicon.

**Before:** Software JPEG encode with 4 intermediate buffers per thumbnail.
**After:** Hardware-accelerated JPEG encode via ImageIO, ~2–3× faster per thumbnail.

---

### Fix 2: Eliminate Disk Reload After Save
**File:** `Sources/DC/ViewModels/LibraryViewModel.swift`

- `saveThumbnailAndCache` previously wrote the JPEG to disk, then immediately reloaded it with `NSImage(contentsOf:)` to cache the "compressed" version.
- Now caches the `CGImage` directly from the encode step — no disk round-trip.

**Before:** Every thumbnail generation = 1 disk write + 1 disk read.
**After:** Every thumbnail generation = 1 disk write only.

---

### Fix 3: Batched `thumbnailGeneration` Increments
**File:** `Sources/DC/ViewModels/LibraryViewModel.swift`

- Added `pendingThumbnailCount` counter and `flushThumbnailGeneration()` helper.
- `thumbnailGeneration` (which triggers a full SwiftUI library grid re-render) now increments only every 10 completions, not after every single thumbnail.
- `flushThumbnailGeneration()` is called at the end of `generateThumbnailsParallel` to ensure the final partial batch is shown.
- Same batching applied to disk-load path in `requestThumbnail`.

**Before:** 369 SwiftUI grid re-renders during a full library scan.
**After:** ~37 re-renders (10× reduction in main-thread work).

---

### Fix 4: Concurrency Reduced to 2 + Task.yield()
**File:** `Sources/DC/ViewModels/LibraryViewModel.swift`

- `generateThumbnailsParallel` concurrency cap reduced from 3 to 2.
- Added `await Task.yield()` after each task completion to let the OS schedule UI rendering work between archive extractions.

**Before:** 3 simultaneous archive extractions competing with the main thread.
**After:** 2 extractions with cooperative yielding; UI stays responsive during generation.

---

### Fix 5: Visible-First Generation Order
**File:** `Sources/DC/ViewModels/LibraryViewModel.swift`

- Added `visibleRequestQueue: [URL]` — populated by `requestThumbnail(for:)` when a card appears on screen and its thumbnail is not yet on disk.
- `generateMissingThumbnails` now calls `buildPrioritisedQueue(all:)` which places visible-first URLs at the front of the generation list.
- Result: thumbnails for the initial viewport are generated before any off-screen comics, so the user sees a complete grid immediately.


## 0.1.1 — 2026-04-14

**In MemoryMonitor.swift, add a computed property 'memoryPressure' that returns 'nominal' if residentBytes < 100MB, 'elevated' if 100-400MB, 'warning' if 400-700MB, 'critical' if > 700MB**
