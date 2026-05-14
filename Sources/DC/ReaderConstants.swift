import CoreGraphics
import Foundation

/// All tunable constants for the Metal reader pipeline live here. Each value
/// has a *why* attached — the rationale for why it's THIS number and not
/// something else. Treat the why as load-bearing: changing the value without
/// re-validating against the why is how regressions get reintroduced.
enum ReaderConstants {

    // MARK: - Layout

    /// Visible height of the reader's top bar overlay. Used as the scrollView's
    /// `contentInsets.top` so the page content scrolls beneath but not over
    /// it. The value is the intrinsic height of `readerTopBar` in ReaderView.
    /// 52pt: tall enough to host 36pt Liquid-Glass capsules with breathing
    /// room above and below them, and to read as a "real" Mac toolbar
    /// rather than a thin chrome line.
    static let topBarHeight: CGFloat = 52

    /// Width of the AppKit window-resize hot zone along each window-frame
    /// edge. The reader uses `.fullSizeContentView` + `.hiddenTitleBar`,
    /// so the NSScrollView spans the full window frame and AppKit's
    /// resize-cursor hot zones sit OVER the scrollView's bounds. Without
    /// an explicit guard, the loupe's app-wide `.leftMouseDown` monitor
    /// claims the click that AppKit's resize tracker needs — the loupe
    /// fires, the cursor hides, and the resize drag glitches. 6pt
    /// matches AppKit's typical hot-zone (verified live on 2026-05-06:
    /// a click at x=1 with this margin classified as `edge=L`).
    static let windowResizeMargin: CGFloat = 6

    /// Height of an individual Liquid-Glass capsule inside `readerTopBar`.
    /// The capsule sits centred in the 52pt strip with ≈ 8pt of strip
    /// remaining above and below it. 36pt accommodates the system's
    /// standard control glyph baseline (16-18pt SF Symbols + label) with
    /// the Liquid-Glass rim still reading as a distinct edge.
    static let toolbarCapsuleHeight: CGFloat = 36

    /// Hairline divider opacity inside `Segmented`-style toolbar capsules.
    /// Tuned to be visible but unobtrusive against both Liquid Glass
    /// (macOS 26+) and `.ultraThinMaterial` (macOS 14–25), in light and
    /// dark mode.
    static let toolbarSegmentDividerOpacity: Double = 0.12

    /// Vertical gap between adjacent pages in vertical-stack layout.
    /// Tight enough to feel continuous but visible enough to communicate
    /// "this is page N+1".
    static let verticalPageGap: CGFloat = 4

    /// Horizontal gap between left and right pages in a double-page spread
    /// (and in vertical-double rows). Thin so the spread reads as a unit
    /// rather than two pages with a hallway between them.
    static let doublePageGutter: CGFloat = 2

    // MARK: - Zoom / magnification

    /// Floor for `NSScrollView.magnification` in vertical modes. Lower than
    /// `wheelZoomMin` because pinch gestures naturally over-shoot and we
    /// don't want the gesture to feel like it hits a wall.
    static let nativeMagnificationMin: CGFloat = 0.1

    /// Ceiling for `NSScrollView.magnification` in vertical modes, and the
    /// hard cap for any zoom in any mode. 8× is enough to inspect cover-art
    /// detail; beyond that the bilinear filter softens the image.
    static let nativeMagnificationMax: CGFloat = 8.0

    /// Floor for ⌘+wheel-driven zoom. Keeping this above the pinch floor
    /// prevents the wheel from scrolling the user into a near-empty viewport
    /// they then have to climb back out of by clicking "fit-to-window".
    static let wheelZoomMin: CGFloat = 0.25

    /// Per-step multiplier for wheel/double-click zoom. 1.25 = +25% per
    /// step; gives ~3 steps from 1.0 to 2.0, which feels responsive without
    /// over-shooting on a single notch.
    static let wheelZoomStep: CGFloat = 1.25

    /// Easing duration for keyboard/double-click zoom transitions.
    static let zoomAnimationDuration: Double = 0.15

    /// Threshold below which two `scale` values are considered equal.
    /// Floats accumulate FP noise across pinch gestures — using `==` gives
    /// false negatives that re-trigger expensive layout rebuilds.
    static let scaleEqualityEpsilon: CGFloat = 0.001

    /// Floor for any aspect-ratio division (page AR / spread AR). Prevents
    /// division-by-zero when a page reports a degenerate naturalSize.
    static let aspectRatioFloor: CGFloat = 0.001

    // MARK: - Render timing

    /// Delays (seconds) for the 3-stage render retry that fires after a
    /// layout change. Walks past the stale CAMetalLayer drawable that the
    /// rotation chain holds onto across mode switches. Empirically: <1ms
    /// catches the fast path (clipView already settled), 50ms covers the
    /// typical scroll-view layout commit, 150ms is the long tail for
    /// content-size-driven re-layouts. A principled alternative is
    /// `CAMetalLayer.presentsWithTransaction = true`; this retry is the
    /// pragmatic workaround.
    static let modeSwitchRenderRetryDelays: [Double] = [0.001, 0.05, 0.15]

    /// Backoff interval and cap for `tryInitialRender`. Up to 12 retries at
    /// 50ms = ~600ms total before giving up — after that the first user
    /// interaction recovers via the normal `updateVisibleRange` path.
    static let initialRenderRetryDelay: Double = 0.05
    static let initialRenderMaxRetries: Int = 12

    // MARK: - Metal limits

    /// Per-axis max for `MTLTexture` and `CAMetalLayer.drawableSize`. Matches
    /// the Apple Silicon GPU family limit; overshooting silently fails or
    /// downsamples.
    static let maxTextureDimension: CGFloat = 16384

    // MARK: - Prefetch

    /// Pages prefetched on each side of the visible window. 3 covers a
    /// typical scroll-velocity look-ahead without flooding decode work.
    static let prefetchLookahead: Int = 3

    // MARK: - Cache caps

    /// Capacity of the three lockstep page caches: `decodedPages`
    /// (`CVPixelBuffer` ring in `MetalPageManager`), `nsImageCache`
    /// (`NSImage` fast-path), and `textureRing` (`MTLTexture` ring in
    /// `MetalPageRenderer`). All three evict together by LRU.
    ///
    /// Budget breakdown (vertical-double on a tall window, worst working set):
    ///   visible:       4 rows × 2 pages       = 8
    ///   prefetch:      `prefetchLookahead` × 2 = 6
    ///   backscroll:    ≈10 pages of history for flip-back cache
    ///                                          ───
    ///                                           24
    /// Memory cost at typical comic resolution (~14 MB CVPixelBuffer +
    /// ~14 MB MTLTexture per page, NSImage shares CV buffer) is ~670 MB —
    /// right at `MemoryMonitor`'s `.high` pressure threshold (700 MB).
    /// Bumping further is fine on high-RAM machines but risks paging on
    /// low-end hardware.
    static let pageCacheCap: Int = 24
}
