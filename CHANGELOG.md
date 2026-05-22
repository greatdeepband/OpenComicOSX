# DC Reader — Changelog

## v0.15.0 — 2026-05-22 — CBZ compression, trackpad swipes, loupe + icon fixes

Two big features and a handful of polish fixes. **CBZ compression** lands as a full feature with menu and right-click access — recompresses JPEG images inside each archive, optionally converts PNGs to JPEGs for PNG-heavy libraries, optionally keeps originals. **Trackpad swipe navigation** lets you flip pages with a two-finger swipe in single/double-page modes. The loupe no longer steals window-resize clicks in the bottom-left/right corners, and the app icon is now compiled into an Asset Catalog so Stage Manager and Spotlight display it properly.

### Added

- **CBZ compression.** Open the Library menu → "Compress All Comics…", right-click a gallery → "Compress Gallery…", or right-click any comic card → "Compress Comic…". A prompt asks two questions: delete originals (replace in place) or keep them as `<name>-original.cbz` next to the compressed file, and whether to convert PNG entries to JPEG. Both choices can be ticked "Remember my choice" to skip the prompt on future batches. A modal progress sheet shows live per-page progress within each file, total file count, current filename, a Cancel button, and on completion a breakdown of JPEGs rewritten / PNGs converted / non-CBZ files skipped / total bytes saved (with percentage). The algorithm mirrors CompyUI's `container.py` + `image_engine.py`: decode each JPEG via ImageIO's thumbnail API, resize to fit 2000 px on the longer edge, re-encode at quality 0.78 (color) / 0.73 (grayscale), skip the rewrite if it wouldn't save at least 5 %. PNG entries pass through unchanged by default — preserving the format — but the opt-in PNG → JPEG mode (renaming `.png` → `.jpg` inside the archive, compositing alpha onto white) typically gives 5–10× shrinkage on scanned-manga archives that are otherwise pass-through-only. Atomic-write via `FileManager.replaceItemAt` — a crash mid-compression never destroys the source. Per-file thumbnail invalidation so the library card refreshes from the new (smaller) file without an app restart.
- **Trackpad swipe navigation** in single-page and double-page reading modes. A two-finger horizontal swipe flips one page (right = previous, left = next). Threshold is 50 points of horizontal travel with a 1.5× horizontal-dominance ratio so a casual diagonal scroll doesn't accidentally flip pages. A momentum-phase guard prevents a flick from double-firing. When the page is zoomed in (scale > 1) the gesture passes through so trackpad panning still works. Three-finger swipe was wired to next/previous comic, but on most macOS setups the OS claims three-finger horizontal gestures for "Swipe between full-screen apps" before the app sees them — to enable, set System Settings → Trackpad → More Gestures → "Swipe between full-screen apps" to four fingers.
- **Compiled Asset Catalog** (`Resources/Assets.car`) alongside the existing `AppIcon.icns`. Stage Manager, Spotlight and Mission Control read the modern asset catalog first; previously they showed a blank tile because they don't always fall back to `CFBundleIconFile`. `build_production.sh` now invokes `xcrun actool` automatically as part of the bundle assembly. `CFBundleIconName: AppIcon` added to `Info.plist`.

### Fixed

- **Loupe no longer fires when clicking in the bottom-left or bottom-right window corners.** AppKit's diagonal-resize hot zone at each corner is ~14 pt square, wider than the 6 pt straight-edge zone the existing guard checked. A click in the corner band was being claimed by the loupe's app-wide `.leftMouseDown` monitor instead of starting a window resize. New `windowResizeCornerMargin = 14` constant and a corner-only check in `MetalPageView+Loupe.swift` so any click where both axes are within the corner band hands the event back to AppKit. Top corners were already shielded by the top-strip guard.
- **Compression progress sheet no longer sticks on "Compression / Idle" after Done.** The `.sheet` binding was reading `library.compressionService.state` — a `@Published` on a nested `ObservableObject` — through an `@EnvironmentObject`. SwiftUI's environment-object observation doesn't chain into nested observables, so when `state` transitioned back to `.idle` after `acknowledge()`, the binding's `get` closure was never re-evaluated and the sheet stayed up. Wrapped both compression sheets in a `CompressionSheetsModifier` that owns `@ObservedObject` references to both the library and the service.

### Changed

- **JPEG compression quality dropped from 0.85 → 0.78 (colour) and 0.80 → 0.73 (grayscale).** ImageIO can only write baseline JPEGs without Huffman optimization; CompyUI's PIL encoder writes progressive JPEGs with optimized Huffman tables, which produces output 10–20 % smaller at the same nominal quality. Dropping our quality knob lands us at comparable output bytes via the only encoder we have. Still visually transparent on comic art at typical reading scales.
- **Compression progress bar now tracks per-page progress within each file**, not just file-level. A single 200 MB CBZ has 200+ entries; previously the bar sat at `0 of 1` for the whole compression then snapped to done. New `entryCompleted` / `entryTotal` `@Published` properties on `CompressionService`, combined with `filesCompleted` / `filesTotal` for a smooth bar across both axes. Multi-file batches show "File X of Y" + "Page X of Y" + the current filename; single-file batches just show the page progress.
- **Compression summary now shows a per-entry-type breakdown.** JPEGs rewritten, JPEGs skipped (already-small / bitonal / decode failure), PNGs converted to JPEG, PNGs passed through, other entries passed. Plus a percentage on the total-bytes line. Tells the user *why* compression was marginal (often: archive is mostly PNGs and PNG-conversion mode wasn't enabled).

### Constants

- `cbzCompressionMaxDim: Int = 2000`, `cbzCompressionJpegQuality: CGFloat = 0.78`, `cbzCompressionGrayQuality: CGFloat = 0.73`, `cbzCompressionSkipThreshold: Double = 0.95` — the four tuning knobs for CBZ compression. Documented inline with the ImageIO-vs-PIL rationale.
- `pageSwipeThreshold: CGFloat = 50`, `swipeHorizontalDominanceRatio: CGFloat = 1.5` — page-nav swipe gating.
- `windowResizeCornerMargin: CGFloat = 14` — corner-resize hot-zone radius for the loupe edge guard.

### Files

- `Sources/DC/Models/CBZCompressor.swift` — new. `recompressJPEG` + `recompressPNGAsJPEG` + `compressCBZ` + result/error types. Tests in `Tests/DCTests/CBZCompressorTests.swift` (4 unit + integration tests).
- `Sources/DC/Models/CompressionService.swift` — new. `@MainActor` `ObservableObject` orchestrator with cancellation, per-entry-type aggregation, and per-page progress publication.
- `Sources/DC/Views/CompressionPromptSheet.swift` — new. Delete-or-keep picker, "Convert PNG pages to JPEG" toggle, "Remember my choice" checkbox, `CompressionPreferences` UserDefaults wrapper.
- `Sources/DC/Views/CompressionProgressSheet.swift` — new. Live progress + breakdown + cancel/done.
- `Sources/DC/Views/MetalPageView+Swipes.swift` — new. Unified `installPageSwipeMonitor` that touch-counts on `.scrollWheel` events for 2-finger and 3-finger gestures.
- `Sources/DC/Views/MetalPageView+Loupe.swift` — corner guard added.
- `Sources/DC/Views/MetalPageView.swift` — wires the new swipe callbacks alongside the existing zoom / loupe / double-click monitors.
- `Sources/DC/Views/ReaderView.swift` — wires swipe callbacks to `vm.nextPage` / `vm.previousPage` / `library.openAdjacentComic` in single & double page mode.
- `Sources/DC/Views/LibraryView.swift` — "Compress Comic…" on each of the 3 comic-card context-menu sites, "Compress Gallery…" on the sidebar gallery rows, `CompressionSheetsModifier` for sheet presentation.
- `Sources/DC/ViewModels/LibraryViewModel.swift` — compression entry methods, `startBatch` with `onFileCompleted` hook, `invalidateThumbnail` for post-compression cover refresh.
- `Sources/DC/DCApp.swift` — "Compress All Comics…" menu item under the existing `CommandMenu("Library")`.
- `Sources/DC/ReaderConstants.swift` — compression + swipe + loupe-corner constants.
- `build_production.sh` — Asset Catalog compilation step (xcassets dir → `xcrun actool` → `Resources/Assets.car`) + `CFBundleIconName` in `Info.plist`.
- `docs/design/2026-05-19-cbz-compression.md` — full 13-task implementation plan that drove the compression work.

---

## v0.14.0 — 2026-05-17 — OSS readiness milestone + comic-switch polish

This release closes the open-source readiness audit started 2026-05-13: MIT license, LGPL attribution for the bundled `unar` / `lsar`, a baseline test target, GitHub Actions CI, and a `CONTRIBUTING.md` that documents the project's live-verification protocol and load-bearing workarounds. On top of that, the comic-switch transition is now visually smooth — the toolbar icon "grey settle" during the cold-render gap is gone, freshly-decoded pages no longer wait for a mouse move to appear, and the library no longer races single-tap-select against double-tap-open.

### Added
- **MIT LICENSE.** Open Comic itself is now MIT-licensed. The bundled `unar` / `lsar` binaries remain LGPL-2.1-or-later; full attribution + source-availability statement + relinking instructions live in `THIRD_PARTY_LICENSES.md`, with the full LGPL-2.1 text under `LICENSES/LGPL-2.1.txt`. The README and the in-bundle resources both point at the same source.
- **Baseline unit test target.** `Tests/DCTests/` covers the pure-logic units that don't need a running app: `ComicFormatTests` (file-extension parsing across CBZ / CBR / CB7 / CBT / PDF), `ReadingPositionStoreTests` (UserDefaults round-trip for page index, reading mode, scroll offset, page count), `TextureRingBufferTests` (LRU eviction + ring-position reuse). Run with `swift test`. Metal-touching code stays live-verified inside `OpenComic.app` per the protocol in `CONTRIBUTING.md`.
- **GitHub Actions CI** at `.github/workflows/swift.yml`. macos-14 runner, Xcode 15.4 (matches `swift-tools-version: 5.10`), `swift build -c release` + `swift test --parallel`, SwiftPM dependency cache keyed on `Package.resolved`. Runs on `push` and `pull_request` against `main`.
- **`CONTRIBUTING.md`.** Branch / test / build workflow, live-verification protocol ("the unit-test target covers pure logic only — UI correctness comes from driving the app"), test-all-four-reading-modes guidance when touching `MetalPageView` or its layout/render extensions, the "don't `rm /tmp/dc_debug.log` while the app is running" rule, and explicit pointers at the load-bearing workarounds (3-stage render retry, synchronous scroll-restore before `updateVisibleRange`, macOS 26 Tahoe scroll-into-header inset pattern, Hume `presentsWithTransaction` triplet).
- **New comics default to Single Page reading mode** instead of inheriting the user's last mode from a different comic. The previous behaviour leaked the wrong mode across comics with very different shapes — a Vertical-Double setting from a long manga applied awkwardly to a 22-page Western comic. A fresh `UserDefaults` entry is now treated as "no preference yet" and lands the reader in `.singlePage` instead of falling through to the global last-used value.

### Changed
- **`DCLogger.enabled` defaults to `true` in DEBUG builds and `false` in release builds** instead of `true` unconditionally. Release builds no longer write to `/tmp/dc_debug.log` by default — flip at runtime via `DCLogger.shared.enabled = true` if you're capturing a bug report. The actor itself is unchanged, just the default.
- **Reader toolbar capsules drop `.interactive(true)` from `glassEffect`.** Each capsule's buttons already have `.buttonStyle(.plain)` interaction, so capsule-level hover/press reactivity was duplicative — and it was leaking hover state across `.id(comic.url)`-driven view-tree rebuilds: the cursor stays in place while the tree tears down + remounts, the new capsule instantly enters hover, and the exit event for the now-gone old capsule sometimes never fires, leaving the new capsule visually stuck "highlighted" until the next mouse move.
- **Reader backdrop is now `Color(NSColor.windowBackgroundColor)` instead of `Color.black`.** Under the floating Liquid-Glass capsules, the system-appropriate window background is sampled instead of solid black during the cold-render gap, so the toolbar's vibrancy-driven foreground colour stays stable.
- **`scripts/make_app.sh`, `scripts/memory_ring_test.sh`, `scripts/make_icns.py` no longer reference hardcoded `/Volumes/Media/__Manus copy/DC` or `/home/ubuntu/…` paths.** All three now resolve their working directory relative to their own location, matching `build_app.sh` / `build_production.sh`.

### Fixed
- **Toolbar icons no longer flash from grey to dark during the cold-render gap on comic switch.** The reader's SwiftUI backdrop was `Color.black`, and the `CAMetalLayer` clear colour is also black — so between the new `ReaderView` mounting (via `.id(comic.url)`) and the first successful Metal draw, the area under the floating Liquid-Glass toolbar capsules was solid black. macOS 26's Liquid Glass auto-adapts `Color.primary` based on the luminance underneath the capsule for legibility: over black it drifts toward light/grey; over normal page art it resolves to dark. As pages painted in, the icons interpolated through that adaptation — visible as a "grey settle" transition. Switching the backdrop to `Color(NSColor.windowBackgroundColor)` means the capsules never sample solid black during the gap, and the icon colour stays stable end-to-end. The black phase was always there — making the page paint faster (the CATransaction fix below) is what exposed the adaptation as a visible transition rather than a static state.
- **Freshly-decoded pages no longer wait for a mouse move or scroll to appear.** Renders triggered from `onTextureReady` (the prefetch upload landing on the main actor) had no enclosing CATransaction — with `CAMetalLayer.presentsWithTransaction = true` the drawable was queued for "next CATransaction commit", which only fired when some other AppKit event woke the runloop. Wrapped `drawable.present()` in an explicit `CATransaction.begin()` / `commit()` pair so the drawable always commits in-frame regardless of who triggered the render. Inside an already-open AppKit transaction (scroll, resize) this nests harmlessly.
- **Single-tap-to-select on a library card no longer races double-tap-to-open.** Two stacked `.onTapGesture` modifiers (count: 2 for open, count: 1 for select) had SwiftUI's gesture arbiter occasionally swallowing the double-tap as two single-taps. Replaced the count-1 selection gesture with `.simultaneousGesture(TapGesture().onEnded { … })` so it can fire alongside the open recognizer without competing for arbitration. Affects all three card grids (`LibraryGridPane`, `LibraryGalleryPane`, `DraggableComicGrid`).
- **Decode and persist failures now log via `DCLogger` instead of being silently swallowed by `try?`.** `ComicLoader` (CBZ entry decode, PDF page extraction, archive `Process.run`), `LibraryViewModel` (cache directory create / remove). Failures still don't bubble up to the user (callers expect optional return), but they leave a breadcrumb in `/tmp/dc_debug.log` when debug logging is enabled.

### OSS hygiene
- Three verified code-quality wins from a focused cleanup pass — `LoupeOverlayState` marked private (was visible across the module despite being a callback payload); rationale comments added to `MemoryMonitor`'s memory thresholds; magic numbers eliminated where they had only one call site.
- Git tags for `v0.11.0` / `.1` / `.2`, `v0.12.0` / `.1` / `.2`, and `v0.13.0` retroactively applied so `git tag -l` reflects the CHANGELOG.

### Files
- `LICENSE`, `LICENSES/LGPL-2.1.txt`, `THIRD_PARTY_LICENSES.md`, `CONTRIBUTING.md` — new. Commits `e1fd0dd`, `9225394`.
- `Tests/DCTests/{ComicFormatTests,ReadingPositionStoreTests,TextureRingBufferTests}.swift`; `Package.swift` adds `testTarget`. Commit `9225394`.
- `.github/workflows/swift.yml` — new. Commit `9225394`.
- `Sources/DC/DCLogger.swift` — `enabled` default `#if DEBUG`. Commit `9225394`.
- `scripts/make_app.sh`, `scripts/memory_ring_test.sh`, `scripts/make_icns.py` — portable paths. Commit `9225394`.
- `Sources/DC/Models/ComicLoader.swift`, `Sources/DC/ViewModels/LibraryViewModel.swift` — DCLogger calls replace `try?` swallows. Commit `cab6a6e`.
- `Sources/DC/ViewModels/ReaderViewModel.swift` — single-page default for fresh comics. Commit `22dac87`.
- `Sources/DC/Views/ReaderView.swift`, `Sources/DC/Views/ReaderToolbar.swift`, `Sources/DC/Views/MetalPageView+Render.swift`, `Sources/DC/Views/LibraryView.swift` — comic-switch polish bundle. Commit `284980f`.
- `Sources/DC/Views/MetalPageView.swift`, `Sources/DC/MemoryMonitor.swift` — quality wins. Commit `7c72dc3`.

---

## v0.13.0 — 2026-05-14 — Page thumbnail placeholder tier (eliminates fast-scroll black gaps)

### Added
- **Fast scroll in vertical-double on long comics no longer shows black gaps.** A low-resolution thumbnail (max 450 px on the longer edge) for every page is pre-scanned in parallel on comic open, then used as a render-path placeholder while full-res decode is in flight. The user sees a blurry-but-legible preview during scroll instead of empty space; full-res snaps in within ~100 ms of scroll settling on a page. ImageIO's `CGImageSourceCreateThumbnailAtIndex` does the decode for raster sources (CBZ / CBR / CB7 / CBT / standalone images) — it picks up the embedded JPEG thumbnail when present and downscales otherwise — and `PDFPage.thumbnail(of:for:)` covers PDFs.
- **Thumbnail pre-scan completes in well under 1 s for a 200-page comic.** `MetalPageManager.preScanThumbnails` uses `withTaskGroup` to fan out one child task per page across the cooperative thread pool (~6 cores on M-series). Thumbnail decode is `nonisolated`, so child tasks run on background CPU without contending at the foreground actor queue — pre-scan progresses concurrently even during active fast scroll, where a serial version stalled behind foreground prefetch priority.

### Changed
- **Thumbnail storage moved off `MetalPageManager`'s decode actor onto a small dedicated `ThumbnailStore` actor.** The store exposes `cached(_:)` / `store(_:for:)` / `snapshot()` — microsecond dict ops, never a bottleneck. Heavy decode work happens in nonisolated helpers that don't touch any of the manager's full-res cache state, so they don't queue behind foreground full-res decode.
- **Render path falls back to thumbnails when full-res isn't ready.** `MetalPageRenderer.render(...)` tries `textureRing[pageIndex]` first, falls back to `thumbnailRing[pageIndex]` before skipping the page. When the full-res `MTLTexture` lands on a later prefetch upload, the next render naturally picks it over the thumb (swap is automatic, no animation needed). No shader change — the GPU samples in 0–1 UV space, so a thumbnail stretches to fill the page rect.

### Constants
- `ReaderConstants.thumbMaxPixel = 450` — max edge for thumbnail decode.
- `ReaderConstants.thumbnailRingCap = 200` — parallel `MTLTexture` ring capacity. ~108 MB GPU memory for 200 thumbs at 300×450 BGRA.

### Files
- `Sources/DC/ViewModels/MetalPageManager.swift` — `ThumbnailStore` actor, nonisolated `decodeThumb` + per-source helpers + `allThumbnails` + parallel `preScanThumbnails`. Commits `e03ec5b`, `d041194`.
- `Sources/DC/ViewModels/ReaderViewModel.swift` — `preScanTask` spawned on init at `.background` priority, cancelled in deinit. Commit `7bb1db1`.
- `Sources/DC/Views/MetalPageRenderer.swift` — `thumbnailRing`, `uploadThumb(image:for:)`, `thumbTexture(for:)`, render fallback. Commits `eb86b74`, `6e9b29a`.
- `Sources/DC/Views/MetalPageView.swift` — `makeNSView` wires `pageManager.onThumbReady` and seeds the new renderer from `manager.allThumbnails()`. Commit `eb86b74`.
- `Sources/DC/ReaderConstants.swift` — new thumbnail constants. Commits `e03ec5b`, `eb86b74`.

---

## v0.12.2 — 2026-05-13 — Library: Continue Reading rail dedupes the hero

### Fixed
- **The comic shown in the Home view's hero card no longer appears again in the "Continue Reading" rail directly below it.** `LibraryHome.content` hoists `resumeURL` out of the `if let` it was previously scoped to, so the rail can filter the same URL out of its list before rendering.

### Changed
- **`LibrarySection`, `CardSize`, `LibrarySortOrder` extracted from `LibraryView.swift` into a new `LibraryTypes.swift`.** No semantic change; keeps the main view file focused on layout, types easy to find under one file for outside contributors.

### Files
- `Sources/DC/Views/LibraryView.swift` — rail filter + extraction. Commit `41377a7`.
- `Sources/DC/Views/LibraryTypes.swift` — new file (71 lines). Commit `41377a7`.

---

## v0.12.1 — 2026-05-13 — Vertical-mode zoom via window-resize gesture

### Added
- **In vertical and vertical-double reading modes, pinch and ⌘+scroll now grow or shrink the window in ±10 % steps** instead of scaling page content. The natural way to "zoom" pages that already fill the column width is to make the column bigger; this gesture path makes that explicit. Single-page and double-page mode's content-scale zoom behaviour is unchanged.

### Changed
- **`NSScrollView.magnification` is now locked to 1.0 in `.verticalStack` layouts**, both in `makeNSView` and the `layoutChanged` branch of `updateNSView` — belt-and-suspenders any pinch event the local monitor might miss before being wired up on a fresh `makeNSView`.
- New `MetalPageView.Coordinator` state: `zoomGestureAccumulator` + `lastZoomStepTime` — accumulate gesture delta and rate-limit window-resize firings.

### Constants
- `ReaderConstants.verticalZoomWindowFactor = 1.10` (10 % per step).
- `ReaderConstants.verticalZoomStepCooldown = 0.15` (seconds between steps).
- `ReaderConstants.verticalZoomGestureThreshold = 0.20` (accumulator threshold).
- `ReaderConstants.verticalZoomMinSize = 480 × 360` (window content size floor).

### Files
- `Sources/DC/Views/MetalPageView.swift` — magnification lock + Coordinator state. Commit `1d90567`.
- `Sources/DC/Views/MetalPageView+Zoom.swift` — scroll-wheel and pinch monitors route to `applyVerticalZoomGestureDelta` in vertical layouts. Commit `1d90567`.
- `Sources/DC/ReaderConstants.swift` — verticalZoom constants. Commit `1d90567`.

---

## v0.12.0 — 2026-05-13 — Off-main-thread Metal upload fix + page-cache discipline

### Fixed
- **Latent race condition in the prefetch task** that could have manifested as black pages, wrong-page flashes, or hard crashes (SIGABRT) on aggressive scroll — especially on Intel Macs with discrete GPUs where Metal's serialisation guarantees are weaker than on Apple Silicon's unified memory architecture. `MetalPageRenderer.upload(pixelBuffer:)` and `texture(for:)` were running on the prefetch `Task`'s nonisolated continuation after `await manager.decodePage(...)`. The renderer's `TextureRingBuffer` mutation and `MTLDevice.makeTexture` are documented main-actor-only — same threading-invariant family as the project's known "`nextDrawable()` off main thread → SIGABRT" landmine. Wrapped both calls in `await MainActor.run`; the early-bail cache check was also moved under a leading main-actor hop so neither side reads `@MainActor` Coordinator state off-isolation.
- **Vertical-double fast scroll on long comics was wiping the page cache to a 5-page window** every time `onPageChanged` fired. The legacy `MetalPageManager._prefetchAround` path (called from `ReaderViewModel.triggerPrefetch` on every `updateCurrentPage`) was calling `evictOutside(currentPage-1 ... currentPage+3)`, wiping `decodedPages` / `lastAccessTimes` / `nsImageCache` to that tiny window — including pages the newer per-visible-range prefetch had just decoded. Eviction is now solely the responsibility of `store(...)`'s LRU against `ReaderConstants.pageCacheCap`.

### Changed
- **Page cache cap centralised into `ReaderConstants.pageCacheCap` and bumped from 10 to 24.** Three lockstep caches — `MetalPageManager.decodedPages` (CVPixelBuffer ring), `MetalPageManager.nsImageCache` (NSImage fast-path), `MetalPageRenderer.textureRing` (MTLTexture ring) — previously hardcoded the value in three places. 24 covers vertical-double on a tall window (8 visible + 6 prefetch) plus ~10 slots of backward-scroll history. Peak memory ~670 MB at typical comic resolution; sits at `MemoryMonitor`'s `.high` threshold.

### Added
- **`build_app.sh` and `build_production.sh` now committed to the repo.** `build_app.sh`'s hardcoded `/Volumes/Media/DC_dev_lib` path was replaced with the same `$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )` pattern `build_production.sh` already used — the script now works from any clone path. Clears an OSS-readiness blocker.

### Files
- `Sources/DC/Views/MetalPageView+Render.swift` — Metal upload moved onto main actor. Commit `f0fc2ab`.
- `Sources/DC/ReaderConstants.swift`, `Sources/DC/ViewModels/MetalPageManager.swift`, `Sources/DC/Views/MetalPageRenderer.swift` — pageCacheCap centralisation. Commit `d91a208`.
- `Sources/DC/ViewModels/MetalPageManager.swift` — `evictOutside` removed from `_prefetchAround`. Commit `ac350be`.
- `build_app.sh`, `build_production.sh` — added; `build_app.sh` path fixed. Commit `de40201`.

---

## v0.11.2 — 2026-04-28 — Scroll position preserved across rapid reading-mode switches

### Fixed
- **Cycling reading modes faster than the runloop could complete a restore landed the user on the cover instead of the page they were reading.** `vm.currentPage` was being clobbered to `0` after a mode switch. The `verticalStack` scroll-restore in `updateNSView`'s `layoutChanged` branch was wrapped in `DispatchQueue.main.async`, so the trailing synchronous `updateVisibleRange()` at the end of `updateNSView` sampled `clipView.origin.y = 0` and emitted `onPageChanged(0)`. If the user switched modes again within the same runloop tick before the dispatched `scrollToPage` / `scrollToFraction` could fire, `vm.currentPage` stayed at `0`. Made the verticalStack restore synchronous — `layoutSubtreeIfNeeded()` already commits the documentView frame, so the synchronous call sees correct `pageYOffsets` and clip bounds. Single-page and double-page paths untouched: their trailing `updateVisibleRange()` is load-bearing for initial render after `rebuildLayout` and must not be skipped (see `2026-04-28` failed-attempts memory).
- **Cover stayed blank after mode switch until a scroll changed the visible range.** Each mode switch creates a new `MetalPageRenderer` with an empty `TextureRingBuffer`. Without cancelling the in-flight prefetch task and clearing `prefetchInFlightRange`, two failures occurred: the in-flight task kept uploading into the dropped renderer, and a new `triggerPrefetch` for the same range (e.g. `0...0` across mode switches) deduplicated against the cleared `prefetchInFlightRange` and skipped the fresh decode. Added prefetch-state reset in `makeNSView` after assigning the fresh renderer; the next `triggerPrefetch` re-decodes and uploads into the new ring.

### Files
- `Sources/DC/Views/MetalPageView.swift` — 36 insertions, 6 deletions across `makeNSView` and the `layoutChanged` branch of `updateNSView`. Code commit: `6499e0c fix(reader): preserve scroll position across rapid reading-mode switches`.

---

## v0.11.1 — 2026-04-28 — Gallery thumbnail refresh decoupled from @Published

### Fixed
- **Gallery covers flickered during fast scroll on a fresh-cache library** — the previous thumbnail-refresh mechanism mutated a `@Published var updatedThumbnailURLs: Set<URL>` twice per batch flush (`= []` then `= batch` — a workaround so `onChange` would fire even when the new batch contained a URL from a previous flush). `LibraryViewModel` is consumed via `@EnvironmentObject`, so every `objectWillChange` re-rendered every visible `ComicCard`. Cards waiting for their own disk-load to complete re-rendered NIL on every neighbour's flush, which the user perceived as covers "appearing and disappearing" while/just-after scrolling. Diagnosed via per-event live debug at `2026-04-28 11:15:43–11:16:46`; trace showed 200+ `[gthumb] render NIL` lines per second across 20+ cards per flush during cache warm-up.

### Changed
- **`LibraryViewModel.thumbnailUpdates: PassthroughSubject<URL, Never>`** — replaces the `@Published Set<URL>` mechanism. `insertIntoCache`, `saveThumbnailAndCache`, and the visible-cache branch of `generateThumbnailsParallel` send one event per inserted URL. The subject is **not** `@Published`, so sending an event does not fire `objectWillChange` — a thumbnail decoded for card N never invalidates cards 1..N-1 / N+1..end.
- **`ComicCard` and `ContinueReadingHero`** subscribe via `.onReceive(library.thumbnailUpdates)` instead of `.onChange(of: library.updatedThumbnailURLs)`. The `if updatedURL == url { renderToken = UUID() }` gate is unchanged; only the publisher and the trigger site moved.

### Removed
- `@Published var updatedThumbnailURLs: Set<URL>`, `private var pendingURLs: Set<URL>`, `private var flushScheduled: Bool`, `private func scheduleFlush()`, `private func flushThumbnailGeneration()` — all obsolete with the per-URL subject.
- `updatedThumbnailURLs.remove(url)` workaround in `closeComic()` — `PassthroughSubject` always delivers `send()` to subscribers regardless of prior emissions, so the Set-mutation workaround that ensured `onChange` would fire is no longer needed.

---

## v0.11.0 — 2026-04-28 — Liquid-Glass classic-Mac reader toolbar

The reader's top-bar chrome is now three floating Liquid-Glass capsules
over a transparent strip — leading (back / Library), centred transport
(prev-comic / prev-page / page-count / next-page / next-comic with 1pt
hairline dividers between segments), trailing (favorite + ellipsis
menu). Same handlers behind every button as before; the geometry and
material are what changed. Detailed spec lives at
`docs/superpowers/specs/2026-04-27-reader-liquid-glass-toolbar-design.md`.

### Added
- **`Sources/DC/Views/ReaderToolbar.swift`** (~250 lines) — top-level
  `ReaderToolbar` view + private `ToolbarCapsule` material wrapper +
  `SegmentDivider` hairline + `LeadingCapsule` / `TransportCapsule` /
  `TrailingCapsule`. The three capsules sit inside one
  `GlassEffectContainer` on macOS 26+ so Liquid-Glass refraction
  sampling is coordinated; on macOS 14–25 the container collapses to a
  plain `Group` and each capsule renders independently with
  `.ultraThinMaterial` clipped to a `Capsule()` plus a 0.5pt rim — same
  shape, same hit targets, no refraction.
- **`ToolbarCapsule` availability gate** —
  `.glassEffect(.regular.interactive(true), in: .capsule)` on macOS
  26+; `.background(.ultraThinMaterial, in: Capsule())` +
  `.overlay(Capsule().strokeBorder(...))` fallback otherwise. One place
  to change material, three call sites (one per capsule).
- **`ReaderConstants.toolbarCapsuleHeight = 36`** and
  **`toolbarSegmentDividerOpacity = 0.12`** — the new tunables for the
  capsule geometry and the hairline divider.

### Changed
- **`ReaderConstants.topBarHeight`: 38 → 52** to host the 36pt capsules
  with breathing room and read as a "real" Mac toolbar rather than a
  thin chrome line. Propagates through `topContentInsets` arithmetic
  unchanged — no other layout math moves.
- **`ReaderView.readerTopBar`** reduces from a 116-line inline ZStack
  to a one-line call site that hands `vm` / `library` /
  `toggleFullscreen` into `ReaderToolbar`. Inline `backButton`,
  `transportCluster`, `trailingCluster` deleted (now live as private
  sub-views in `ReaderToolbar.swift`). The `TitlebarEffectView` struct
  and its `NSVisualEffectView(.titlebar)` background on the strip are
  both removed — the strip is fully transparent now.
- **`ReaderView` body** gains
  `.ignoresSafeArea(.container, edges: .top)` and
  `.background(FullSizeTitleBarConfigurator())` so the title-bar area
  is transparent and the toolbar overlays the traffic-light row in one
  unified strip — instead of stacking a 28pt opaque title bar above
  the 52pt toolbar (the symptom the first build showed: chrome read as
  ~80pt of stacked bars).
- **`FullSizeTitleBarConfigurator`** now also re-asserts
  `window.standardWindowButton(.closeButton/.miniaturizeButton/.zoomButton)?.isHidden = false`
  so the traffic lights are always visible — `.windowStyle(.hiddenTitleBar)`
  was hiding them on macOS 26 until the user hovered.
- **`DCApp.swift`** — removed `.windowStyle(.hiddenTitleBar)`. Default
  `.windowStyle(.titleBar)` keeps the controls visible always; the
  configurator handles transparency + content stretch.

### Fixed
- **Click on the navbar to drag the window also fired the loupe.**
  `MetalPageView+Loupe.swift:handleLoupeEvent` now skips
  `.leftMouseDown` events when `svLocal.y < topBarHeight` (the
  scrollView's effective coords are top-origin because the documentView
  is `isFlipped = true`, propagating through the clipView — diagnosed
  via per-event live debug, the previous bottom-origin guard always
  evaluated false). The strip is the band `[0, topBarHeight]`, not
  `[bounds.maxY - topBarHeight, bounds.maxY]`.
- **Loupe disappeared when the cursor crossed up into the navbar
  during an in-flight drag.** The naive top-strip guard blocked
  `.leftMouseDragged` events too, so the loupe felt asymmetric (works
  at left/right/bottom edges, dies at the top). Added
  `MetalPageView.Coordinator.loupeDragActive: Bool` — the strip-skip
  only gates the INITIAL `.leftMouseDown`; once a drag has started
  below the strip, all subsequent `.leftMouseDragged` events are
  processed regardless of cursor position. The loupe now fades to
  black at the page top edge in the same way it already did at the
  other three edges. `loupeDragActive` resets on `.leftMouseUp`.

---

## v0.10.3 — 2026-04-27 — Loupe behaviour restored to pre-Metal feel

### Fixed
- **Loupe image broke when crossing page top, left, or right edge in vertical scroll modes.** Inside a single page the loupe correctly faded its content to black at the page edge, but the moment the cursor crossed *outside* the page rect (into a 4pt row gap, the 2pt column gap, the 38pt top inset, or the side margins) `findSequentialIndex` returned `-1` and `updateLoupe` returned early — so the loupe panel froze at its last screen position with stale content, then unfroze when the cursor re-entered the next page rect. The bottom edge appeared to work only because the cursor couldn't travel below the page in vertical scroll without immediately re-resolving into the next page.

  Symptom traced live via per-event logging in `MetalPageView+Loupe.swift` and `MagnifierView.swift`: at the breaking point `[loupe-canvas] NO-DRAW reason=src-outside-iv` fired the moment `cursorInImage.x < -halfW` (≈ -186pt at `loupeRadius / magnification = 270 / 1.45`). The Canvas's black fill sat *inside* the visible-rect guard, so a null `srcRect.intersection(ivBounds)` produced a transparent ring, not a black circle.

### Changed
- **Restored the pre-Metal `ZoomableImageView` loupe UX, generalised across the unified Metal pipeline.** Same gesture, same lifetime, same edge fade-to-black — now resolves "which page" automatically instead of having a single image:
  - `MetalPageView.Coordinator.loupeActivePage: Int?` — the page currently being magnified. Sticky across cursor excursions; `updateLoupe` falls back to it whenever `findSequentialIndex` returns `-1`. The loupe panel keeps tracking the raw cursor (no clamping) while its magnified content stays anchored to a real page rect. `MagnifierView`'s existing `srcRect.intersection(ivBounds)` clip handles the natural fade-to-black at the page edges; raw `cursorInImage` is allowed to go arbitrarily far past the page bounds.
  - `MetalPageView+Loupe.swift:updateLoupe` only emits `nil` to the SwiftUI overlay when there are no pages at all. **No mid-drag hides** — the loupe is visible from `mouseDown` through `mouseUp`, exactly like the pre-Metal `ZoomableImageView` (`MouseCatcher.mouseDown` set `showLoupe = true`; only `mouseUp` set it back to `false`).
  - `MagnifierView.loupeContent` now paints the Canvas solid black *before* the visible-rect guard, so a cursor far enough off the page that `srcRect ⊄ ivBounds` produces an opaque black circle instead of a transparent ring with a hovering shadow.
  - `loupeActivePage` resets to `nil` on `hideLoupe` (mouseUp), in lockstep with `loupeImage` and the cursor-restore — next press starts fresh.

### Notes
- Logic is mode-agnostic: all four reading modes (single, double, vertical, vertical-double) flow through the same `updateLoupe`. The only mode-dependent branch is the *initial* fallback when `loupeActivePage` hasn't been set yet (`.singlePage`/`.doubleSpread` → `currentPage`; `.verticalStack` → `lastVisibleRange.lowerBound`); after the first successful resolution every subsequent gap/margin excursion just reuses `loupeActivePage`.
- The previous CHANGELOG note (v0.10.0 "Loupe freezes mid-drag at the gutter") covered only the *async-decode* freeze in double-page mode; this entry covers the *coordinate-system* freeze that affected vertical and vertical-double crossings into row/column gaps and side/top margins.

---

## v0.10.2 — 2026-04-25 — Reader-wide named constants + MetalPageView file split

### Changed
- **`Sources/DC/ReaderConstants.swift`** — new file gathering every previously-bare numeric constant (top-bar height, vertical-page gap, double-page gutter, magnification range, wheel-zoom step + clamp, scale-equality epsilon, aspect-ratio floor, mode-switch render-retry delays, initial-render retry budget, Metal max texture dimension, prefetch lookahead). Each value documents *why* it's that number, not just what it is. Replaces 15+ unnamed magic numbers across `MetalPageView.swift`, `ReaderView.swift`, and `ReaderViewModel.swift`.
- **`MetalPageView.swift` split into focused extension files** — the 1500-line monolith was carved into:
  - `MetalPageView.swift` (~600 lines): NSViewRepresentable struct, `MetalCanvasView` NSView subclass, `Coordinator` class declaration with stored properties + init/deinit.
  - `MetalPageView+Layout.swift` (~600 lines): rebuild, scroll, visible-range, recentre, hit-test (`findSequentialIndex`).
  - `MetalPageView+Render.swift` (~125 lines): `render`, `triggerPrefetch`, `onTextureReady`.
  - `MetalPageView+Loupe.swift` (~210 lines): NSEvent monitor, `updateLoupe`, cursor visibility, overlay state emission.
  - `MetalPageView+Zoom.swift` (~95 lines): scroll-wheel, double-click, pinch monitors.
- Coordinator stored properties were upgraded from `private` to `internal` so sibling extensions can reach them; the `final class Coordinator` is still nested inside `extension MetalPageView` and never referenced outside the reader, so the practical encapsulation is unchanged.

## v0.10.1 — 2026-04-25 — Mode-switch centring + cross-vertical scroll restore

### Fixed
- **Single-page off-centre after switching from double-page** — `NSClipView`'s `constrainBoundsRect:` clamps negative bounds origins back to 0 when the documentView is smaller than the clip view, so the previous "set negative origin to centre" math silently failed in X (no `contentInsets.left` to legalise it). `rebuildSinglePage` / `rebuildDoubleSpread` now pad the documentView to `max(scaledSize, usableViewport)` and place the page rect centred *within* the doc — centring is intrinsic to the layout, no negative origins needed. The centring block in `updateNSView` reduces to a single non-negative scroll-origin computation.
- **Vertical-single ↔ vertical-double scroll position jumped** — the live `scrollOffsetFraction` was shared across both pagesPerRow values, but a fraction is only meaningful against the doc height it was captured under (vertical-double's doc is roughly half as tall). New `vm.scrollOffsetPagesPerRow` tracks which column count the fraction was saved against; `verticalScrollView` falls through to page-based restore when the count differs, so position tracks the page rather than the (mismatched) fraction.

## v0.10.0 — 2026-04-25 — Metal pipeline unified across all four reading modes

The full Step A migration: every reading mode (single, double, vertical, vertical-double) now renders through one shared `MetalPageView` → `MetalPageRenderer` → `Shaders.metal` stack. SpreadView, ZoomableImageView, MouseCatcher, and `View.onScrollWheel` retired.

### Added
- **Metal-rendered single-page** — `MetalPageView(layout: .singlePage)` replaces SwiftUI `ZoomableImageView`. Frame-resize zoom (avoids CAMetalLayer compositing issues with `NSScrollView.magnification`).
- **Metal-rendered double-page** — `MetalPageView(layout: .doubleSpread)` replaces SwiftUI `SpreadView`. Honours `.isSpread` for natural double-scan pages.
- **Fit-to-window on open** for single/double — `scale = 1.0` now fits the page in both width and height (previously fit-by-width only, overflowing tall pages).
- **Zoom-around-centre** for single/double — every zoom step recentres the page on the viewport, preserving the focal point.
- **SwiftUI loupe overlay** — `LoupeOverlayState` + `MagnifierView` driven from `MetalPageView.onLoupeOverlay` callback. Naturally clipped by the reader's ZStack bounds; cursor reset when dragged outside the window. Replaces NSPanel-based loupe.
- **`prefetchInFlightRange` dedupe** — same-range re-triggers no longer cancel the in-flight prefetch task (was killing decodes mid-flight on rapid `updateVisibleRange` bursts).
- **Cross-mode-switch state preservation** — switching modes now preserves the live scroll-offset fraction (vertical) and current page (single/double); the new layout restores via the same persistence path the on-disk save uses.
- **3-stage render retry on layout change** — at 1ms, 50ms, 150ms after `lastLayout` changes, walks CAMetalLayer's drawable rotation past stale frames so the new layout reaches the screen reliably.

### Fixed
- **First page doesn't render on initial mode open** in single/double — `clipH = 0` on the first call to `rebuildSinglePage` / `rebuildDoubleSpread` produced a 1pt-wide documentView frame; now falls back to `containerWidth` and re-rebuilds via `clipViewGeometryChanged` once the clip view sizes up.
- **Top-bar bleed** — zoomed page no longer overlaps the 38pt reader top bar. CAMetalLayer's `direct-to-surface` compositing bypasses ancestor `masksToBounds`, so the metalLayer frame now subtracts `topInset` before intersecting with `docFrame`.
- **Image squish at low zoom / centred state** — shader now normalises page-rect doc coords against `metalLayer.frame` (the actual drawable) rather than `clipView.bounds`. Added `viewportOriginX` to the shader uniforms so X panning works correctly in single/double when the doc is wider than the clip.
- **Page-turn renders the wrong page** in single/double — `updateVisibleRange` short-circuits for these layouts to use `currentPage` directly; the previous binary-search-over-pageYOffsets path always collapsed to `0…0` and the renderer looked up `pages[0].id` instead of the current page.
- **Scale/docFrame desync** — `coordinator.scale` is now committed BEFORE `rebuildLayout()` runs, so the documentView frame uses the new zoom step rather than the previous-cycle value.
- **Centre on every zoom step** — block in `updateNSView` forces the documentView's centre to the viewport centre after any rebuild or scale change. `recenterIfContentFits` now uses the *usable* viewport (clip minus top inset) instead of full clip.
- **Mode-switch leaves single-page slightly off-centre** — `scrollView.magnification` is now reset to the new layout's pinned value on mode change (single/double pin to 1.0; vertical uses the live scale). Without this reset, a stale magnification from a previous vertical session shrank `clipView.bounds.size`, throwing off the centre math.
- **Mode-switch black state** — SwiftUI reuses the Coordinator/NSScrollView/CAMetalLayer across mode switches, so the first render after a layout change races with the layout commit and presents a stale drawable. The 3-stage render retry walks past it; `metalView.layoutSubtreeIfNeeded()` ensures the metalLayer geometry is current before the retries fire.
- **Loupe right-page never shown in double-page** — `findSequentialIndex` now hit-tests `pagePositions[pages[currentPage].id]` and `pagePositions[pages[currentPage+1].id]` directly for `.doubleSpread`. The previous walk over `pageYOffsets` indices looked up `sequentialToID[idx]` which pointed at `pages[0]/pages[1]` rather than the visible pages once `currentPage > 0`.
- **Loupe freezes mid-drag at the gutter** — when the target page's NSImage isn't yet decoded, `updateLoupe` now emits a fallback state using the last cached image so the loupe position keeps tracking the cursor.

### Changed
- **`ReaderViewModel`** — removed `currentImage`, `image(for:)`, `cacheVersion`, `offset`, and the `pageManager.onPageReadyNSImage` callback. All four modes drive their own re-renders via `MetalPageView`'s `onTextureReady` path; no SwiftUI cache-version bumping needed.
- **CHANGELOG**: consolidated five overlapping `Unreleased` entries from the migration arc (2026-04-24 → 2026-04-25) into this single v0.10.0 release.

### Removed
- `Sources/DC/Views/ZoomableImageView.swift` — entire file (230 lines): `ZoomableImageView`, `MouseCatcher`, `_MouseCatcherView`, `ScrollWheelModifier`, `ScrollWheelView`, `_SWView`, and the `View.onScrollWheel` extension. All callers retired.
- `SpreadView` struct + `computeLoupe` from `ReaderView.swift` (~167 lines).

### Technical notes (archive)

The migration uncovered a chain of Metal/AppKit/SwiftUI interactions that were each diagnosed via live telemetry sessions:

- **CAMetalLayer direct-to-surface compositing bypasses ancestor `masksToBounds`.** This was the root cause of the top-bar bleed and made the SwiftUI overlay loupe (which IS clipped by ancestor bounds) the right pattern over the NSPanel-based loupe.
- **NSScrollView's `contentInsets` shifts `clipView.bounds.origin` to negative values at the rubber-band-at-top state**, but the bounds-origin behaviour wasn't symmetric with our model — the carve-from-visible math had to handle both `origin = 0` (initial layout) and `origin = -topInset` (rubber band) cases.
- **SwiftUI reuses NSViewRepresentable Coordinators** when the surrounding struct type is preserved at the same view-tree position — even across `_ConditionalContent` branches that change associated values like our `layout` enum. This was unintuitive but explains why the texture ring persisted across mode switches and why the magnification-reset and 3-stage render retry were necessary.
- **CAMetalLayer's drawable rotation queue** can hold a stale frame from before a layout commit. The retry-render approach (multiple presents at 1ms/50ms/150ms intervals) is a pragmatic fix for the racing-commit problem; `presentsWithTransaction = true` would be the principled alternative if this ever needs revisiting.
- **`updateVisibleRange` fires many times in rapid succession during initial layout** (clip-view bounds-change notifications, layout-completed retries, render dispatches, frame-change notifications). Without the `prefetchInFlightRange` dedupe, each call cancelled the in-flight decode mid-flight.

---

## v0.9.0 — 2026-04-23

Reader decode cache unified. Single-page, double-page, vertical, and vertical-double modes now all decode through one shared `MetalPageManager` instance. `PageImageCache` retired.

### What changed
- **`MetalPageManager`** gained three new capabilities on top of its existing CVPixelBuffer ring (10-page LRU):
  - Parallel `NSCache<NSNumber, NSImage>` (cap 10, nonisolated) populated in `store(_:for:)` after each decode. Evicted in lockstep with the CVPixelBuffer — evictions happen through both `store`'s LRU overflow path and `evictOutside(_:)`.
  - `nsImage(for: Int) -> NSImage?` — nonisolated O(1) fast-path read for SwiftUI render paths.
  - `prefetch(around: Int, pages: [ComicPage])` — fire-and-forget, `[center-1 … center+3]` window (matches the old `PageImageCache` window). Evicts outside the window before scheduling decodes. Fires `onPageReadyNSImage` on the main actor after each successful decode+convert.
- **Shared converter.** `makeNSImageFromPixelBuffer(_:)` lifted to a file-level internal function in `MetalPageManager.swift`. `MetalPageView.Coordinator.nsImage(from:)` now forwards to it. Both the manager (for populating its NSImage cache) and the loupe (for CVPixelBuffer → NSImage conversion) go through the same helper.
- **`MetalPageView`** drops the `imageCache: PageImageCache?` parameter; instead takes `pageManager: MetalPageManager`. No longer creates its own `MetalPageManager()` in `makeNSView` — uses the injected instance so all reading modes share one decode cache. Loupe fast-path now reads `pageManager?.nsImage(for: seqIdx)` directly.
- **`ReaderViewModel`** replaces `let imageCache = PageImageCache()` with `let pageManager = MetalPageManager()`. `currentImage`, `image(for:)`, and `triggerPrefetch()` rewired to the new manager. Callback binding moves from `imageCache.onPageReadySwiftUI` to `pageManager.onPageReadyNSImage`, same filter on `currentPage` / `currentPage + 1` for `cacheVersion` bump granularity.

### Removed
- **`PageImageCache`** actor class (218 lines) deleted from `ReaderViewModel.swift`. No external callers; two stale doc-comment references in `MetalPageManager.swift` and `Comic.swift` are harmless and can be cleaned up in a follow-up.

### Memory footprint
Before v0.9.0 the reader kept up to 15 decoded pages in memory (5 NSImages in `PageImageCache` + 10 CVPixelBuffers in `MetalPageManager`). v0.9.0 holds at most 10 pages shared across every reading mode — each page as both a `CVPixelBuffer` and a derived `NSImage`. That's ~20 page-equivalents of memory worst case (up from ~15), but the ceiling is now hard and consistent across modes, not a 5+10-ceiling that appears on mode switches.

### Why this matters
This is step B of the two-step plan toward full Metal rendering in every reading mode. Step A (replacing `ZoomableImageView` with a Metal-rendered single/double page view) is now a mechanical view-layer substitution in a follow-up session: both renderers already pull from the same decode source. Every subsequent bugfix (loupe, prefetch, eviction, CBR/PDF support) lands in one place instead of two.

### Process notes
- Backup before: `/Volumes/Media/DC_dev_lib_backup_20260423_234635/` (SHA `eaf84360…`).
- Planned via spec `docs/superpowers/specs/2026-04-23-unify-decode-cache-step-b-design.md` + plan `docs/superpowers/plans/2026-04-23-unify-decode-cache-step-b.md`.
- Executed with the superpowers subagent-driven-development skill: five task commits with spec+quality review between each.
- Commits: `1023041` (helper), `7e82ced` (NSImage cache), `2fc7346` (prefetch + callback), `5a1ab1e` (inject + rewire — T4+T5 bundled per plan), `8049038` (delete PageImageCache).

### Verification
`swift build -c release` clean. `.app` produced. Per-task grep checks passed. Manual runtime verification of the four reading modes across CBZ / CBR / PDF + loupe is pending user smoke test.

---

## Unreleased — planned v0.9.0 (unify decode cache, step B toward full-Metal)

**Snapshot taken:** `/Volumes/Media/DC_dev_lib_backup_20260423_234635/` — 158 MB, full source tree + current `.app`, SHA-matched binary (`eaf84360…`). `.build/` excluded (rebuildable). This is the last-known-good state of v0.8.3 before the decode-cache unification.

### Planned work (step B)
Retire `PageImageCache` and route single/double-page mode through `MetalPageManager`:

- `ZoomableImageView` and `ReaderViewModel.image(for:)` will fetch NSImages from `MetalPageManager` instead of `PageImageCache`. The `CVPixelBuffer → NSImage` convert used by the vertical loupe is the same one we'll use for single/double display (already exists as `MetalPageView.Coordinator.nsImage(from:)`).
- `LibraryViewModel.imageCache` / `PageImageCache` / `onPageReady` / `onPageReadySwiftUI` wiring removed.
- Net memory ceiling drops from 15 pages (10 Metal + 5 NSImage) to **10 pages** shared across all reading modes.
- Loupe becomes fully unified — no more mode-specific fetching.

### Future work (step A, separate session)
After B stabilises: replace `ZoomableImageView` entirely with a `MetalPageView` single-page configuration. Uses `NSScrollView.magnification` for zoom (same as vertical modes) and a single-page or two-page quad layout in `MetalPageRenderer`. Deletes `ZoomableImageView`, `MouseCatcher`, `PageImageCache` (already gone after B).

---

## v0.8.3 — 2026-04-23

Two-button add flow. Replaces the three previous add affordances (toolbar Open Comic button, sidebar New Gallery, per-gallery Add Folders) with two:

1. **Sidebar `+ New Gallery`** — unchanged. Creates an empty gallery; user can name it and optionally add source folders during creation.
2. **Per-gallery `+ Add`** — gallery-pane toolbar's trailing action opens a **unified NSOpenPanel** that accepts files, folders, and multi-select in the same dialog. Result is smart-split into files-vs-folders and routed accordingly.

### Removed
- **Open Comic** button from `PaneToolbar`. The top library toolbar now shows only search / sort / zoom / debug. ⌘O still works via the menu-bar *File* command (kept in `DCApp`).
- The separate "Add Folders" button on `LibraryGalleryPane` (folders-only picker) is gone — replaced by the unified one.

### New API
- `LibraryViewModel.addComicFiles(_:to:)` — appends individual comic URLs to a gallery's `comics` array without scanning source folders. De-duplicates silently. Needed because the previous `addFolders` path only handled directories; now loose files land here.

### Picker
`pickComicsOrFolders(_:)` on `LibraryGalleryPane`:
- `canChooseFiles = true` · `canChooseDirectories = true` · `allowsMultipleSelection = true`
- `allowedContentTypes = [.pdf, cbz, cbr, cb7, cbt]` (custom extensions via `UTType(filenameExtension:)`)
- Title: "Add to Gallery" · message: "Choose comic files and/or folders."

After OK, `addToGallery(_:)` walks the returned URL list, checks `isDirectory` per URL, and dispatches: folders → `library.addFolders(folders, to: gallery.id)` (existing scan path), files → `library.addComicFiles(files, to: gallery.id)` (new method).

### Empty-gallery state
Empty-gallery placeholder updated: title "Empty Gallery", hint "Add comic files or folders to populate this gallery", action button "Add Comics or Folders…" — all routed through the same unified picker.

### Design rationale
Context determines destination: if you click `+` inside a gallery, contents go into *that* gallery, no modal decision. To read a one-off file without tracking, either drag onto the window (existing) or use File → Open Comic (⌘O). No top-level in-window "Open Comic" button.

---

## v0.8.2 — 2026-04-23

Fixed: CBR, CB7, CBT, and PDF comics were black pages in vertical / vertical-double reading modes (single-page and double-page worked fine).

### Root cause
`MetalPageManager.decodePage(pageIndex:from:)` only handled `PageSource.zipData` (in-memory CBZ). Every other variant — `.file(URL)` for `unar`/`tar`-extracted CBR/CB7/CBT, `.zip(URL, String)` for disk-backed archives, `.pdf(PDFDocument, Int)` for PDFs — fell through to `return nil` with a stub comment from v0.3.1 saying "let the existing pipeline handle these pages". The fallback NSImage pipeline (`VerticalComicScrollView`) was commented out in v0.4.0 and deleted in v0.5.0, so the stub quietly became a black page for every non-CBZ format.

Single-page and double-page modes stayed unaffected because they route through `ZoomableImageView` using `PageSource.decode()` (the general-purpose NSImage path), not the Metal pipeline.

### Fix
Replaced the stub with full decode coverage for every `PageSource` case:

- `.file(url)` → reads the file from disk and decodes via `CGImageSource` (same decode path as the CBZ entry bytes).
- `.zip(archiveURL, entryPath)` → opens the archive from disk, extracts the entry, decodes via `CGImageSource`. Shares a common helper with `.zipData`.
- `.pdf(doc, pageIndex)` → renders the PDF page through `PDFKit` at 2× scale on top of a white background (PDFs are opaque, so a white fill prevents the reader's black showing through transparent areas). Same `.mediaBox` bounds as the single/double-page path.
- `.zipData(…)` → unchanged behaviourally; refactored to share the archive-entry helper.

### Internal cleanup
Extracted three shared helpers:
- `makePixelBuffer(width:height:)` — single `CVPixelBufferCreate` with 32BGRA + Metal-compatible attrs.
- `renderCGImageToBuffer(_:)` — lock/draw/unlock wrapper for any `CGImage`.
- `decodeImageData(_:)` — ImageIO decode → `renderCGImageToBuffer`. Used by `.file` / `.zipData` / `.zip` branches.

Caching and LRU eviction (10-page cap) centralised in a new `store(_:for:)` method instead of being duplicated inside each decoder. `PDFKit` import added. Main decode switch statement is now readable top-to-bottom: one case per source variant, each returning the same buffer type.

All four formats now render correctly in all four reading modes (single, double, vertical, vertical-double).

---

## v0.8.1 — 2026-04-23

v0.8.0 added `.windowStyle(.hiddenTitleBar)` but the bar still looked stacked — `.hiddenTitleBar` only hides the title TEXT, it doesn't make content flow under the traffic-light region. The window's title bar slab was still there, 28 pt tall, above our custom bar.

**Fix — configure the NSWindow directly:** added `FullSizeTitleBarConfigurator`, an `NSViewRepresentable` that grabs the hosting `NSWindow` on appear and sets:
- `titlebarAppearsTransparent = true` — removes the opaque title-bar background so our custom strip behind it is visible.
- `titleVisibility = .hidden` — redundant with `.hiddenTitleBar` but explicit.
- `styleMask.insert(.fullSizeContentView)` — this is the key one: content view now extends up under the title-bar region instead of being pushed below it.

Attached to `ContentView` via `.background(FullSizeTitleBarConfigurator())` so the configuration applies across both library and reader sessions. Traffic-light controls now float over the same strip as the reader's 38-pt custom chrome.

SwiftUI unfortunately doesn't expose these three NSWindow knobs, so the NSViewRepresentable bridge is necessary. One-shot configuration; no teardown required (these settings persist for the window's lifetime).

---

## v0.8.0 — 2026-04-23

Reader top chrome redesigned — one integrated strip. Ended v0.6.x-v0.7.4's running fight with centring and color-matching by removing the native title bar entirely and making the reader's custom bar *be* the title bar.

### Hidden title bar on the scene
`DCApp` now attaches `.windowStyle(.hiddenTitleBar)` to the `WindowGroup`. The window's traffic-light controls (close/minimise/maximise) now live in the same row as the reader's custom chrome. There is no separate title bar above our controls any more, and therefore no second chrome strip for vibrancy/height to mismatch.

### Reader top bar integrated with traffic lights
`readerTopBar` now:
- Leads with a 72-pt spacer — reserves horizontal room for the traffic-light controls at the top-left.
- Back button sits immediately to the right of the gutter.
- Trailing cluster (favorite · ⋯ menu) pinned flush-right by the outer HStack's `Spacer()`.
- Transport cluster (prev-comic · prev-page · N/M · next-page · next-comic) is layered over the HStack via the ZStack's default `.center` alignment — geometrically centred at the window midpoint regardless of back/trailing widths.
- Bar height raised 36 → 38 pt to match the natural title-bar height.
- Horizontal padding tightened 10 → 8 pt since the gutter spacer now handles the left-side inset.
- Background still `TitlebarEffectView()` (`NSVisualEffectView` with `.titlebar` material + `.behindWindow` blending + `.followsWindowActiveState`) — identical vibrancy to the native window chrome.

### Library carried along automatically
`NavigationSplitView` on macOS already handles hidden title bars: its sidebar-toggle button and detail-pane toolbar content render in the chrome row next to the traffic lights, matching apps like Books/Photos. No library-specific changes needed.

Result: one 38-pt chrome strip at the top of the window containing the traffic lights and (in the reader) the back button, transport, favourite, and menu. No stacked bars. No color/height mismatch. Transport geometrically centred. Natively styled because it *is* the title bar.

---

## v0.7.4 — 2026-04-23

Custom top bar now visually identical to the native macOS title-bar chrome.

SwiftUI's `.background(.bar)` is close but uses a different vibrancy recipe than `NSToolbar`, so the v0.7.3 custom bar looked subtly different from the rest of the window — a more washed-out grey instead of the usual titlebar translucency.

**Fix:** swapped `.background(.bar)` for `.background(TitlebarEffectView())`, a tiny `NSViewRepresentable` wrapper around `NSVisualEffectView` configured with `material = .titlebar` + `blendingMode = .behindWindow` + `state = .followsWindowActiveState`. This is the exact same view AppKit uses for the window's own title bar, so the reader top bar matches the library's NSToolbar pixel-for-pixel (including the dim/bright shift when the window loses focus).

Everything else from v0.7.3 unchanged: 36 pt height, ZStack geometric centring, back button flush-left, trailing cluster flush-right, transport centred.

---

## v0.7.3 — 2026-04-23

Back on the left, transport geometrically centred.

The native `.toolbar { … .principal … }` centres the principal item between the leading and trailing clusters — which means the transport shifts whenever they have different widths. For true geometric centring, only a `ZStack` works.

Reintroduced the custom top bar from v0.6.x but with **native-default button sizes** (no `.font(.system(size:))` overrides this time):

- `ZStack { HStack { backButton; Spacer; trailingCluster }; transportCluster }`
- Back button pinned flush-left by the outer HStack.
- Trailing cluster (favourite + ⋯ menu) pinned flush-right by the outer HStack's `Spacer()`.
- Transport layered on top of the ZStack at its default `.center` alignment — lands at the bar's exact horizontal midpoint regardless of how wide the back and trailing clusters are.
- Bar height fixed at **36 pt** with 10 pt horizontal padding and `.bar` material background; `Divider` below separates it from the reader canvas.
- Buttons use their default button style so sizing matches macOS conventions — no custom fonts, no `.borderless` overrides.
- `.toolbar(.hidden, for: .windowToolbar)` hides the native NSToolbar row so the custom bar is the sole top chrome.

Back button: `Label("Library", systemImage: "chevron.left")`.
Transport: `« ‹ · ‹ · N / M · › · › »` with tooltips (Q/E, ←→/AD).
Trailing: favourite heart · ⋯ menu (Zoom / Reading Mode / Full Screen).

---

## v0.7.2 — 2026-04-23

Transport back in the native toolbar, floating pill removed.

v0.7.0/v0.7.1 moved the transport to a bottom-centre floating pill overlaid on the comic page. User preference is the classic placement — navigation buttons in the toolbar, not overlaid on content.

**Changes:**
- Removed the `transportPill` view and its `ZStack(alignment: .bottom)` overlay layer.
- Reader body is back to a simple `ZStack { black; modeContent }` without any floating chrome.
- `readerToolbarContent` now has four toolbar items:
  - `.navigation`: Back.
  - `.principal`: a `ToolbarItemGroup` with prev-comic · prev-page · `N / M` · next-page · next-comic — the full transport cluster, using native toolbar sizing and icons.
  - `.primaryAction`: Favorite toggle.
  - `.primaryAction`: `⋯ More` menu (Zoom · Reading Mode · Full Screen).
- Native macOS toolbar look throughout. `.principal` centres the cluster within the space between leading and trailing items — not geometrically perfect to the window centre, but it looks like a first-party Apple app.
- Tooltips still show keyboard shortcuts (Q/E, ←→/AD).

---

## v0.7.1 — 2026-04-23

Dropped the pill auto-hide — navigation buttons stay visible at all times.

**Why:** v0.7.0's `.onContinuousHover` lived on the reader's `ZStack`, but `ZoomableImageView` (single/double mode) and `MetalPageView` (vertical modes) both consume mouse events internally via their own `MouseCatcher` / `NSScrollView`. Hover events never bubbled up to the `ZStack`, so after the initial 2.5 s the pill hid and never came back — user saw no navigation at all.

**Fix:** kept the floating transport pill exactly as-is visually, but removed the `pillVisible` / `pillHideTask` / `pointerOverPill` state and the `.onContinuousHover` / `.onHover` handlers. Pill is now always rendered.

Simpler code, no event-plumbing fight, and the navigation is always one click away. If the cinematic fade-out is wanted later, the right way to do it is a window-level `NSEvent.addLocalMonitorForEvents(.mouseMoved)` + `acceptsMouseMovedEvents = true` on the reader's NSWindow — not SwiftUI hover. That's a separate ticket.

---

## v0.7.0 — 2026-04-23

Reader redesigned around a **floating transport pill** + **native top toolbar**. Five rounds of centring-fight on the custom bar (v0.6.4–v0.6.8) convinced me the engineered-looking bar was the problem, not the geometry inside it. Option B from the brainstorm: content-first, macOS-native chrome on top, transport pill at the bottom.

### Top bar
Back to `.toolbar { … }` with standard placements and sizes. Three items:

- `.navigation`: **Back** — `Label("Library", systemImage: "chevron.left")`.
- `.primaryAction`: **Favorite** — filled-heart toggle in red.
- `.primaryAction`: **⋯ More** — menu with Zoom · Reading Mode · Toggle Full Screen sections. Zoom In / Zoom Out keyboard shortcuts (⌘= / ⌘-) live on the menu items.

No custom heights, no dividers, no font overrides. Title shows via `.navigationTitle(vm.comic.title)`. Looks like a first-party Apple app.

### Transport pill
New floating capsule at the bottom centre of the reader:

- Contents: prev-comic · `|` · prev-page · **N / M** · next-page · `|` · next-comic. Same five controls that were fighting for space in the toolbar, now in a dedicated component that's always centred because it's laid out inside a `ZStack(alignment: .bottom)` overlay on the reader.
- Styled as an `.ultraThinMaterial` `Capsule()` with a subtle white stroke and a soft shadow. 16 pt icons, `.medium` weight, 14 pt page counter. 18 pt horizontal padding, 10 pt vertical.
- Offset 24 pt above the window bottom.
- Helps show keyboard shortcuts — `Q / E` for comic nav, `← → / A D` for page nav.

### Auto-hide behavior
- Pill is visible on reader open.
- Mouse movement anywhere in the reader (`.onContinuousHover(.active)`) resets a 2.5 s idle timer. When the timer fires, pill fades out over 180 ms + slides down 16 pt.
- `.onHover` on the pill itself: while the pointer is over the pill, the hide timer is cancelled so it stays visible indefinitely. Pointer leaves the pill → normal 2.5 s timer resumes.
- Implemented via `@State var pillHideTask: Task<Void, Never>?` cancelled and restarted on every movement.
- Pill is `.allowsHitTesting(pillVisible)` so invisible pill doesn't intercept clicks on pages underneath.

### Removed
- The custom `readerTopBar` VStack (v0.6.4–v0.6.8) and all its helpers: `transportCluster`, `trailingCluster`, `barIcon(_:weight:)`, `barIconSize`, `barHeight`.
- `.toolbar(.hidden, for: .windowToolbar)` — no longer hiding the native toolbar; the reader now uses it.
- The zoom `-`/`%`/`+` cluster from the toolbar. Zoom lives in the More menu with keyboard shortcuts. Scroll-wheel + pinch-zoom remain the primary zoom interactions.

Same keyboard shortcuts as before: arrows/WASD for pages, Q/E for comics, ⌘F for full screen, Backspace/Z for back. Z-order: reader content < pill < native toolbar (system chrome).

---

## v0.6.8 — 2026-04-23

Reader top-bar glyphs now centred both axes.

**Why they were bottom-aligned:** v0.6.7 set `.font(.system(size: 26))` on the outer ZStack and expected `Button { Image(systemName:) }` children to inherit. They don't — SwiftUI's `.borderless` button style renders its icon at the button-style's own default size (~13 pt) regardless of parent font. So the bar was 40 pt tall with tiny glyphs sitting wherever SwiftUI's button baseline put them: at the bottom.

**Fix:**
- Extracted a `barIcon(_:weight:)` helper that returns `Image(systemName:).font(.system(size: 26, weight:)).frame(maxHeight: .infinity)`. Called from every button label. The font now lives on the icon itself (not the container) so the button-style honours it, and `maxHeight: .infinity` lets the icon stretch to fill the button's vertical extent so it centres inside the bar.
- Every HStack now declares `alignment: .center` explicitly. Outer `ZStack(alignment: .center)` too.
- Both clusters carry `.frame(maxHeight: .infinity)` so they fill the full bar height before the icons centre within them.
- Bar height 40 → **44 pt** for a touch more breathing room around 26 pt icons.
- Divider heights 24 → 26 pt to match icon extent.
- Page counter font 16 → 17 pt-medium; uses `.frame(maxHeight: .infinity)` for proper vertical centring.

---

## v0.6.7 — 2026-04-23

Reader top-bar buttons doubled in size.

- Glyph size raised from SwiftUI's ~13 pt default to **26 pt** via a single `.font(.system(size: barIconSize))` on `readerTopBar` so all child buttons inherit. Back, transport, favorite, zoom, and overflow menu icons all scale together.
- Bar height grown 22 pt → **40 pt** to fit the larger glyphs with 7 pt of breathing room top and bottom.
- Divider heights raised from 16 pt to 24 pt so they visually match the new button extent.
- Page counter font raised from `.callout` to 16 pt-medium; min-width 72 → 88 pt to accommodate three-digit page totals.
- Zoom-percent text raised from `.caption` to 14 pt-medium; min-width 42 → 52 pt.
- Inter-cluster spacing: transport cluster inner spacing 6 → 10 pt; trailing cluster 10 → 14 pt; zoom cluster internal 4 → 6 pt.
- Overflow `Menu` frame 28 → 36 pt wide.

ZStack centring, `.toolbar(.hidden)`, and `.bar` background unchanged.

---

## v0.6.6 — 2026-04-23

Revert v0.6.5 (single-principal toolbar dropped buttons) and slim the v0.6.4 custom bar. The `ToolbarItem(placement: .principal)` single-item approach refused to lay out the inner `HStack { back; Spacer; trailing }` + ZStack transport as expected in the macOS toolbar row — SwiftUI collapsed or clipped the content and the back/trailing buttons disappeared.

**Fix:** back to v0.6.4's custom bar below the title bar (VStack of `readerTopBar` + `Divider` + reader content) with `.toolbar(.hidden, for: .windowToolbar)` suppressing the native toolbar. Reduced bar height from 38 pt to **22 pt** — the transport/zoom button icons are ~14 pt, so 22 pt gives 4 pt top/bottom padding and no more; the empty space above the buttons that felt chunky in v0.6.4 is gone. Horizontal padding stays at 14 pt for edge breathing room. ZStack centring from v0.6.4 preserved.

---

## v0.6.5 — 2026-04-23

Reader top bar: slim it back down into the native toolbar row.

v0.6.4 moved the reader controls into a custom bar below the title bar and hid the native `NSToolbar`. The transport centring worked, but the window now had two stacked top regions — the (empty) title bar above the custom bar — which felt chunky and wasted vertical space.

**Fix:** go back to `.toolbar { … }` but as a **single** `ToolbarItem(placement: .principal)` containing the whole ZStack. Because there are no separate leading/trailing toolbar items competing for width, the principal item fills the title-bar width, and its internal `ZStack { HStack { back; Spacer; trailing }; transport }` keeps the transport geometrically centred. Added `.frame(minWidth: 640, idealWidth: 960, maxWidth: .infinity)` to the inner content so the toolbar item expands to let the HStack's Spacer actually push the clusters to opposite edges.

Result: same centred layout as v0.6.4, rendered inline in the native toolbar row — no second bar, no empty dead space above the controls.

---

## v0.6.4 — 2026-04-23

Reader top bar: true-centre layout.

### Why `.principal` wasn't centring
The previous pass used `ToolbarItem(placement: .principal)` for the transport cluster with leading/trailing items alongside. `.principal` on macOS is centred *between the leading and trailing groups*, not within the window — and because our leading (back button) is ~30 pt while trailing (favorite + zoom + menu ~200 pt), the principal shifts toward the leading side. No amount of reshuffling inside `.principal` fixes that.

### Fix — custom top bar with ZStack centring
Retired `.toolbar { … }` for the reader entirely. A new `readerTopBar` renders above the reader content as a `VStack`-child custom bar:

- `ZStack { HStack { backButton; Spacer(); trailingCluster }; transportCluster }` — back pinned to the leading edge, trailing cluster pinned to the trailing edge, transport layered on top and geometrically centred via the ZStack's default alignment.
- The transport is therefore at the bar's exact horizontal midpoint regardless of how wide the back button or the trailing cluster are. Widening favourite/zoom/menu no longer shifts the page counter.
- Applied `.toolbar(.hidden, for: .windowToolbar)` on the reader so the native `NSToolbar` is hidden while a comic is open — the custom bar is the sole top chrome. The window's traffic-light controls remain visible because they live in the title bar, not the toolbar.
- Bar height fixed at 38 pt, `.bar` material background for consistency with the sidebar footer, `Divider()` below separating it from the page area.
- Every button switched to `.borderless` style with `.help(…)` hover hints for the keyboard shortcuts (`← → W A S D Q E` + `⌘F`).

The reader returns to the library via the `←` back button or the existing `Backspace`/`Z` keyboard shortcut, both of which also persist the reading position before dismissing.

---

## v0.6.3 — 2026-04-23

Reader-toolbar layout pass and library comic-removal UX.

### Reader toolbar cleanup
The reader's centered navigation and trailing controls were packed into two large `ToolbarItemGroup`s (5 items in principal, 7 in primary action), so macOS could never balance them around the window title — the page counter drifted off-centre and individual buttons lost their hit targets on narrower windows. Rewrote both clusters:

- **Principal (centered):** a single `ToolbarItem` containing an `HStack` of prev-gallery · vertical divider · prev-page · page counter · next-page · vertical divider · next-gallery. Fixed minimum widths on the counter, explicit `help(...)` strings on every button, consistent 6-pt spacing. Centres as one atomic unit instead of five loose items.
- **Trailing:** three compact `ToolbarItem`s — favorite toggle · zoom cluster (zoom-out · "N%" · zoom-in) · overflow menu. Moved Reset Zoom, Fit to Width, Actual Size, reading-mode switch, and full-screen toggle into the overflow menu (organised into Zoom / Reading Mode / sections with `⌃⌘F` for full screen). Fewer top-level buttons, consistent layout on any window size.

### Remove individual comics from a gallery
Right-click any comic in a gallery → **"Remove from Gallery"** (destructive, red). Keyboard path: single-click selects the card (3-pt accent-colour border + title tinted), Delete key removes it. Double-click still opens. Clicking on empty space in the pane clears the selection.

- `ComicCard` gained an optional `isSelected: Bool`, rendered as a `RoundedRectangle` stroke at `Color.accentColor`, animated over 120 ms.
- `LibraryGridPane`, `LibraryGalleryPane`, and `DraggableComicGrid` each maintain their own `@State private var selectedURL: URL?`. Selection is per-pane; switching sidebar rows resets naturally because the parent view rebuilds.
- Click-to-open was demoted to double-click (`.onTapGesture(count: 2)`) so single-click can select. This matches Finder and is what macOS users expect from a gallery grid.
- Delete-key wiring via a hidden `Button(label: EmptyView()).keyboardShortcut(.delete)` in each pane's `.background`, disabled when `selectedURL == nil`. Each pane's removal action is scoped:
  - Favorites → `toggleFavorite(url:)`
  - Recents → `removeRecent(_:)`
  - All Comics → new `LibraryViewModel.removeFromLibrary(url:)` — drops the URL from every gallery, from recents, and from favorites in one call (file on disk untouched).
  - Gallery pane → `removeComics(_ urls:from:)` against the active gallery.
- Context-menu labels adapt per pane: *Remove from Favorites / Recents / Library / Gallery*.

### Delete-key scoping
The sidebar intentionally does **not** bind `.delete` to "Delete Gallery". Gallery deletion is an intentional destructive action and stays behind the right-click context menu (`Delete Gallery`, destructive) to avoid conflicting with the comic-removal shortcut when a gallery row and a comic are both selected. This matches the user's stated design: "press delete on a highlighted comic".

---

## v0.6.2 — 2026-04-23

Audit-driven fixes. Two bugs, two perf wins, one UX polish, plus cleanup.

### Fixed — drag-and-drop visual rejection
Both the window-level drag-to-import handler (`handleLibraryDrop`) and the per-sidebar-row drop handler (`LibrarySidebar.handleDrop`) set their accept flag *inside* the async `NSItemProvider.loadObject(ofClass:)` callback and returned it from the synchronous enclosing method. The return always ran before the callback, so SwiftUI always read `false`, displayed a rejection cursor, and the user saw the drop "bounce back" — even though `library.load(url:)` / `library.moveComic(_:toGallery:)` actually completed. Both handlers now eagerly return `true` when any provider conforms to `public.file-url` and do the real work in the async callback.

### Fixed — deleted-gallery dead end
Deleting the currently-selected gallery left `LibraryDetail` rendering a permanent `Text("Gallery not found")` until the user clicked elsewhere. Fix in two places: `LibraryViewModel.deleteGallery(id:)` now clears `selectedSection` back to `.home` if the deleted gallery was selected, and the detail-pane fallback case snaps to `.home` via `.onAppear` if the stored selection resolves to a missing gallery.

### Perf — mtime cache for Recently Added sort
`LibrarySort.apply(.recentlyAdded, …)` and `LibraryHome.recentlyAdded` previously called `FileManager.attributesOfItem` synchronously on the main actor for every URL, every render. `LibrarySort` now keeps a process-lifetime `[URL: Date]` mtime cache, populated on first lookup per URL. Subsequent sorts and home-view rail refreshes are O(1) per URL. Safe because file mtimes are effectively static during an app session; any stale values clear on relaunch.

### Perf — memoised `allComicURLs`
`LibraryViewModel.allComicURLs` was an O(n+m) computed property re-evaluated every time `LibraryDetail`'s body ran — which meant every thumbnail-update publish, every search keystroke, every sort change. Added a backing store plus a coarse signature (sum of per-gallery comic counts + recents count). Invalidation happens whenever any comic is added/removed; no-op renders return the cached array in O(1). Gallery renames and pure reorderings (no count change) reuse the cache correctly since the URL set is identical.

### UX — loading overlay
`LibraryViewModel.isLoading` was still set during `load(url:)` but nothing read it after the stacked-sections view was retired. Slow CBR/CB7 extraction left the user staring at an unchanged library for several seconds. Added a `LoadingOverlay` (material-backed card with `ProgressView` + "Opening comic…") that fades in whenever `library.isLoading` is true.

### Cleanup
- Removed three dead computed properties from `LibraryViewModel`: `filteredRecentComics`, `searchResults`, `filteredGalleries` — their callers were all in the pre-v0.6.0 stacked-sections view; every new pane does its filtering inline.
- Modernised the two deprecated `onChange(of: library.updatedThumbnailURLs) { urls in … }` closures (in `ContinueReadingHero` and `ComicCard`) to the macOS-14 two-parameter form `{ _, urls in … }`.

### Carried forward (not addressed this round)
- Pre-existing concurrency warnings in `ReaderViewModel` / `ComicLoader` / `Comic` / `MetalPageManager` / `DCLogger` (Swift 6 hazards and ZIPFoundation deprecated initializers) — separate Swift 6 readiness pass.
- `ComicCard` non-favourite heart button still hover-only; acceptable for a desktop app.
- `LibraryView.swift` is ~1270 lines; candidate for splitting into `LibrarySidebar.swift` / `LibraryHome.swift` / `LibraryDetail.swift` if it grows further.

---

## v0.6.1 — 2026-04-23

Library hotfixes after v0.6.0.

### Reader toolbar collision
`LibraryDetail` previously attached `.toolbar { … }` with Open Comic (⌘O), the memory-debug toggle, and a "N comics" leading item. Because `ContentView` keeps `LibraryView` mounted under the reader (dimmed to opacity 0 so its `NSScrollView` keeps its scroll position), SwiftUI's toolbar system kept merging those items into the window toolbar even while the reader was active — they stacked on top of `ReaderView`'s own toolbar and pushed the reader controls off-screen.

**Fix:** removed the `.toolbar` modifier from `LibraryDetail` entirely. Open Comic, the debug toggle, and the section count now live inside each pane's `PaneToolbar` so they only render when a library pane is actually being drawn. `LibraryHome` now also has a `PaneToolbar` header for consistency. A divider separates the pane-scoped controls (search/sort/zoom/pane-specific actions) from the global library controls (Open Comic, debug).

### Create Gallery affordance
The "New Gallery" button at the bottom of the sidebar used `.buttonStyle(.plain)` with secondary foreground — it read as inactive chrome rather than a call-to-action, and users missed it entirely. Replaced with a full-width `.borderedProminent` button using `plus.circle.fill`. Same sheet wiring (`CreateGallerySheet`), just visible now.

### Per-pane count badge
`PaneToolbar` now shows the current section's count in a capsule next to the title (`Home → total comics`, `Favorites → favouriteURLs.count`, `Recents → recentComics.count`, `All Comics → allComicURLs.count`, `Gallery → gallery.comics.count`). Replaces the old leading-toolbar-item stat that was dropped along with the `.toolbar` modifier.

---

## v0.6.0 — 2026-04-23

Library redesign. `LibraryView` moves from a stacked-sections `ScrollView` to a two-column `NavigationSplitView`, with a Home view, per-pane toolbars, and richer interaction. All prior functionality preserved.

### New architecture
- **Sidebar:** Home · Favorites · Recents · All Comics, then a "Galleries" section listing each user gallery with a count badge. A "+ New Gallery" button sits at the bottom of the sidebar. Sidebar selection (`LibrarySection`) is persisted to `UserDefaults` so the app restores the same view on relaunch.
- **Detail pane:** content router keyed by the selected sidebar row.
  - `Home`: `LibraryHome` with a "Continue Reading" hero (last-opened comic with 0 < progress < 1, cover + title + linear progress + Resume button) plus horizontal rails for Recently Added, Favorites, and Continue Reading. Each rail has a "See All" that jumps to the matching sidebar row.
  - `Favorites`/`Recents`/`All Comics`: `LibraryGridPane` renders a `LazyVGrid` of `ComicCard`s.
  - `Gallery(id)`: `LibraryGalleryPane` — uses `DraggableComicGrid` when sort order is manual and no search is active (preserves per-gallery drag-to-reorder), otherwise a sorted/filtered grid.
- **Per-pane toolbar:** each detail pane gets a toolbar with a scoped search field, a sort menu (Custom Order only on galleries; Recently Added · Recently Read · A–Z · Progress · Format elsewhere), a card-size menu (Small/Medium/Large/Extra Large), and section-specific actions (Add Folders on gallery panes). Global "Open Comic" (⌘O) and memory-debug toggle sit in the standard window toolbar.
- **Drag-to-import:** drop CBZ/CBR/CB7/CBT/PDF files anywhere on the library window to open immediately; a dashed accent-coloured drop-zone overlay shows while the drag is over the window.
- **Drag between galleries:** drag a comic card onto a gallery row in the sidebar to move it to that gallery. Intra-gallery drag-to-reorder is unchanged.

### New interactions
- Hover on `ComicCard`: soft elevation (shadow opacity 0.25→0.45, radius 4→8), 3% scale-up, and the heart button fades in for non-favourites (always visible on favourited cards).
- Card size is a global preference; applies to all panes and persists.
- Sort preference is per-section and persists (stored as `[sectionKey: sortOrder]` in `UserDefaults`).
- Error banner: `errorMessage` from `LibraryViewModel` now surfaces as a dismissible banner over the library, replacing the full-pane error view.

### Model additions (`LibraryViewModel`)
- `selectedSection: LibrarySection?` — sidebar selection, persisted.
- `cardSize: CardSize` — global card size preference, persisted.
- `sortPreferences: [String: LibrarySortOrder]` — per-section sort, persisted.
- `allComicURLs: [URL]` — flat deduplicated list across all galleries + orphan recents; backs the All Comics pane.
- `continueReadingURL() -> URL?` — picks the most-recently-opened comic with a reading progress strictly between 0.02 and 0.98; falls back to the most recent overall.
- `moveComic(_:toGallery:)` — removes a comic from any gallery that contains it and appends to the target gallery.
- `loadNewLibraryState()` called from `init()` restores the three persisted values.

### New types (`LibraryTypes.swift`)
- `LibrarySection`: `Hashable`/`Codable` enum — `.home`, `.favorites`, `.recents`, `.allComics`, `.gallery(UUID)`.
- `CardSize`: four cases mapping to adaptive-grid minimums 140 / 180 / 240 / 320 pt and per-size title font sizes.
- `LibrarySortOrder`: six cases (`manual`, `recentlyAdded`, `recentlyRead`, `alphabetical`, `progress`, `format`). `LibrarySort.apply(_:to:library:)` implements each against `FileManager.attributesOfItem`, the recents list, or plain string/extension comparisons.

### Removed
- Stacked-sections `ScrollView` with `GallerySectionHeader`s (`Favorites`, `Recent`, per-gallery collapsible headers).
- `LibraryViewModel.collapsedSections` and `hasLaunched` — no longer meaningful under sidebar selection.
- Old global header (stats + centered search) — stats moved to toolbar leading, search moved into each pane's toolbar.
- Old `emptyState` / full-pane `errorView` — replaced by `EmptyPane` per detail pane and `ErrorBanner` overlay.

### Build script
- `build_app.sh` was hard-coded to `/Volumes/Media/DC_dev`. `DC_dev_lib`'s copy now points at `/Volumes/Media/DC_dev_lib` so each working tree has an independent `.app` output.

---

## v0.5.1 — 2026-04-23

Loupe polish in vertical modes.

### Wrong-page content while scrolling — coordinate pipeline rewrite
**Root cause:** `updateLoupe` computed the document-space point by adding `clipView.convert(windowPt, from: nil)` and `clipView.bounds.origin`. `NSClipView.isFlipped` mirrors `documentView.isFlipped`, but the mirror isn't always in sync during transient layout states — the two-step composition occasionally produced a document Y that lagged the true scroll position, so `findSequentialIndex` resolved a page that wasn't actually under the cursor and the loupe showed content from a page further up or down the document.

**Fix:** Replaced the manual composition with `scrollView.documentView.convert(windowPt, from: nil)`. The documentView is authoritative for its own coordinate system (including `isFlipped`), so the window → document-space conversion now happens in one step with no synchronisation assumptions. The loupe tracks the correct page through arbitrary-length scrolls in both vertical and vertical-double.

### Stale SwiftUI state when reusing the hosting view
**Root cause:** The loupe panel reassigned `NSHostingView.rootView = AnyView(magnifier)` when the page under the cursor changed. With `AnyView` erasure the host occasionally carried over the previous page's internal SwiftUI state, producing a stale image at the new cursor coords even though the inputs were correct.

**Fix:** Added a `loupeHostPage: Int?` tracker. When `page != loupeHostPage`, the current `NSHostingView` is removed from the panel and a brand-new instance is installed. `MagnifierView` is also tagged `.id(page)` so even within a single host, SwiftUI treats each page as a distinct identity and rebuilds the Canvas from scratch.

### Async-fetch race
**Root cause:** Each right-mouse-drag spawned a Task to decode the page's pixel buffer. Fast drags queued several Tasks whose captured `cursorInImageView` / `windowPt` were stale by the time they resolved, so a late Task could paint a previous page's image at the wrong position on top of the newest correct frame.

**Fixes:**
- `loupeTaskID` monotonic counter incremented at every `updateLoupe` entry. Each Task captures its ID at dispatch and checks it before calling `showMagnifier` — stale Tasks are silently dropped.
- Prior `loupeTask` is cancelled before a new one is spawned; `Task.isCancelled` is checked before the expensive `CGContext.makeImage()` conversion.
- If `MetalPageManager.page(for:)` returns `nil` (page not prefetched yet), the Task now falls back to `decodePage(pageIndex:from:)` with the captured `PageSource`. Loupe works even while the user scrolls faster than the visible-first prefetch.

### Scroll-without-mouse-move refresh
**Root cause:** A trackpad or scroll-wheel scroll doesn't fire `rightMouseDragged`, but the document slides under the fixed-on-screen cursor. Without a refresh, the loupe kept showing the page that *was* under the cursor before scrolling.

**Fix:** `scrollDidChange` now triggers `updateLoupe` using the live cursor location from `NSEvent.mouseLocation` → `window.convertPoint(fromScreen:)`. Guards include `loupePanel != nil` (loupe is active) and `scrollView.bounds.contains(scrollViewLocal)` (cursor is actually over the scroll area), so the refresh is skipped when the cursor has strayed onto the toolbar or window chrome.

### Unified left-click loupe across all reading modes
Single and double page already bound the loupe to left-click (`ZoomableImageView` → `MouseCatcher` intentional button swap). Vertical and vertical-double were bound to right-click. The `NSEvent` monitor now listens for `.leftMouseDown / .leftMouseDragged / .leftMouseUp` so the gesture is the same in all four modes: left-click-and-hold to show, drag to move, release to dismiss. The monitor still returns the event (doesn't consume) so scroll-wheel / pinch / trackpad gestures continue to work during the drag.

### Cursor hidden for the duration of the loupe
- Added a `cursorHidden: Bool` state tracker so `NSCursor.hide()` / `unhide()` calls stay balanced — macOS auto-unhides the cursor when it leaves the application window, which breaks naive pair counting.
- `hideCursorIfNeeded()` is re-asserted on every `rightMouseDragged` and on the scroll-driven refresh, defending against any auto-unhide that happens mid-drag (e.g. when the child panel is attached).
- `showCursorIfNeeded()` on right-mouse-up, `hideLoupe()`, and in `deinit` (best-effort) — guarantees the cursor reappears even if the view is torn down while right-click is still held.

---

## v0.5.0 — 2026-04-23

Vertical-reader bug fixes and cleanup. The Metal pipeline introduced in v0.3.1/0.4.0 shipped with three compounding rendering bugs that this release addresses, plus the first working loupe in vertical modes.

### Vertical stretch — CAMetalLayer sublayer architecture
**Root cause:** `MetalCanvasView` was `NSScrollView.documentView` with a frame matching the full stacked-pages height (tens of thousands of points), and its backing layer was a `CAMetalLayer` directly. `CAMetalLayer.contentsGravity` defaults to `.resize`, so a viewport-sized drawable (~1078 pt tall) was scaled to fill the full-document layer — ~94× vertical stretch, then cropped by the clip view. Pages in vertical and vertical-double modes appeared grossly elongated.

**Fix:** `MetalCanvasView.makeBackingLayer()` now returns a plain `CALayer`; `CAMetalLayer` is added as a sublayer. A new `updateMetalLayerFrame()` pins the sublayer to the visible `clipView.bounds` (position + size) and sets `drawableSize = visible × contentsScale`, wrapped in `CATransaction.setDisableActions(true)` so the sublayer snaps without tweening. Called from `layout()`, the scroll handler, and before every `nextDrawable()`.

### Fast-scroll page drop-off — four memory-neutral fixes
**Root cause:** Each scroll event spawned a fresh prefetch `Task` without cancelling earlier ones; prefetch decoded pages in `firstIdx → lastIdx` order so off-screen lookahead pages decoded *before* the actually-visible pages; `render()` called `renderer.evictOutside(visibleRange)` every frame and purged freshly uploaded prefetch pages; and renders only fired on scroll events, so a page whose decode landed *after* the last scroll stayed black.

**Fixes, all memory-neutral (both rings stay at the existing cap of 10):**
- `prefetchTask` handle on the coordinator; cancel the prior task before starting a new one; `Task.isCancelled` checked between decodes.
- Prefetch order is now the visible range first, then lookahead pages fanning outward by `±1, ±2, …` offsets.
- Short-circuit for pages already in the texture ring before asking the actor to decode.
- Re-render on upload: `onTextureReady(seqIdx)` fires a `render(visibleRange:)` if the just-uploaded page is in the current visible range.
- Removed the per-frame `renderer.evictOutside(visibleRange)` call. The `TextureRingBuffer` (cap 10) and `MetalPageManager.decodedPages` (cap 10) already bound memory via LRU.

### Vertical-double rendering
**Root cause:** `pageYOffsets` was indexed by *row* while `pagePositions` was indexed by *page id*. The visible-range binary search returned row indices but the render loop resolved them through `pages[rowIndex]`, addressing the wrong page for every row past the first. The binary search also returned the rightmost match on Y-ties, clipping the leftmost page of the top visible row and the rightmost of the bottom. On top of that, the `composeSpread` compute kernel waited for *both* halves of a pair before producing a spread texture, so a slow-decoding right half blanked the entire row.

**Fixes:**
- `rebuildLayout()` double-page branch now appends `pageYOffsets` twice per pair (left and right sharing the same Y). Everything downstream is consistently page-indexed, matching single-page mode.
- `updateVisibleRange()` walks left from `firstVisible` and right from `lastVisible` across duplicate-Y entries so both halves of a row are always in range.
- `findSequentialIndex(at:)` walks across the same-Y page run and returns whichever page's horizontal bounds contain the cursor — so the loupe hit-tests correctly on left and right halves.
- Removed the spread composition path entirely. Left and right pages render as two independent quads from their individual `pagePositions` rects, so each page appears the instant its own texture uploads.

### Loupe for vertical and vertical-double
Vertical reading modes now have the same right-click-hold magnifier that single/double-page mode has.

- Right-mouse events captured via a window-local `NSEvent.addLocalMonitorForEvents` monitor (not a subview) so scrolling, pinch-zoom, and scroll-wheel zoom keep working.
- The same SwiftUI `MagnifierView` (Canvas-based, 1.45× magnification, circular clip) that single/double-page mode uses is hosted inside a borderless non-activating child `NSPanel` attached to the main window via `addChildWindow(_:ordered:)`. Using a panel rather than a subview of `window.contentView` avoids SwiftUI's `WindowGroup`-managed hosting view stripping foreign subviews on its own layout passes (which was silently killing the loupe under the initial implementation).
- Source NSImage is resolved in order: (1) one-entry cache of the last cursored page so drag-moves are instant; (2) `PageImageCache` if the page is already decoded for single/double mode; (3) async snapshot from the `CVPixelBuffer` held by `MetalPageManager` via `CGContext.makeImage()`. Memory overhead: one NSImage (~10 MB) bounded by the cache being replaced on page change.
- Panel teardown uses `removeChildWindow` + `orderOut` on right-mouse-up.

### Cleanup
- Deleted the 806-line commented-out `VerticalComicScrollView.swift` (replaced by `MetalPageView` in v0.4.0) and the `/* OLD: */` block in `ReaderView.verticalScrollView(...)`.
- Removed the old pre-MagnifierView loupe infrastructure: `MetalLoupeOverlayView`, `LoupeMetalView`, `MetalLoupeView`, `MetalPageRenderer.renderLoupe`, `loupePipeline`, and the `loupeKernel` in `Shaders.metal`. Never worked in vertical modes (overlay sibling blocked scrolling; compute-kernel radius units were wrong).
- Removed the dead spread composition path: `SpreadInfo`, `Coordinator.spreads`, `MetalPageRenderer.spreadTextures`, `setSpreads`, `composeSpread`, `renderSpreadIntoTexture`, `spreadTexture(for:)`, `blitPipeline`, and `composeSpreadKernel` in `Shaders.metal`.
- Removed `MetalPageRenderer.evictOutside` / `TextureRingBuffer.evictOutside` (no callers after the per-frame evict was dropped).
- Removed `MetalPageRenderer.uploadImage` (unused).
- Removed `MetalPageManager.device` field and `init(device:)` parameter (unused) and the `import Metal` that only existed to type that parameter.
- Trimmed chatty per-render/per-upload/per-loupe diagnostic `DCLogger` calls added while fixing the above.

### Shader
- `Shaders.metal` `vertexShader` previously clamped `viewY` into `[0, 1]` to "keep pages inside the viewport", which squashed off-viewport vertices onto the viewport edges while the texcoords interpolated unchanged — this was the second, subtler half of the vertical-stretch bug. Clamp removed; the rasterizer's NDC clipping handles the visible slice correctly.

---

## v0.4.1 — 2026-04-22

### Bug Fix — 1× Drawable / backingScaleFactor

**Root cause:** `NSScreen.main?.backingScaleFactor` returned 1.0 instead of 2.0 on Retina displays. Since the value was not nil, the `?? 2.0` fallback never triggered, causing all Metal drawables to be created at 1× scale instead of 2×.

**Fix:** Replaced `NSScreen.main?.backingScaleFactor` with `NSScreen.screens.first?.backingScaleFactor` at both sites in `MetalPageView.swift`:
- `setup()` (line 75) — `metalLayer.contentsScale`
- `makeBackingLayer()` (line 318) — `MetalCanvasView`

**Logging added:**
- `[MetalPageView] setup: NSScreen.screens.first?.backingScaleFactor = ...`
- `[MetalCanvasView] makeBackingLayer: NSScreen.screens.first?.backingScaleFactor = ...`

**Build:** Verified clean (`swift build`).

---

## v0.4.0 — 2026-04-20

### Metal Rendering Pipeline — Complete

All vertical/vertical-double reading modes now use the Metal GPU pipeline.

**Task 3 — TextureRingBuffer:**
- Extracted `TextureRingBuffer` struct with `maxSize=10`, `insert()`, `touch()`, `subscript`, `evictOutside()`
- Replaced inline dict with `TextureRingBuffer` instance in `MetalPageRenderer`

**Task 4 — Metal render pipeline:**
- All pipeline components verified: `CAMetalLayer` → `drawable` → `commandBuffer` → `renderEncoder` → textured quads
- Rasterizer: `framebufferOnly=true`, BGRA8 pixel format consistent throughout
- Texture upload: `CVMetalTextureCacheCreateTextureFromImage` path verified
- `Shaders.metal` declared as resource in `Package.swift`

**Task 5 — NSScrollView wiring:**
- Fixed page ID vs sequential index key mismatch throughout Coordinator
- Fixed `onPageChanged`/`onOffsetChanged` to pass sequential indices
- Fixed `render()` to translate sequential→page.id for GPU rect lookup
- Fixed scale feedback loop with dedicated `lastScale` comparison anchor
- Fixed `magnificationDidChange` to update coordinator state
- Fixed `scrollToFraction` division-by-zero guard
- Fixed double-column height calculation in `rebuildLayout()`
- Added `sequentialIndexAtCenter()` helper

**Task 6 — Vertical double mode:**
- GPU spread composition via `composeSpreadKernel` compute shader
- `MetalPageRenderer`: `SpreadInfo` struct, `spreadTextures` dict, `blitPipeline` compute pipeline
- `MetalPageView`: `spreads` dict built in `rebuildLayout()`, synced via `setSpreads()`, `render()` composes visible spreads
- `pagesPerRow==2` now composites left+right into single spread quad per row

**Task 7 — Loupe:**
- `loupeKernel` compute shader — 2× reduced magnification, circular clip
- `MetalPageRenderer`: `loupePipeline` + `renderLoupe()` for GPU loupe rendering
- `MetalLoupeOverlayView` intercepts rightMouse events, converts coordinates to document space
- `LoupeMetalView` renders loupe texture via blit copy; `MetalLoupeView` bridged via `NSHostingView`
- Right-click/hold activates, follows cursor, circular clip with 2× magnification

**Task 8 — Memory verification:**
- Two-ring architecture confirmed: `MetalPageManager` (CVPixelBuffer, 10-page cap) + `MetalPageRenderer.textureRing` (MTLTexture, 10-page cap)
- Both rings wired with LRU eviction in render path
- `scripts/memory_ring_test.sh`: 6-point verification script
- `.agent/Memory_Verification.md`: architecture docs and verification steps

**Task 9 — Old reader removed:**
- `VerticalComicScrollView` commented out (replaced by `MetalPageView`)
- `verticalScrollView()` in `ReaderView` now routes `.verticalScroll` and `.verticalDouble` to `MetalPageView`
- Build: `swift build -c release` produces clean `.app`

---

## v0.3.1 — 2026-04-20

### Metal Rendering Pipeline — Phase 1

**New files:** `MetalPageView.swift`, `MetalPageRenderer.swift`, `MetalPageManager.swift`, `Shaders.metal`

**Critical bugs fixed:**
- `triggerPrefetch` passed empty `Data()` to `decodePage` — CGImageSource returned nil for all pages. Fixed: now extracts `.zipData` from `PageSource` enum via pattern matching.
- `render()` never called `upload()` — the texture ring was always empty, all pages rendered black. Fixed: `render()` now fetches decoded `CVPixelBuffer` from `pageManager` and uploads to `renderer` texture ring before encoding.
- `MetalPageManager.page(for:)` didn't update `lastAccessTimes` — LRU eviction always evicted the same page regardless of access pattern. Fixed: `lastAccessTimes[pageIndex] = Date()` on every access.
- `MetalPageManager` LRU eviction used `dict.keys.first` (arbitrary ordering) instead of true LRU. Fixed: `lastAccessTimes.min(by:)` finds the least-recently-used entry.

**Architecture:** Two-ring design — `MetalPageManager` (actor) holds decoded `CVPixelBuffer`s, `MetalPageRenderer` (struct) holds uploaded `MTLTexture`s. Both rings are 10-page capped with LRU eviction.

---

### v0.3.1 — 2026-04-20 (continued)

**Task 2 — CBZ decode pipeline:**
- `decodePage` now uses `ZIPFoundation.Archive` to extract the correct entry bytes from `.zipData`, then decodes via `CGImageSource`
- `MetalPageRenderer` added `MTLRenderPipelineState` — loads shaders from default library, sets pipeline on encoder
- `triggerPrefetch` now passes `PageSource` enum directly to `decodePage`

**Race condition fixed:**
- `render(visibleRange:)` is now `@MainActor async` — uploads visible pages synchronously before encoding, eliminating the race where background `Task` uploads raced with `commandBuffer.commit()`

---

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
