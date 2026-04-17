# Open Comic — Codebase Report

**Project:** DC (Open Comic)
**Path:** `/Volumes/Media/__Manus copy/DC`
**Platform:** macOS 14.0+ (Swift 5.10+ / SPM)
**Total:** 15 Swift files, ~4,620 lines

---

## Architecture Overview

**Pattern:** AppKit + SwiftUI hybrid. AppKit (NSCollectionView, NSView) for performant image rendering in the reader — SwiftUI for all UI chrome. This is a deliberate performance choice: SwiftUI's image rendering was causing flicker and re-render issues at scroll.

```
Sources/DC/
  DCApp.swift              — @main entry, WindowGroup, app-level commands
  DCLogger.swift           — actor-based async file logger → /tmp/dc_debug.log
  MemoryMonitor.swift      — @MainActor RSS polling (mach_task_basic_info), 5s interval
  Models/
    Comic.swift            — Comic, ComicPage, PageSource, ComicFormat
    ComicLoader.swift      — format-specific loaders (CBZ, PDF, CBR/CB7 via unar, CBT via tar)
    ReadingPosition.swift   — UserDefaults-backed reading position/mode/scroll persistence
  ViewModels/
    LibraryViewModel.swift  — @MainActor library state, galleries, recents, thumbnail cache
    ReaderViewModel.swift   — @MainActor reader session, PageImageCache actor, navigation
  Views/
    ContentView.swift      — root: ZStack of LibraryView + conditionally shown ReaderView
    LibraryView.swift       — full library UI: header, search, grid, gallery sections, debug bar
    ReaderView.swift        — toolbar, mode routing (single/double/vertical), keyboard handling
    VerticalComicScrollView — NSViewRepresentable wrapping NSCollectionView + custom flow layout
    ZoomableImageView.swift — SwiftUI pinch/pan/zoom + magnifier loupe
    MagnifierView.swift     — circular 1.45× loupe rendered via SwiftUI Canvas
```

---

## Memory Architecture — Core Design

**Hard constraint:** Stay under 200 MB RSS.

### Thumbnail cache (LibraryViewModel)
- **NSCache** with `countLimit = 600`. Auto-evicts under system memory pressure.
- **Disk fallback** — thumbnails on disk at `~/Library/Application Support/DC/Thumbnails/<FNV1a-hash>.jpg`
- **FNV-1a hash** replaces Swift's per-process random `hashValue` — thumbnails are stable across launches.
- **Visible-first generation** — background TaskGroup with concurrency=8; off-screen thumbnails written to disk only (not cached in RAM) to prevent the 1 GB first-launch spike from caching 2,000+ thumbnails.
- **Orphan purge** on every launch — cleans up old hashValue-named files.
- **Migration** — one-time clear of old thumbnails when `thumbnailScheme_fnv1a_v1` key is absent.

### Page cache (ReaderViewModel + PageImageCache)
- **Actor-isolated** sliding window: `[center - 1 ... center + 3]` = 5 pages hard-capped.
- `NSCache.countLimit = 8` provides a safety margin above the 5-page window.
- **Explicit eviction** on every page turn — `evictOutside()` runs synchronously (not deferred), so stale decodes don't block new ones.
- **CBZ whole-file load**: `loadCBZ` reads the entire compressed ZIP into `Data` (`zipData` case), eliminating per-page disk I/O during scrolling. Memory cost = compressed file size (50–200 MB typical).
- **Streaming CBZ decode**: `CGImageSourceCreateIncremental` + chunked `archive.extract()` — never holds full decompressed image in RAM at full resolution.
- **Screen-resolution decode**: `CGImageSourceCreateThumbnailAtIndex` with `maxPixelSize = 2048` — avoids loading print-resolution bitmaps (e.g. 1988×3056, ~23 MB). Decoded pages stay ~10 MB each.
- **Deduplication**: `inFlight` Set prevents redundant parallel decodes of the same page.
- **Cancel stale in-flight**: when window moves backward, `evictOutside` clears `inFlight` entries, unblocking the re-decode.

### MemoryMonitor
- Samples RSS via `mach_task_basic_info` every 5s.
- Thresholds: Clean < 50 MB, Moderate < 200 MB, High < 500 MB, Critical above.
- Logs to `/tmp/dc_debug.log` and publishes to debug overlay.

---

## File Format Handling

| Format | Loader | Extraction | Cache |
|--------|--------|-------------|-------|
| CBZ | `loadCBZ()` | Whole-file `Data` load, `zipData` PageSource | RAM (compressed size) |
| PDF | `loadPDF()` | `PDFDocument(url:)` — pages referenced, not decoded | PDFKit managed |
| CBR/CB7 | `loadWithUnar()` | `unar` to `~/Library/Application Support/DC/Pages/<hash>/` | Extracted files |
| CBT | `loadTAR()` | `tar -xf` to cache dir | Extracted files |
| EPUB | unsupported | — | — |

**Content-based cache validation**: cache manifest (`entryCount` + `totalUncompressedSize`) stored as `.dc_cache_manifest.json` in each cache directory. Staleness checks compare archive metadata vs manifest — avoids relying on mtime.

**RAR metadata**: `lsar -j` (JSON) parses `XADFileName` and `XADFileSize` for count/size without full extraction.

---

## Gallery Model (LibraryViewModel)

```swift
struct Gallery: Identifiable, Codable {
    var id: UUID
    var name: String
    var sourceFolders: [URL]      // user-added folder URLs
    var comics: [URL]             // resolved comic URLs, ordered
    var deletedComics: Set<URL>  // permanently excluded URLs
}
```

- Galleries persisted via `UserDefaults` (`galleries_v1` key).
- `deletedComics` prevents reappearing comics when folders are re-scanned.
- `sourceFolders` preserved — `addFolders()` appends new folders only and merges new comics.
- `resolveComics()` scans each folder recursively (enumerator), filters by extension, sorts alphabetically within each folder.

**Recents**: separate list, max 20, stored under `recentComics` key.

---

## Reading Position Persistence

All via `UserDefaults` (4 separate dictionaries):
- `readingPositions`: `[URL.path: Int]` — last page index
- `readingModes`: `[URL.path: String]` — `ReadingMode.rawValue`
- `scrollOffsets`: `[URL.path: Double]` — vertical scroll fraction (0.0–1.0)
- `pageCounts`: `[URL.path: Int]` — total pages (for progress fraction calculation)

Restored on `ReaderViewModel.init`. `isRestoringPosition` flag suppresses `updateCurrentPage` callbacks during the restore pass.

---

## Navigation & Adjacent Comic

`adjacentComicURL(offset: ±1)` searches **first gallery containing the comic** — not all galleries. Returns nil at boundaries. Navigated comics inherit the current reading mode if they have no prior saved mode.

---

## UI Architecture

### ContentView
- Library always alive (never destroyed) — preserves NSScrollView state.
- Reader shown via conditional in ZStack — `.id(comic.url)` forces fresh ReaderView on comic change.

### LibraryView
- `LazyVGrid` with `adaptive(minimum: 160, maximum: 200)` columns.
- `ComicCard` reads thumbnails directly from `NSCache` on every render pass — no `@State NSImage`.
- `updatedThumbnailURLs: Set<URL>` — per-card invalidation token. `scheduleFlush()` coalesces batch updates into one `@Published` transition.
- `onChange(of: library.openComic)` — scrolls to last-opened card after closing reader.
- `isEditMode` toggle enables gallery reorder mode (chevron headers, disable interactions).
- Debug mode toggle activates `MemoryMonitor` polling + debug bar.

### ReaderView
- Toolbar with: back, prev/next page, page counter, next/prev comic, favorite toggle, zoom controls, fullscreen, reading mode menu.
- Keyboard: arrows/WASD for navigation, Q/E for prev/next comic, 1-4 for mode, Cmd+F fullscreen, Backspace/Z to close.
- `cacheVersion` bumped on page decode completion — forces SwiftUI re-evaluation of `currentImage`.
- Four modes routed to three view types: `singlePageView` (ZoomableImageView), `doublePageView` (SpreadView), `verticalScrollView` (VerticalComicScrollView with pagesPerRow=1 or 2).

### VerticalComicScrollView
- `NSViewRepresentable` wrapping `NSScrollView` + `FlippedCollectionView` (top-left origin).
- Custom `ComicFlowLayout` — pre-computes all item frames in `prepare()`, no deferred layout.
- **Viewport-aware prefetch**: `scrollDidChange` computes visible range from layout attributes, calls `cache.prefetch(visible: ClosedRange, lookahead: 3)` — decodes visible pages + 3 ahead, evicts everything else synchronously via `removeObjectsOutside`.
- **Spread pages**: aspect ratio > 1.2 triggers full-width layout (no column split).
- **Restore**: pending page index or scroll fraction applied after `reloadData()` via `DispatchQueue.main.async`.

### ZoomableImageView
- `MagnifyGesture` + scroll-wheel zoom (0.95/1.05 factor per scroll tick).
- `MouseCatcher` NSView: left-drag = pan, right-click = magnifier loupe. **Button swap intentionally reversed** for ergonomic right-hand operation.
- `clampedOffset`: only allows pan when `scale > 1.0`, clamps to half-overhang.

### MagnifierView
- SwiftUI `Canvas` — draws a crop of the source image at 1.45× magnification.
- Origin-flip math to handle NSImage bottom-left vs Canvas top-left coordinate systems.
- `CGContext` high-interpolation copy with `NSGraphicsContext` bridging.

---

## Dependencies

Only one: **ZIPFoundation** (weichsel/ZIPFoundation.git, ~0.9.19+). All other functionality is stdlib/AppKit/SwiftUI.

**External tool dependencies** (must be installed separately):
- `unar` — RAR/7z extraction (CBR/CB7). Bundled path checked first, then Homebrew Apple Silicon (`/opt/homebrew/bin/unar`), then Homebrew Intel.
- `lsar` — Same package, JSON listing (`lsar -j`) for metadata without full extraction.

---

## Key Implementation Details

### Hash stability
Swift's `hashValue` is randomised per-process (since Swift 4.2). All cache filenames use FNV-1a 64-bit hash of the URL path, which is deterministic across processes and launches.

### Threading
- `DCLogger` is an `actor` — all writes are serialized, fire-and-forget from callers.
- `PageImageCache` is an `actor` — `image(for:)` is `nonisolated` because `NSCache` is thread-safe; mutation methods are actor-isolated.
- `LibraryViewModel` and `ReaderViewModel` are `@MainActor` — all `@Published` properties and SwiftUI bindings are main-thread-only.
- Image decoding (`source.decode()`) runs on detached `Task(priority: .userInitiated)`.

### Thumbnail pipeline
`ComicLoader.loadCoverCGImage()` → `CGImage` → `LibraryViewModel.scaledCGImage()` (200×280 canvas, `CGContext`) → `LibraryViewModel.saveCGImage()` (hardware JPEG via `CGImageDestination`) → disk. CGImage kept in NSCache directly (no re-decode on display).

### Cache busting strategy
Old thumbnails named by non-deterministic `hashValue` are orphaned on every upgrade. `purgeOrphanedThumbnails()` deletes any file whose name doesn't match a known FNV-1a key. A one-time migration wipes all old files when `thumbnailScheme_fnv1a_v1` is absent.

---

## Known Quirks / Design Decisions

1. **Left/right mouse button swap in ZoomableImageView**: left-click-drag shows loupe, right-click-drag pans. Comment explicitly calls this "intentional button swap for ergonomic right-hand operation."
2. **LibraryView always alive**: preserves scroll position naturally — the NSScrollView is never torn down.
3. **ComicCard reads NSCache on every render**: `renderToken` UUID bumps trigger re-evaluation; no `@State NSImage` to avoid strong references blocking NSCache eviction.
4. **`zipData` for CBZ loads entire compressed file into RAM**: trade-off of memory for scroll smoothness. No disk I/O per page.
5. **Spread detection**: `isSpread = naturalSize.width / naturalSize.height > 1.2` — landscape pages treated as double-page spreads.
6. **PDF render scale = 2.0** (not maxPixelSize-based like CBZ) — `page.draw(with: .mediaBox, to: ctx)` at 2× for Retina.
7. **No EPUB support**: `load()` throws; `loadCover()` returns nil.
