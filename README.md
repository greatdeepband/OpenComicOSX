# Open Comic

A native macOS comic book reader built with SwiftUI, AppKit, and Metal. Designed for large libraries, smooth reading, and pixel-perfect vertical scrolling.

## Features

- **Formats:** CBZ, CBR, CB7, CBT, and PDF.
- **Reading modes:** Single Page, Double Page, Vertical Scroll, Vertical Double.
- **Library:** two-column `NavigationSplitView` — sidebar (Home · Favorites · Recents · All Comics · user Galleries with count badges) and a detail pane that changes per selection. Home hosts a "Continue Reading" hero plus horizontal rails; other panes are filtered/sorted grids with a scoped search, sort menu, and card-size control.
- **User-defined galleries:** multi-folder scanning, drag-to-reorder within a gallery, drag a card onto a sidebar gallery row to move between galleries, per-gallery sort (custom order preserved only when sort is Custom and search is empty).
- **Drag-to-import:** drop CBZ/CBR/CB7/CBT/PDF files onto the library window to open immediately; an accent-coloured drop-zone highlights the target area.
- **Fast library load:** background parallel thumbnail extraction with an `NSCache` + disk-backed fallback keyed by FNV-1a content hash.
- **Per-comic persistence:** remembers page index, reading mode, exact scroll offset, and page count in `UserDefaults`.
- **Magnifier loupe:** left-click and hold on any page (all four reading modes) for a 1.45× circular loupe centred on the cursor.
- **GPU-accelerated vertical reader:** Metal render pipeline with two LRU rings (decoded `CVPixelBuffer`s and uploaded `MTLTexture`s, 10 entries each) and native `NSScrollView.magnification` for zoom.

## Architecture

SwiftUI for library, chrome, and state; AppKit (`NSScrollView`) for pixel-accurate scrolling in every reader mode; Metal for page rendering in three of four modes. `MetalPageView` (NSViewRepresentable wrapping `NSScrollView` + a `CAMetalLayer` sublayer) backs single-page, vertical, and vertical-double. Double-page still uses `SpreadView` (SwiftUI) — scheduled to migrate to `MetalPageView(layout: .doubleSpread)` in Step A phase A-2.

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
| `ReaderView` | Hosts the reader content + the custom integrated top bar (`readerTopBar`). Keyboard routing and mode switch. |
| `readerTopBar` | 38-pt strip at the very top of the window, background = `TitlebarEffectView` (NSVisualEffectView `.titlebar`). Internally a ZStack: `HStack { [72 pt traffic-light gutter]; backButton; Spacer; trailingCluster }` with the transport cluster layered on top at the ZStack's default `.center` alignment — geometrically centred at the window midpoint regardless of back/trailing widths. |
| `TitlebarEffectView` | NSViewRepresentable → `NSVisualEffectView` with `material = .titlebar`, `blendingMode = .behindWindow`, `state = .followsWindowActiveState`. Pixel-identical to AppKit's own title-bar chrome. |
| `FullSizeTitleBarConfigurator` | NSViewRepresentable attached to `ContentView.background(...)`. On appear, reaches up to the hosting NSWindow and sets `titlebarAppearsTransparent = true` + `styleMask.insert(.fullSizeContentView)` + `titleVisibility = .hidden` — without this the 28-pt title-bar slab stays above the content. Paired with `.windowStyle(.hiddenTitleBar)` in `DCApp`. |
| `MetalPageView` | Single-page, Vertical, Vertical Double. Hosts `NSScrollView` with a flipped `MetalCanvasView` as `documentView`; renders visible pages via Metal. Layout branches on `ReadingLayout`. |
| `ReadingLayout` | Enum in `MetalPageView.swift`: `.verticalStack(pagesPerRow:)` · `.singlePage` · `.doubleSpread`. Drives all layout/scroller/zoom branching in `Coordinator.rebuildLayout()`. |
| `SpreadView` | Double-page mode. Legacy SwiftUI; scheduled for removal in Step A phase A-3 once double-page migrates to `MetalPageView(layout: .doubleSpread, …)`. |
| `ZoomableImageView` | **Dead code** as of Step A phase A-1 — single-page has moved to `MetalPageView`. File still present; deletion in phase A-3. |
| `MetalCanvasView` | `NSScrollView.documentView` with a plain `CALayer` as backing and a `CAMetalLayer` **sublayer** pinned to `clipView.bounds` on scroll (see "Why a sublayer" below). |
| `MetalPageRenderer` | `MTLRenderPipelineState`, `TextureRingBuffer` (10-entry LRU), `render(viewport:scrollOriginY:visibleRange:pagePositions:…)`. |
| `MetalPageManager` | Actor holding decoded `CVPixelBuffer`s (10-entry LRU) + parallel nonisolated `NSCache<NSNumber, NSImage>` (cap 10). Shared across all reading modes since v0.9.0. `nsImage(for:)` fast-path for SwiftUI render paths; `prefetch(around:pages:)` fires `onPageReadyNSImage` on completion. |
| `MagnifierView` | SwiftUI Canvas loupe (1.45×, circular, top-left-origin cursor coords). |

### Reader top-bar layout

Version 0.8 settled a five-version fight over reader-toolbar centring. Key decisions, recorded here so we don't relitigate:

1. **One integrated chrome strip.** The window's title bar is hidden via `.windowStyle(.hiddenTitleBar)` on the `WindowGroup`, and the NSWindow is further configured via `FullSizeTitleBarConfigurator` so content extends under the title-bar region. Traffic-light controls + our reader bar share the same 38-pt strip. No stacked bars, no empty-space-above-the-buttons.
2. **ZStack geometric centring.** `.toolbar { .principal }` centres relative to the leading/trailing clusters — which shifts whenever they have different widths. The only way to pin the transport at the true window midpoint is a ZStack with the transport as a separate layer.
3. **72-pt leading gutter** reserves room for the macOS traffic-light triad (14 pt × 3 + padding). The back button sits immediately to its right.
4. **Native vibrancy.** `.background(.bar)` or any SwiftUI material is close to the system chrome but not identical. `NSVisualEffectView` with `material = .titlebar` is the actual widget the system uses — wrapping it via `TitlebarEffectView` is the only way to match pixel-perfectly.

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

Single and double page use `ZoomableImageView` → `MagnifierView`. Vertical and vertical-double use the same `MagnifierView`, fed by:

- A window-local `NSEvent.addLocalMonitorForEvents` monitor for `.leftMouseDown/Dragged/Up` (matching single/double page's left-click gesture) — observes events without consuming them, so scroll / pinch / wheel continue to work.
- Coordinate resolution via `scrollView.documentView.convert(windowPt, from: nil)` — single-step conversion through the flipped documentView, no manual `clipView.bounds` arithmetic.
- A borderless non-activating child `NSPanel` attached via `window.addChildWindow(_:ordered:)`. SwiftUI's `WindowGroup`-managed `contentView` strips foreign subviews during its own layout passes; a child panel sidesteps that entirely.
- A brand-new `NSHostingView<AnyView>` is installed whenever the page under the cursor changes (tracked by `loupeHostPage`). `MagnifierView` is also tagged `.id(page)`. Belt-and-suspenders against stale SwiftUI Canvas state bleeding across pages.
- NSImage source priority: 1-entry cache of the last cursored page; `PageImageCache.image(for:)` if the page was decoded in single/double mode; else async snapshot from the `CVPixelBuffer` in `MetalPageManager` via `CGContext.makeImage()`, with a `decodePage` fallback if the prefetch hasn't reached the page yet.
- Async fetches use a `loupeTaskID` generation counter; late-arriving Tasks from prior drag positions are silently dropped.
- `scrollDidChange` re-triggers `updateLoupe` using `NSEvent.mouseLocation` so trackpad scrolls (no `rightMouseDragged` event) still refresh the loupe as pages move under a stationary cursor.
- Cursor hide/show is balanced via a `cursorHidden` tracker; `NSCursor.hide()` is re-asserted on every drag and scroll refresh because macOS auto-unhides when the cursor crosses the app window boundary.

### Caching layers (memory budget)

| Layer | Scope | Cap |
|---|---|---|
| `NSCache` thumbnails + FNV-1a disk fallback | Library grid | 600 entries |
| `MetalPageManager.decodedPages` | All reading modes — `CVPixelBuffer` ring | 10 |
| `MetalPageManager.nsImageCache` | All reading modes — `NSImage` fast-path (paired with CVPixelBuffer ring, evicted in lockstep) | 10 |
| `MetalPageRenderer.textureRing` | Metal-backed modes — `MTLTexture` ring | 10 |
| Loupe NSImage | Last cursored page only | 1 |

Since v0.9.0, one `MetalPageManager` is owned by `ReaderViewModel` and injected into every `MetalPageView` instance, so all four reading modes share the same decode cache. `PageImageCache` was retired in v0.9.0.

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

### External dependencies

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — native CBZ extraction and entry streaming.

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
