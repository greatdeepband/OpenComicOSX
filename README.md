# Open Comic

A native macOS comic book reader built with SwiftUI, AppKit, and Metal. Designed for large libraries, smooth reading, and pixel-perfect vertical scrolling.

## Download

**Requirements:** Apple Silicon Mac (M1 or newer), macOS 14 (Sonoma) or later.

**Option A — direct download (no build needed):**

1. Grab the latest **`OpenComic-<version>.zip`** from the [**Releases**](https://github.com/greatdeepband/OpenComicOSX/releases/latest) page.
2. Unzip it and move **`OpenComic.app`** into `/Applications`.
3. First launch: because the app is ad-hoc signed (not notarized through an Apple Developer account), Gatekeeper blocks it the first time. **Right-click the app → Open → Open**, or, if that option is missing on macOS 15+, go to **System Settings → Privacy & Security → Open Anyway**. From a terminal you can instead run `xattr -dr com.apple.quarantine /Applications/OpenComic.app`. Only needed once.

**Option B — Homebrew:**

```bash
brew install --cask greatdeepband/tap/open-comic   # once a tap is published
# …or directly from this repo's checkout:
brew install --cask ./homebrew/Formula/open-comic.rb
```

`unar`/`lsar` (for CBR/CB7) ship inside the app bundle, so no extra dependencies are required.

## Features

- **Formats:** CBZ, CBR, CB7, CBT, and PDF.
- **Reading modes:** Single Page, Double Page, Vertical Scroll, Vertical Double.
- **Library:** two-column `NavigationSplitView` — sidebar (Home · Favorites · Recents · All Comics · user Galleries with count badges) and a detail pane that changes per selection. Home hosts a "Continue Reading" hero plus horizontal rails; other panes are filtered/sorted grids with a scoped search, sort menu, and card-size control.
- **User-defined galleries:** multi-folder scanning, drag-to-reorder within a gallery, drag a card onto a sidebar gallery row to move between galleries, per-gallery sort (custom order preserved only when sort is Custom and search is empty).
- **Drag-to-import:** drop CBZ/CBR/CB7/CBT/PDF files onto the library window to open immediately; an accent-coloured drop-zone highlights the target area.
- **Fast library load:** background parallel thumbnail extraction with an `NSCache` + disk-backed fallback keyed by FNV-1a content hash.
- **Per-comic persistence:** remembers page index, reading mode, exact scroll offset, and page count in `UserDefaults`.
- **Magnifier loupe:** left-click and hold on any page (all four reading modes) for a 1.45× circular loupe centred on the cursor.
- **GPU-accelerated rendering across every reading mode:** Metal pipeline with three LRU rings (decoded `CVPixelBuffer`s and uploaded full-res `MTLTexture`s at 24 entries each, plus a 200-entry thumbnail `MTLTexture` ring that fills the placeholder tier during fast scroll). Vertical modes use native `NSScrollView.magnification` for zoom; single/double use frame-resize zoom with the documentView sized to fit the viewport.

## Architecture

SwiftUI for library, chrome, and state; AppKit (`NSScrollView`) for pixel-accurate scrolling; Metal for page rendering in **all four reading modes**. `MetalPageView` (NSViewRepresentable wrapping `NSScrollView` + a `CAMetalLayer` sublayer) backs single-page, double-page, vertical, and vertical-double — branching on a `ReadingLayout` enum. The decode cache (`MetalPageManager`) and texture ring (`MetalPageRenderer`) are shared across modes; SwiftUI swaps the `layout` parameter and the same `Coordinator` rebuilds the document.

### Core components

| Component | Responsibility |
|---|---|
| `DCApp` / `ContentView` | App entry point. Owns `LibraryViewModel`; switches between `LibraryView` and `ReaderView`. |
| `LibraryViewModel` | Gallery persistence, folder scanning, `NSCache`-backed thumbnail pipeline, search. Also owns the new-library state: `selectedSection`, `cardSize`, `sortPreferences` — all persisted to `UserDefaults`. |
| `ReaderViewModel` | Current comic state: page nav, zoom, reading mode. Owns the shared `MetalPageManager` (decode cache for all four reading modes). |
| `ComicLoader` | Archive decode: `ZIPFoundation` for CBZ, `PDFKit` for PDF, bundled `unar` / `lsar` for CBR / CB7, `tar` for CBT. |
| `ReadingPositionStore` | UserDefaults: page index, reading mode, scroll offset, page count per comic. |
| `MemoryMonitor` | `mach_task_basic_info` RSS sampler with pressure thresholds (passive — informational only). |
| `DCLogger` | Actor-based file logger → `/tmp/dc_debug.log`. |

### Library views (`LibraryView.swift`, `LibraryTypes.swift`)

| View | Role |
|---|---|
| `LibraryView` | `NavigationSplitView` shell. Hosts sidebar + detail, plus a window-level drop target for CBZ/CBR/CB7/CBT/PDF drag-to-import and an `ErrorBanner` overlay for `LibraryViewModel.errorMessage`. |
| `LibrarySidebar` | `List(selection:)` keyed by `LibrarySection`. Static top rows (Home/Favorites/Recents/All Comics) and a dynamic Galleries section. Gallery rows accept drops (`moveComic`) and expose a context menu for Rename / Add Folders / Reset Order / Delete. "+ New Gallery" button sits at the bottom via `safeAreaInset`. |
| `LibraryDetail` | Router. Switches on `library.selectedSection` and returns `LibraryHome` / `LibraryGridPane` / `LibraryGalleryPane`. The window toolbar provides Open Comic (⌘O) and the memory-debug toggle. |
| `LibraryHome` | Hero + rails. `ContinueReadingHero` when a resumable comic exists, else `WelcomeHero`. Rails: Recently Added, Favorites, Continue Reading — each a `LazyHStack` of `ComicCard`s with a "See All" jump. |
| `LibraryGridPane` | Sectioned grid for Favorites / Recents / All Comics. Pulls its URL list from the view model, filters via `searchQuery`, sorts via `LibrarySort.apply`. |
| `LibraryGalleryPane` | Gallery grid. Uses `DraggableComicGrid` when sort is `.manual` and search is empty (preserving drag-reorder); otherwise a sorted/filtered `LazyVGrid`. |
| `PaneToolbar` | Shared per-pane toolbar: scoped search field, sort menu, card-size menu, optional trailing content. |
| `ComicCard` | Cover + title, progress badge, heart button. Hover state drives scale + shadow + heart-reveal animation. |
| `DraggableComicGrid` / `ComicDropDelegate` | Preserved from the previous library. Drag-to-reorder within a single gallery via `onDrag` / `onDrop` delegate. |
| `EmptyPane` / `ErrorBanner` / `DebugMemoryBar` | Supporting chrome. |
| `CreateGallerySheet` / `RenameGallerySheet` | Unchanged semantics, lightly re-styled. |

`LibrarySection`, `CardSize`, and `LibrarySortOrder` live in `LibraryTypes.swift`. `LibrarySort.apply` centralises the sort logic so every pane uses the same implementation.

### Reader views

| View | Role |
|---|---|
| `ReaderView` | Hosts the reader content + the custom integrated top bar. Keyboard routing and mode switch. Calls `ReaderToolbar` for the chrome strip. |
| `ReaderToolbar` | 52-pt transparent strip carrying three floating Liquid-Glass capsules: leading (back / Library), centred transport (prev-comic / prev-page / page-count / next-page / next-comic with 1pt hairline dividers), trailing (favorite + ellipsis menu). Lives in `Sources/DC/Views/ReaderToolbar.swift`. |
| `ToolbarCapsule` | Private wrapper inside `ReaderToolbar.swift`. Applies `.glassEffect(.regular.interactive(true), in: .capsule)` on macOS 26+; falls back to `.background(.ultraThinMaterial, in: Capsule())` + 0.5pt rim on macOS 14–25 via an `if #available` gate. One place to change material, three call sites. |
| `FullSizeTitleBarConfigurator` | NSViewRepresentable attached to `ReaderView.background(...)` (and `ContentView.background(...)`). On appear, reaches up to the hosting NSWindow and sets `titlebarAppearsTransparent = true` + `styleMask.insert(.fullSizeContentView)` + `titleVisibility = .hidden`, plus re-asserts `standardWindowButton(...)?.isHidden = false` so the traffic lights stay visible. Without this the title-bar slab stays opaque above the content and the toolbar reads as two stacked bars. |
| `MetalPageView` | All four reading modes. Hosts `NSScrollView` with a flipped `MetalCanvasView` as `documentView`; renders visible pages via Metal. Layout branches on `ReadingLayout`. |
| `ReadingLayout` | Enum in `MetalPageView.swift`: `.verticalStack(pagesPerRow:)` · `.singlePage` · `.doubleSpread`. Drives all layout/scroller/zoom branching in `Coordinator.rebuildLayout()`. |
| `LoupeOverlayState` | Struct passed via `MetalPageView.onLoupeOverlay` callback. `ReaderView` keeps a `@State LoupeOverlayState?` and renders a SwiftUI `MagnifierView` from it; the loupe is naturally clipped by the reader's ZStack bounds. |
| `MetalCanvasView` | `NSScrollView.documentView` with a plain `CALayer` as backing and a `CAMetalLayer` **sublayer** pinned to `clipView.bounds` on scroll (see "Why a sublayer" below). |
| `MetalPageRenderer` | `MTLRenderPipelineState`, `TextureRingBuffer` (10-entry LRU), `render(viewport:visibleRange:pagePositions:…)`. Shader uniforms carry `(viewportOriginX, Y, Width, Height)` matching the metalLayer frame. |
| `MetalPageManager` | Actor holding decoded `CVPixelBuffer`s (10-entry LRU) + parallel nonisolated `NSCache<NSNumber, NSImage>` (cap 10). Shared across all reading modes. `nsImage(for:)` fast-path for the loupe; `prefetch(around:pages:)` decodes the surrounding window. |
| `MagnifierView` | SwiftUI Canvas loupe (1.45×, circular, top-left-origin cursor coords). |

### Reader top-bar layout

Version 0.11 replaced the v0.8 unified-strip-with-NSVisualEffectView design with a transparent strip carrying three floating Liquid-Glass capsules. Key decisions, recorded here so we don't relitigate:

1. **One integrated chrome strip.** `DCApp` uses the default `.windowStyle(.titleBar)` so traffic lights stay visible always (the previous `.windowStyle(.hiddenTitleBar)` hid them on macOS 26 until hover). `FullSizeTitleBarConfigurator` makes the title bar transparent (`titlebarAppearsTransparent = true`) and stretches content underneath (`styleMask.insert(.fullSizeContentView)`). `ReaderView.body` adds `.ignoresSafeArea(.container, edges: .top)` so SwiftUI doesn't reserve title-bar safe area. Traffic-light controls + our toolbar share the same 52-pt strip; no stacked bars.
2. **ZStack geometric centring.** `.toolbar { .principal }` centres relative to the leading/trailing clusters — which shifts whenever they have different widths. The only way to pin the transport at the true window midpoint is a ZStack with the transport laid as a separate layer over the leading/trailing HStack.
3. **80-pt leading gutter** reserves room for the macOS traffic-light triad (14 pt × 3 + padding) **plus** an 8-pt buffer so the leading capsule's Liquid-Glass rim doesn't kiss the close-button hit area.
4. **Liquid Glass material.** `.glassEffect(.regular.interactive(true), in: .capsule)` inside one `GlassEffectContainer` on macOS 26+ — refractive, reactive to hover, coordinated sampling across the three capsules. macOS 14–25 falls back to `.ultraThinMaterial` + a 0.5pt white-10% rim, same shape, same hit targets, no refraction. The fallback is *honest*: same geometry, just a flatter material.
5. **Loupe / navbar interaction.** The NSScrollView spans the full window with `topContentInset = 52`, so the navbar overlays the scrollview (not next to it). `MetalPageView+Loupe.swift:handleLoupeEvent` skips the *initial* `.leftMouseDown` when `svLocal.y < topBarHeight` (NSScrollView is top-origin in our setup because the `MetalCanvasView` documentView is `isFlipped = true`). Once a drag has started below the strip, `loupeDragActive` keeps subsequent `.leftMouseDragged` events flowing regardless of cursor position — the loupe fades to black at the page top edge the same way it already did at left/right/bottom.

### Why a sublayer?

Earlier Metal-pipeline versions made `CAMetalLayer` the backing layer of `MetalCanvasView`. Because `MetalCanvasView.frame` is the full stacked-pages height (tens of thousands of points) but `drawableSize` is the viewport in pixels, `CAMetalLayer`'s default `contentsGravity = .resize` stretched the drawable ~100× vertically. v0.5.0 fixed this by making the backing layer a plain `CALayer` and adding `CAMetalLayer` as a **sublayer** that is repositioned over the visible `clipView.bounds` on every scroll, with `drawableSize` set to `visible × contentsScale`. The Metal-rendered drawable composites 1:1 against the visible viewport; the vertex shader projects document-space page rects into NDC using the current scroll offset + viewport dimensions.

### Fast-scroll pipeline

On every scroll event, `Coordinator.updateVisibleRange()`:

1. Binary-searches `pageYOffsets` (page-indexed, with duplicate Y for vertical-double pairs), walking left/right across duplicates so both halves of the first and last visible rows are in range.
2. Cancels the previous `prefetchTask` and starts a new one that decodes **visible pages first**, then lookahead pages fanning outward.
3. Calls `updateMetalLayerFrame()` so the CAMetalLayer sublayer is in position before `render(visibleRange:)`.
4. Renders deferred by one runloop tick (lets the layout pass settle).

When a prefetch decode lands, `onTextureReady(seqIdx)` re-renders if the page is still visible, so pages that complete after the last scroll event still appear without the user scrolling again. The `TextureRingBuffer`'s own LRU (cap 10) bounds memory — there is no per-frame explicit eviction.

### Vertical-double rendering

`rebuildLayout()` lays out left and right pages at half-width with shared Y offset, appending **two** `pageYOffsets` entries per pair (so page indexing stays consistent with single mode). Render draws left and right as two independent quads from their individual `pagePositions` rects — no spread compute-kernel composition. Each page appears the moment its own texture uploads; the partner page doesn't block it.

### Loupe

The loupe is one unified `MagnifierView` instance across all four reading modes, driven by `MetalPageView`'s Coordinator and rendered as a SwiftUI overlay in `ReaderView`. Key mechanics:

- A window-local `NSEvent.addLocalMonitorForEvents` monitor for `.leftMouseDown/Dragged/Up` observes events without consuming them, so scroll / pinch / wheel continue to work.
- Coordinate resolution via `scrollView.documentView.convert(windowPt, from: nil)` — single-step conversion through the flipped documentView.
- The Coordinator emits a `LoupeOverlayState?` via `onLoupeOverlay` callback. `ReaderView` keeps the state in `@State` and renders the `MagnifierView` inside its inner ZStack, where SwiftUI's natural bounds clip the circle to the reader frame.
- Position is translated from AppKit's bottom-left window coords to SwiftUI's top-left coords inside the Coordinator: `swiftuiY = window.frame.height - windowPt.y`.
- For the page under the cursor, the Coordinator hit-tests `pagePositions` directly (single/double-page) or via `pageYOffsets` binary search (vertical). When the cursor is in a row gap, the column gap, the top/side margins, or past the document edges, `updateLoupe` sticks to `loupeActivePage` — the last page that *was* under the cursor — so the loupe never disappears mid-drag. Initial fallback (no active page yet) is `currentPage` for single/double or `lastVisibleRange.lowerBound` for vertical. `MagnifierView` always paints the canvas black before attempting the image draw, so off-page cursors render as a solid black circle rather than a transparent ring; raw cursor coords are never clamped, so within-page edges fade to black naturally via `srcRect.intersection(ivBounds)`. Same gesture/lifetime/edge behaviour as the pre-Metal `ZoomableImageView` loupe, generalised across multiple page rects.
- NSImage source priority: 1-entry per-page cache (`loupeImage`); `MetalPageManager.nsImage(for:)` (synchronous, hits the nonisolated `NSCache`); else async snapshot from the `CVPixelBuffer` via `CGContext.makeImage()`, with a `decodePage` fallback.
- Async fetches use a `loupeTaskID` generation counter; late-arriving Tasks from prior drag positions are silently dropped. While a fetch is in flight, the Coordinator emits a fallback state using the last cached image so the loupe position keeps tracking the cursor.
- `scrollDidChange` re-triggers `updateLoupe` using `NSEvent.mouseLocation` so trackpad scrolls (no `rightMouseDragged` event) still refresh the loupe as pages move under a stationary cursor.
- Cursor hide/show is balanced via a `cursorHidden` tracker. The OS cursor is hidden on `mouseDown` (after the page resolves) and restored on `mouseUp` via `hideLoupe`; `loupeActivePage` resets there too, so the next press starts fresh. The loupe stays visible for the full duration of the drag — content tracks whichever page sits under the cursor, the panel position is the raw cursor, and the reader's ZStack bounds clip the circle progressively at the window edges (no manual bezel arithmetic).

### Caching layers (memory budget)

| Layer | Scope | Cap |
|---|---|---|
| `NSCache` thumbnails + FNV-1a disk fallback | Library grid | 600 entries |
| `MetalPageManager.decodedPages` | All reading modes — `CVPixelBuffer` ring | 24 |
| `MetalPageManager.nsImageCache` | All reading modes — `NSImage` fast-path (paired with CVPixelBuffer ring, evicted in lockstep) | 24 |
| `MetalPageRenderer.textureRing` | Metal-backed modes — full-res `MTLTexture` ring | 24 |
| `MetalPageRenderer.thumbnailRing` | All reading modes — low-res `MTLTexture` placeholder ring (filled by parallel pre-scan, ~108 MB GPU for 200 thumbs at 300×450 BGRA) | 200 |
| Loupe NSImage | Last cursored page only | 1 |

Since v0.9.0, one `MetalPageManager` is owned by `ReaderViewModel` and injected into every `MetalPageView` instance, so all four reading modes share the same decode cache. `PageImageCache` was retired in v0.9.0.

Per-card refreshes are driven by `LibraryViewModel.thumbnailUpdates`, a non-`@Published` `PassthroughSubject<URL, Never>` that broadcasts one event per cache insertion; cards observe via `.onReceive` so a thumbnail write for one card never invalidates the rest of the grid.

## Development

### Prerequisites

- macOS 14.0+
- Xcode 15+ or Swift 5.10 toolchain
- `unar` / `lsar` are bundled in the app at `Contents/Resources/bin/` (used for CBR / CB7 extraction). A Homebrew-installed copy is used as fallback.

### Build

```bash
cd /path/to/DC_dev
./build_app.sh
```

`build_app.sh`:
1. Runs `swift build -c release`.
2. Assembles `OpenComic.app/` in the repo root.
3. Writes `Info.plist` + entitlements, copies `Shaders.metal` (the renderer compiles it at runtime if the SPM default library is not present in the bundle).
4. Ad-hoc signs the binary.

### Test

```bash
swift test
```

Runs the `DCTests` target (baseline coverage of `ComicFormat` extension parsing, `ReadingPositionStore` UserDefaults round-trip, and `TextureRingBuffer` LRU semantics — the last requires a Metal device, present on every supported macOS).

GitHub Actions runs `swift build -c release` and `swift test --parallel` on every push and PR via `.github/workflows/swift.yml`.

### External dependencies

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — native CBZ extraction and entry streaming. MIT-licensed.
- **`unar` / `lsar`** — bundled binaries from [The Unarchiver](https://theunarchiver.com/command-line), used for CBR (RAR) and CB7 (7-Zip) extraction. LGPL-2.1-or-later; see [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for source-availability statement and relinking instructions.
- System `tar` (BSD tar, ships with macOS) — used for CBT (Tar) extraction. No bundling.

### Keyboard shortcuts (reader)

| Key | Single / Double page | Vertical / Vertical Double |
|---|---|---|
| `←` / `A` | Previous page | — |
| `→` / `D` | Next page | — |
| `↑` / `W` | Zoom in | — (use ⌘+scroll or pinch — grows the window in ±10% steps) |
| `↓` / `S` | Zoom out | — |
| `Q` | Open previous comic in gallery | Open previous comic in gallery |
| `E` | Open next comic in gallery | Open next comic in gallery |
| `Backspace` / `Z` | Back to library | Back to library |
| `⌘F` | Toggle full screen | Toggle full screen |
| `1` | Switch to Single Page mode | Switch to Single Page mode |
| `2` | Switch to Double Page mode | Switch to Double Page mode |
| `3` | Switch to Vertical mode | Switch to Vertical mode |
| `4` | Switch to Vertical Double mode | Switch to Vertical Double mode |

Mouse / trackpad:
- **Left-click and hold** anywhere on a page — 1.45× circular magnifier loupe centred on the cursor (every reading mode).
- **⌘+scroll** or **pinch** — zoom (in vertical modes this becomes a ±10% window-resize step; in single/double it scales the page).
- **Double-click** (single / double page only) — reset zoom to fit-to-window.

### Notes for future sessions

- **Don't assume `NSScreen.main`.** It can return `nil` or `1.0` during early layout passes. Use `NSScreen.screens.first?.backingScaleFactor ?? 2.0` or read `metalLayer.contentsScale` after it has been set.
- **`pageYOffsets` is page-indexed.** In vertical-double mode, the two pages of a pair share a Y value. Every binary search over `pageYOffsets` in this codebase must walk duplicates.
- **Don't re-introduce `CAMetalLayer` as the backing layer** of a full-documentView-sized NSView. See "Why a sublayer" above.
- **Don't add a subview to `window.contentView`** under a SwiftUI `WindowGroup` and expect it to stay. Use a child `NSPanel` for long-lived AppKit chrome (the loupe does this).
- **For cursor → document-space math, call `documentView.convert(windowPt, from: nil)` directly.** The manual `clipView.convert + bounds.origin` composition looks right on paper but `NSClipView.isFlipped` can drift out of sync with `documentView.isFlipped` during transient layout states, producing the wrong document Y. One-step conversion is authoritative.
- **`NSCursor.hide()` / `unhide()` are reference-counted and macOS auto-unhides on window exit.** Track the hidden state yourself and re-assert `hide()` on every mouse event while a modal-style feature (loupe, etc.) is active.
- **AppKit + SwiftUI lifecycle:** `LibraryView` is conditionally rendered in `ContentView`; `@State` is destroyed each time the reader opens/closes. Session-persistent state lives on `LibraryViewModel`.
- **`makeNSView` writes can be clobbered by `updateNSView`** if you rely on reading coordinator fields from a `DispatchQueue.main.async` closure. Capture values at schedule time.
- **macOS 26 (Tahoe) scroll-into-header bug.** If an `NSScrollView`'s frame does not stretch top-to-bottom of its window's content view, its scrolled content will render OVER any sibling above it in the layout tree — even with `masksToBounds = true`, even with SwiftUI `.clipped()`, even after removing `magnification`. Reserve top-bar space via native `NSScrollView.contentInsets` (frame stays full-height; clip view honors the inset as a non-scrollable band), **not** SwiftUI `.padding(.top, …)`. `MetalPageView` exposes a `topContentInset` parameter for this. Also set `scrollView.borderType = .noBorder` as belt-and-suspenders (independently disables the buggy render path). Reference: https://troz.net/post/2026/appkit-table-scroll-bug-in-macos-tahoe/.
- **CAMetalLayer + `NSScrollView.magnification` is unsafe.** The direct-to-surface Metal drawable bypasses ancestor layer clipping when a scale transform is present on the `clipView`. In `MetalPageView`, vertical modes use native magnification (fast CALayer transform) but single-page and double-spread zoom via documentView frame-resize (`scrollView.magnification` pinned to 1.0). The scale change flows through `Coordinator.rebuildLayout()` which resizes the documentView frame around the centered content. `recenterIfContentFits()` re-centers the documentView when zoomed content is smaller than the viewport, so zoom-out doesn't leave content off-center.
- **NSEvent local monitors vs overlay views.** `MetalPageView` uses `NSEvent.addLocalMonitorForEvents` (scoped to its window) for cmd-scroll zoom, double-click fit-to-width, pinch zoom, and the loupe. An overlay sibling view would block scroll-wheel / pinch gestures from reaching `NSScrollView`; monitors observe events without consuming them. Scope monitors to the scroll view's own window (`event.window === scrollView.window`) so a monitor installed by one reader instance doesn't fire for events in another window.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to set up the dev environment, the testing workflow, and — importantly — a list of **load-bearing comments / workarounds** that look like cleanup opportunities but are not.

## License

Open Comic itself is [MIT-licensed](LICENSE). The bundled `unar` / `lsar` binaries are LGPL-2.1-or-later; full attribution + relinking instructions are in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md). The full LGPL-2.1 text is in [`LICENSES/LGPL-2.1.txt`](LICENSES/LGPL-2.1.txt).
