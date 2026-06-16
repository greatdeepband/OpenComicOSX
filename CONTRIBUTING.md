# Contributing to Open Comic

Thanks for your interest. This file covers:

1. Dev environment + workflow
2. How to test
3. **Load-bearing comments and workarounds** — code that looks "weird" but isn't a cleanup target

## Dev environment

- macOS 14.0+ (the project targets macOS 14 and is regularly used on macOS 26 Tahoe)
- Xcode 15+ or Swift 5.10 toolchain
- `unar` / `lsar` are bundled at `AppBundle/Resources/bin/` so cloning is enough — no Homebrew step required

The canonical build command is:

```bash
./build_app.sh
```

This runs `swift build -c release`, assembles `OpenComic.app/` at the repo root, copies `Shaders.metal` as a resource, writes `Info.plist`, and ad-hoc signs the binary. Don't run the binary directly out of `.build/release/DC` — it won't have the resources/plist/signing and will misbehave in subtle ways.

## Workflow

1. **Branch from `main`.**
2. **Write tests first** when you can — see `Tests/DCTests/` for examples. The baseline coverage targets pure-logic units (`ComicFormat` extension parsing, `ReadingPositionStore` UserDefaults round-trip, `TextureRingBuffer` LRU). Metal-touching code is verified by driving the app live (see "Live verification" below).
3. **Run `swift test`** and confirm all tests pass before opening a PR.
4. **Run `./build_app.sh`** and confirm the produced `.app` works for the case you've changed. CI builds + tests automatically, but it doesn't drive the UI.
5. **Open a PR** against `main`. CI runs `swift build` + `swift test` via `.github/workflows/swift.yml`.

### Live verification

Reader / library / loupe / scroll changes need an actual app run. The unit-test target covers pure logic only — UI correctness comes from driving the app:

- Run `./build_app.sh`.
- Launch `OpenComic.app`.
- Reproduce the scenario you changed.
- Touch all four reading modes (Single Page · Double Page · Vertical · Vertical Double) if you've changed anything in `MetalPageView.swift`, `MetalPageView+Layout.swift`, `MetalPageView+Render.swift`, or related render-path code. They share more code than the file split suggests.

For debug runs: `/tmp/dc_debug.log` captures `DCLogger` output. In `DEBUG` builds the logger is enabled by default; in release builds it's silent unless flipped at runtime via `DCLogger.shared.enabled = true`. **Never `rm /tmp/dc_debug.log` while the app is running** — it silently breaks the actor's file handle. Truncate with `: > /tmp/dc_debug.log` instead.

## Tests

```bash
swift test
```

Tests live in `Tests/DCTests/`:

- `ComicFormatTests.swift` — extension → format detection
- `ReadingPositionStoreTests.swift` — UserDefaults round-trip for per-comic page / scroll / progress state (cleans `/tmp/dc-test-*` keys around each test, so it won't disturb your real library)
- `TextureRingBufferTests.swift` — LRU eviction semantics on the renderer's texture ring (requires a Metal device — present on every supported macOS)

When adding tests for new pure-logic code, prefer to expose the minimum surface needed (`@testable import DC` is in play, so `internal` is enough).

## Style

- Swift 5.10. No tabs. 4-space indent.
- Comments justify **why**, not what. The codebase has unusually dense comments on load-bearing workarounds — match that density when you add similar workarounds. See next section.
- Don't add error handling, fallbacks, or validation for impossible scenarios. Trust internal-call invariants. Only validate at system boundaries (user input, external APIs, disk).
- Prefer editing existing files over creating new ones.

## Load-bearing comments and workarounds — do NOT remove without reading

The following look like candidates for "cleanup" but are deliberately the way they are. Each carries a comment explaining the constraint; please read the comment before touching the code.

### `MetalPageView.swift` — reader-pipeline workarounds

- **`MetalCanvasView.makeBackingLayer` — plain `CALayer` backing + `CAMetalLayer` sublayer.** Earlier versions used `CAMetalLayer` as the backing layer directly. With a 100,000pt-tall backing layer and a viewport-sized drawable, the default `contentsGravity = .resize` stretched the drawable ~100×. The sublayer pattern keeps the drawable 1:1 with the visible viewport.
- **`presentsWithTransaction = true` + `commit() / waitUntilScheduled() / drawable.present()` triplet.** The Hume canonical present pattern. Drops the previous-size drawable being held over for a frame on every window resize. The pair MUST be kept together — disabling either side reintroduces resize artifacts.
- **3-stage render retry on layout change (1ms / 50ms / 150ms).** Walks past stale `CAMetalLayer` drawables queued from the previous layout. `presentsWithTransaction` is the principled alternative for the resize case, but mode-switch races still need this retry — they're a different family of bug.
- **`scrollView.borderType = .noBorder` + `automaticallyAdjustsContentInsets = false` + native `contentInsets.top` for the toolbar reserve.** Works around the macOS 26 (Tahoe) `NSScrollView` scroll-into-header bug. Do NOT use SwiftUI `.padding(.top, …)` for top-bar reserve — that does NOT satisfy the bug's precondition (the scroll view must stretch top-to-bottom of its containing window content area). Reference: https://troz.net/post/2026/appkit-table-scroll-bug-in-macos-tahoe/
- **Single/double zoom via documentView frame-resize, NOT via `scrollView.magnification`.** `CAMetalLayer`'s direct-to-surface compositing bypasses ancestor `masksToBounds` clipping when a scale transform is on the `clipView`. Vertical modes use native magnification (CALayer transform); single/double pin `magnification = 1.0` and scale the `documentView.frame` instead.
- **`scrollView.frame.size` override from `updateNSView` during live resize.** SwiftUI's NSViewRepresentable layout commits at coarser cadence than its body re-eval (~24 vs 98+ distinct widths across a 15-sec drag). Driving the scrollView frame from `updateNSView` per body eval promotes the visible viewport to the finer cadence. Removing it makes resizes stair-step.
- **`updateVisibleRange` runs `triggerPrefetch` AND `render`** in a single pass per scroll event. Render before prefetch lets the visible page paint immediately; prefetch after fans out the surrounding window. Reversing the order makes the first scroll frame visibly later.
- **Synchronous `scrollToFraction` / `scrollToPage` in mode-switch path BEFORE the trailing `updateVisibleRange()`.** A dispatched async restore samples `clipView.origin.y = 0` before its scroll fires, emits `onPageChanged(0)`, and clobbers `vm.currentPage`. The sync version closes that race window. See the long comment at `MetalPageView.swift:416-438`.
- **The `@objc` notification selectors live in the `Coordinator` class body, NOT in extensions.** `NotificationCenter.addObserver(_, selector:)` resolves selectors via the Objective-C runtime, and `@objc` extension methods on `final class : NSObject` aren't reliably exposed there. Symptom of getting this wrong: scroll events stop firing in vertical mode.

### `MetalPageView+Render.swift`

- **Texture upload + readiness notification wrapped in `await MainActor.run`.** `MetalPageRenderer`'s `TextureRingBuffer` mutation and `MTLDevice.makeTexture` are documented as main-actor-only; previously this ran on the Task's nonisolated continuation after `await decodePage`, which races with main-actor render() / texture(for:) calls. Same threading-invariant family as the project's known "`nextDrawable()` off main thread → SIGABRT" landmine.
- **`prefetchInFlightRange` dedupe.** `updateVisibleRange` fires repeatedly during initial layout (multiple bounds-change notifications, layout-completed retries). Without this dedupe each call cancels the previous task, killing decode mid-flight, and textures never land in the ring. Symptom: page stays black on mode switch.

### `MetalPageView+Loupe.swift`

- **`inEdge` guard at the start of `.leftMouseDown` handling.** The reader uses `.fullSizeContentView`, so the `NSScrollView` spans the full window frame and AppKit's window-resize hot zones sit OVER `scrollView.bounds`. Without this guard the loupe monitor swallows the `.leftMouseDown` that AppKit needs to start its resize session — cursor hides, loupe flashes, resize drag glitches.
- **`loupeTaskID &+= 1` + `self.loupeTaskID == myID` check in async image-fetch.** Each `updateLoupe` call bumps the token, and a Task only applies its result if the token still matches — fast drags don't let a late-resolving stale Task paint over the newest request.
- **`loupeActivePage` stickiness.** When the cursor wanders into row/column gaps or past document edges, the loupe sticks to the last-active page so it never disappears mid-drag. `MagnifierView`'s intersection clip fades content to black at the page edge; the loupe panel itself stays anchored to the raw cursor.

### `MetalPageManager.swift`

- **`ThumbnailStore` sub-actor + `nonisolated` decode helpers + `withTaskGroup` pre-scan.** Decoding thumbnails is pure-functional work over a `Data` blob — it doesn't need actor isolation. Putting it on the manager's serial decode actor stalled it behind foreground per-visible-range prefetch during fast scroll (priority bumps didn't help — it's an actor-queue contention issue, not a priority issue). The fix was moving decode off the actor entirely. See the long comment at `:155-180` (approx) for the full rationale.
- **`_prefetchAround` (the legacy navigation prefetch path).** Looks vestigial but is still useful as a head-start: it warms `decodedPages` (CPU `CVPixelBuffer` cache) on explicit page navigation events, BEFORE the per-visible-range prefetch in `MetalPageView+Render.swift` fires. Both go through `decodePage`, which is idempotent.

### Build / scripts

- **`build_app.sh` is the canonical builder.** Don't run the binary directly out of `.build/release/DC`. The script copies `Info.plist`, the `Shaders.metal` resource, and ad-hoc signs — all required for the app to launch correctly. Tests don't need the bundle, so `swift test` is fine on its own.

## Reporting bugs

Open an issue with:

- macOS version
- The format that triggered the issue (CBZ / CBR / CB7 / CBT / PDF)
- A reproduction (ideally with a sample file if it's a parsing bug)
- The contents of `/tmp/dc_debug.log` if relevant — enable logging in a release build via `DCLogger.shared.enabled = true` in the debugger before reproducing

## License

Open Comic itself is MIT (see [`LICENSE`](LICENSE)). By contributing, you agree your contributions are MIT-licensed under the same terms.
