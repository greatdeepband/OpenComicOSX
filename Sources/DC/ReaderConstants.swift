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

    /// Corner-resize hot-zone radius. AppKit reserves a larger diagonal
    /// hot zone at each window corner than along a straight edge — the
    /// cursor turns into the diagonal-resize variant within roughly a
    /// 12 × 12pt square at each corner. The straight-edge guard
    /// (`windowResizeMargin`) caught the four edges but missed the
    /// bottom-left and bottom-right corners specifically (the top
    /// corners are masked by the top-strip guard already). Verified
    /// live 2026-05-22.
    static let windowResizeCornerMargin: CGFloat = 14

    /// Per-step factor for the zoom-replaces-window-resize behaviour in
    /// vertical / vertical-double reading modes. A "zoom in" gesture
    /// (pinch out, ⌘+scroll up) grows the window's frame by
    /// `verticalZoomWindowFactor`; a "zoom out" gesture shrinks it by
    /// 1/`verticalZoomWindowFactor` so two opposing steps return the
    /// window to roughly the same size. 1.10 = 10% per step, deliberately
    /// coarse so a single discrete gesture produces a visible change
    /// rather than a sub-perceptual one.
    static let verticalZoomWindowFactor: CGFloat = 1.10

    /// Cooldown between successive vertical-mode zoom-window-resize
    /// steps. Prevents a single continuous pinch / scroll-wheel event
    /// stream from firing dozens of resize ticks; combined with the
    /// gesture-delta accumulator this caps a typical gesture at 1-3
    /// discrete steps.
    static let verticalZoomStepCooldown: Double = 0.15

    /// Threshold for the gesture-delta accumulator before a single
    /// vertical-mode zoom-window-resize step fires. For pinch this is
    /// summed `event.magnification` (≈ 0.005-0.05 per gesture frame);
    /// for ⌘+scroll it's accumulated `scrollingDeltaY` divided by 100
    /// to bring it into the same approximate range. A coarser
    /// threshold = fewer, more deliberate steps.
    static let verticalZoomGestureThreshold: CGFloat = 0.20

    /// Minimum window content size for the vertical zoom-window-resize
    /// path. Stops a runaway shrink past where the toolbar still reads.
    static let verticalZoomMinSize: CGSize = CGSize(width: 480, height: 360)

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

    /// Radius of the circular magnifier loupe (`MagnifierView`). Drives both
    /// the rendered circle size in SwiftUI and the AppKit hit-region used by
    /// the loupe gesture monitor — they must agree, hence one constant.
    /// 270pt: large enough that a single eye-fixation captures the magnified
    /// region without micro-pans, small enough to leave the bulk of the page
    /// visible around the loupe edge.
    static let loupeRadius: CGFloat = 270

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

    // MARK: - Trackpad swipe page/comic navigation (single & double modes)

    /// Accumulated horizontal trackpad delta (points) that triggers one
    /// page change in single/double mode. Trackpad scroll events arrive
    /// at ~60 Hz with `scrollingDeltaX` of a few points each; a deliberate
    /// 2-finger swipe across the trackpad accumulates ~50-150 points.
    /// 50 fires on a brisk flick without triggering on a small drift.
    static let pageSwipeThreshold: CGFloat = 50

    /// `|deltaX|` must exceed `|deltaY| * this ratio` for a 2-finger scroll
    /// to count as a horizontal swipe (page nav) rather than a vertical
    /// scroll (pan when zoomed). 1.5 lets a clearly-horizontal flick win
    /// while a casual diagonal drift stays out of the page-nav code path.
    static let swipeHorizontalDominanceRatio: CGFloat = 1.5

    // MARK: - CBZ compression (ported from a Python compression engine, 2026-05-14)

    /// Longest-edge pixel cap for recompressed JPEGs inside CBZ archives.
    /// 2000 px stays above the highest reading-mode native resolution on a
    /// 5K display while shrinking large 4000+ px source scans by ~75 %.
    static let cbzCompressionMaxDim: Int = 2000

    /// JPEG quality for colour images during CBZ recompression (0.0-1.0,
    /// matches `kCGImageDestinationLossyCompressionQuality`). 0.78 chosen
    /// to compensate for ImageIO's limitations vs the reference PIL encoder —
    /// PIL writes progressive JPEGs with optimized Huffman tables, which
    /// shrinks output by ~10-20% at the same nominal quality. ImageIO
    /// can only write baseline JPEGs without Huffman optimization, so we
    /// drop the quality knob to land at comparable bytes. Should still
    /// read as visually transparent on comic art at typical reading scales.
    static let cbzCompressionJpegQuality: CGFloat = 0.78

    /// JPEG quality for grayscale images. 0.73 — manga and B&W scans
    /// tolerate slightly more aggressive quantisation than colour. Same
    /// ImageIO-vs-PIL compensation as `cbzCompressionJpegQuality`.
    static let cbzCompressionGrayQuality: CGFloat = 0.73

    /// Skip the rewrite when the recompressed JPEG would be larger than
    /// `original_size * skipThreshold`. 0.95 — only rewrite when we save
    /// at least 5 %, so a near-optimum source doesn't get bounced through
    /// a re-encoder for no benefit.
    static let cbzCompressionSkipThreshold: Double = 0.95

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

    // MARK: - Thumbnails

    /// Max edge (in pixels) for the low-resolution page thumbnails used as
    /// the render-path placeholder when full-res isn't ready yet. 450
    /// preserves comic aspect (~300×450 for a 2:3 page), is small enough
    /// that 200 thumbs fit in ~108 MB, and is large enough to be legible
    /// when scaled up to full-window dimensions. Driven through
    /// `kCGImageSourceThumbnailMaxPixelSize`, so ImageIO uses any
    /// embedded JPEG thumbnail when present and downscales otherwise.
    static let thumbMaxPixel: Int = 450

    /// Capacity of the renderer's `thumbnailRing` (parallel `MTLTexture`
    /// ring used for the render-path placeholder). Separate from
    /// `pageCacheCap` because thumbs are ~1/30th the memory of full-res
    /// textures, so we keep many more of them. 200 covers a typical
    /// long-form comic's entire page count; comics beyond 200 pages fall
    /// back to LRU eviction on the oldest thumbs.
    static let thumbnailRingCap: Int = 200
}
