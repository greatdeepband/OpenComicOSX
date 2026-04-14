# DC Reader — Changelog

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
