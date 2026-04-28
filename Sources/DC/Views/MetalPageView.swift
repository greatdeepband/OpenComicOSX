import SwiftUI
import AppKit
import Metal

// MARK: - LoupeOverlayState
/// State for the SwiftUI loupe overlay. The loupe is a SwiftUI MagnifierView
/// placed inside the reader's container; natural SwiftUI clipping bounds the
/// circle to the reader frame. Position is in SwiftUI top-left coords within
/// the reader's outer ZStack (same space as `geo.size` from the
/// GeometryReader).
struct LoupeOverlayState {
    var position: CGPoint
    var image: NSImage
    var imageViewSize: CGSize
    var cursorInImage: CGPoint
}

// MARK: - ReadingLayout

/// How `MetalPageView` should lay out its pages in the NSScrollView.
/// - `.verticalStack` — pages stacked top-to-bottom, user scrolls vertically.
///   `pagesPerRow: 1` for single column, `2` for side-by-side.
/// - `.singlePage` — exactly one page fits the viewport; user zooms + pans.
/// - `.doubleSpread` — one or two pages in a spread; user zooms + pans. Honors
///   `ComicPage.isSpread` for natural full-width spread pages.
enum ReadingLayout: Equatable {
    case verticalStack(pagesPerRow: Int)
    case singlePage
    case doubleSpread
}

// MARK: - MetalPageView

/// Metal-backed reader view using NSScrollView for scroll math
/// and CAMetalLayer for GPU rendering. Replaces the NSStackView
/// + NSImage pipeline for vertical and vertical-double modes.
///
/// Coordinator behaviour is split across sibling extension files:
///   - `MetalPageView+Layout.swift` — rebuild, scroll, visible-range, recentre, hit-test
///   - `MetalPageView+Render.swift` — render, prefetch, onTextureReady
///   - `MetalPageView+Loupe.swift`  — loupe NSEvent monitor + overlay state
///   - `MetalPageView+Zoom.swift`   — ⌘+wheel / double-click / pinch zoom monitors
///
/// This file holds the NSViewRepresentable struct, the MetalCanvasView NSView
/// subclass, and the Coordinator class declaration with stored properties +
/// init/deinit. Stored properties on Coordinator are package-internal so the
/// sibling extensions can read/write them.
struct MetalPageView: NSViewRepresentable {
    let pages: [ComicPage]
    let layout: ReadingLayout
    let currentPage: Int
    let pagesPerRow: Int  // 1 = vertical single, 2 = vertical double
    let scale: CGFloat
    let containerWidth: CGFloat
    let restorePage: Int?
    let restoreOffset: Double?
    let pageManager: MetalPageManager
    /// Top inset applied via `NSScrollView.contentInsets` so the scroll view
    /// stretches to the full window height (required to dodge the macOS 26
    /// "scroll-into-header" bug) while still reserving the top region for an
    /// overlaid UI bar. The scroll view's frame is full-height; content simply
    /// can't enter the inset band.
    var topContentInset: CGFloat = 0

    var onPageChanged: (Int) -> Void
    var onOffsetChanged: (Double) -> Void
    var onMagnificationChanged: ((CGFloat) -> Void)?
    /// Fires whenever the loupe state changes. Pass `nil` to hide the overlay
    /// (cursor-off-window, left-mouse-up, off-page with no fallback, etc.).
    /// ReaderView drives a SwiftUI MagnifierView overlay from this state so
    /// the loupe is naturally clipped to the reader frame.
    var onLoupeOverlay: ((LoupeOverlayState?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPageChanged: onPageChanged,
            onOffsetChanged: onOffsetChanged,
            onMagnificationChanged: onMagnificationChanged,
            onLoupeOverlay: onLoupeOverlay
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        Task { await DCLogger.shared.log("SWITCH: makeNSView layout=\(layout) pages.count=\(pages.count) pagesPerRow=\(pagesPerRow) containerWidth=\(containerWidth)") }
        let scrollView = NSScrollView()
        // Belt-and-suspenders fix for the macOS 26 (Tahoe) scroll-into-header
        // bug: setting borderType = .noBorder independently disables the
        // rendering path that lets NSScrollView content bleed above the view.
        // See: https://troz.net/post/2026/appkit-table-scroll-bug-in-macos-tahoe/
        scrollView.borderType = .noBorder
        // Reserve space for an overlaid top bar via NSScrollView's native
        // contentInsets rather than SwiftUI .padding. SwiftUI padding frames
        // the scroll view at Y=topInset, which does NOT satisfy the Tahoe
        // bug's precondition (the scroll view must stretch top-to-bottom of
        // its containing window content area). With contentInsets the scroll
        // view frame is full-height, the clip view honors the inset as a
        // non-scrollable top band, and zoomed content cannot overflow above.
        if topContentInset > 0 {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: topContentInset, left: 0, bottom: 0, right: 0
            )
        }
        // Ensure the scroll view and its clip view never bleed outside the
        // frame SwiftUI has allocated, even when magnification > 1. Without
        // this the zoomed content can overflow upward into the reader top bar
        // under .fullSizeContentView / .hiddenTitleBar window styling.
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true
        // Vertical modes: vertical scroller only. Single/double: both axes —
        // a zoomed page can overhang in either direction, so both scrollers
        // must be available. autohidesScrollers keeps the chrome clean.
        scrollView.hasVerticalScroller = true
        switch layout {
        case .verticalStack:
            scrollView.hasHorizontalScroller = false
        case .singlePage, .doubleSpread:
            scrollView.hasHorizontalScroller = true
        }
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        // Vertical modes use NSScrollView's native magnification (fast CALayer
        // transform). Single/double use frame-resize zoom — NSScrollView's
        // magnification transform is NOT safe with CAMetalLayer because the
        // direct-to-surface Metal drawable bypasses ancestor layer clipping
        // when a scale transform is present on the clipView. Instead, zoom
        // is achieved by scaling the documentView frame in `rebuildLayout`.
        scrollView.allowsMagnification = true
        switch layout {
        case .verticalStack:
            scrollView.minMagnification = ReaderConstants.nativeMagnificationMin
            scrollView.maxMagnification = ReaderConstants.nativeMagnificationMax
            scrollView.magnification = scale
        case .singlePage, .doubleSpread:
            // Magnification stays at 1.0. `scale` drives documentView resize
            // in the layout path.
            scrollView.minMagnification = 1.0
            scrollView.maxMagnification = 1.0
            scrollView.magnification = 1.0
        }

        let metalView = MetalCanvasView(frame: .zero)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.frame = CGRect(x: 0, y: 0, width: containerWidth, height: 1000) // placeholder

        guard let renderer = MetalPageRenderer() else {
            fatalError("Metal is not available on this device")
        }

        context.coordinator.scrollView = scrollView
        context.coordinator.metalView = metalView
        context.coordinator.renderer = renderer
        context.coordinator.pageManager = pageManager
        context.coordinator.pages = pages
        context.coordinator.pagesPerRow = pagesPerRow
        context.coordinator.containerWidth = containerWidth
        context.coordinator.scale = scale
        context.coordinator.lastScale = scale

        scrollView.documentView = metalView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )
        // Watch the clipView for size changes. On mode switch, SwiftUI hands
        // us a scrollView whose clipView hasn't been sized yet — MetalCanvas
        // View.layout() fires before the clipView has settled, so drawableSize
        // stays 0 and the pending render can't paint. When the clipView's
        // bounds eventually change to non-zero, we retry the pending render.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewGeometryChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewGeometryChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Restore scroll position
        if let page = restorePage {
            DispatchQueue.main.async {
                context.coordinator.scrollToPage(page)
            }
        } else if let offset = restoreOffset {
            DispatchQueue.main.async {
                context.coordinator.scrollToFraction(offset)
            }
        }

        // Wire the layout-completed hook so we can retry the initial render
        // after the scrollView has actually sized the clipView. Without this
        // retry, switching to single/double-page mode lands a render() call
        // BEFORE drawableSize is set (because clip.bounds is still 0×0), so
        // nextDrawable() returns nil and nothing gets drawn until the user
        // triggers another update (e.g. a page turn).
        metalView.onLayoutCompleted = { [weak coordinator = context.coordinator] in
            coordinator?.handleLayoutCompleted()
        }

        // Install the right-mouse loupe monitor. Using an NSEvent local
        // monitor instead of an overlay view because vertical modes use
        // NSScrollView — any overlay sibling that intercepts events would
        // also block scroll-wheel / pinch-zoom gestures.
        context.coordinator.installLoupeMonitor()
        context.coordinator.installZoomWheelMonitor()
        context.coordinator.installDoubleClickMonitor()
        context.coordinator.installPinchMonitor()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        Task { await DCLogger.shared.log("SWITCH: updateNSView layout=\(layout) pages.count=\(pages.count) currentPage=\(currentPage) scale=\(scale) containerWidth=\(containerWidth)") }
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
        context.coordinator.onMagnificationChanged = onMagnificationChanged
        context.coordinator.onLoupeOverlay = onLoupeOverlay

        let needsRebuild = context.coordinator.needsRebuild(
            containerWidth: containerWidth,
            pagesPerRow: pagesPerRow,
            pages: pages,
            layout: layout,
            currentPage: currentPage,
            scale: scale
        )

        // Update the coordinator's scale BEFORE rebuildLayout runs — otherwise
        // rebuildSinglePage/rebuildDoubleSpread reads the previous-cycle scale
        // and builds a documentView frame one zoom step behind the real value.
        let oldScale = context.coordinator.lastScale
        let scaleChanged = abs(oldScale - scale) > ReaderConstants.scaleEqualityEpsilon

        if scaleChanged {
            context.coordinator.lastScale = scale
            context.coordinator.scale = scale
        }

        if needsRebuild {
            let layoutChanged = context.coordinator.lastLayout != layout
            context.coordinator.pages = pages
            context.coordinator.pagesPerRow = pagesPerRow
            context.coordinator.containerWidth = containerWidth
            context.coordinator.layout = layout
            context.coordinator.currentPage = currentPage
            context.coordinator.rebuildLayout()
            context.coordinator.lastLayout = layout
            context.coordinator.lastCurrentPage = currentPage

            if layoutChanged {
                let coord = context.coordinator
                // Reset the scrollView's magnification to match the new
                // layout's zoom semantics. Vertical uses native magnification
                // (range nativeMagnificationMin–nativeMagnificationMax);
                // single/double pin it at 1.0 (zoom is implemented via
                // frame-resize). Without this reset, a stale magnification
                // from a previous vertical session makes the clipView report
                // a scaled-down bounds.size, throwing off the centre math.
                switch layout {
                case .singlePage, .doubleSpread:
                    scrollView.minMagnification = 1.0
                    scrollView.maxMagnification = 1.0
                    scrollView.magnification = 1.0
                case .verticalStack:
                    scrollView.minMagnification = ReaderConstants.nativeMagnificationMin
                    scrollView.maxMagnification = ReaderConstants.nativeMagnificationMax
                    scrollView.magnification = scale
                }

                // Force a synchronous layout pass so the metalView's frame
                // change from rebuildLayout commits before any render fires.
                // Without this, the new layout's first render runs against
                // the previous layout's metalLayer frame — visible as a
                // stale frame on screen when returning from single/double
                // back to vertical (and vice-versa).
                coord.metalView?.layoutSubtreeIfNeeded()
                coord.metalView?.updateMetalLayerFrame()

                // Restore scroll position from the model. On mode switch,
                // makeNSView's one-shot restore doesn't fire (SwiftUI reuses
                // the Coordinator), so we need to do it here. For vertical
                // we use the saved fraction (preserves mid-page position);
                // for single/double we just snap to currentPage.
                switch layout {
                case .verticalStack:
                    if let offset = restoreOffset {
                        DispatchQueue.main.async { [weak coord] in
                            coord?.scrollToFraction(offset)
                        }
                    } else if let page = restorePage {
                        DispatchQueue.main.async { [weak coord] in
                            coord?.scrollToPage(page)
                        }
                    }
                case .singlePage, .doubleSpread:
                    // currentPage is already in the coordinator; rebuildSinglePage
                    // / rebuildDoubleSpread laid out for that page. Recentre via
                    // the existing centre-on-rebuild block below.
                    break
                }

                // 3-stage render retry to walk CAMetalLayer's drawable chain
                // past whatever stale frame is queued from the previous
                // layout. Without this, the first render after rebuild
                // races with the layout commit and presents a black frame.
                for delay in ReaderConstants.modeSwitchRenderRetryDelays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak coord] in
                        coord?.render(visibleRange: coord?.lastVisibleRange ?? 0...0)
                    }
                }
            }
        }

        if scaleChanged, case .verticalStack = layout {
            // Vertical modes use NSScrollView's native magnification transform
            // (CALayer-level); single/double resize the documentView in
            // rebuildLayout above, so no additional action is needed.
            scrollView.magnification = scale
        }

        // Single/double-page: after initial layout, any page turn, or any
        // zoom step, recentre the documentView so the image centre lands at
        // the viewport centre. The doc is now intrinsically padded to ≥ clip
        // (rebuildSinglePage / rebuildDoubleSpread), so the centred scroll
        // origin is always non-negative — NSClipView won't clamp it back.
        let isSingleOrDouble = (layout == .singlePage || layout == .doubleSpread)
        if isSingleOrDouble, (needsRebuild || scaleChanged) {
            if let doc = scrollView.documentView {
                let clip = scrollView.contentView
                let topInset = scrollView.contentInsets.top
                let usableH = max(0, clip.bounds.size.height - topInset)
                let usableW = clip.bounds.size.width
                // Place doc-centre at usable-viewport-centre. doc.midY -
                // (topInset + usableH/2) collapses to -topInset when
                // doc.height == usableH (the fit-to-window case), which
                // NSClipView accepts because contentInsets.top extends the
                // legal scroll range upward by exactly that amount.
                let newOrigin = CGPoint(
                    x: max(0, doc.bounds.size.width / 2 - usableW / 2),
                    y: max(-topInset, doc.bounds.size.height / 2 - (topInset + usableH / 2))
                )
                clip.scroll(to: newOrigin)
                scrollView.reflectScrolledClipView(clip)
            }
        }

        context.coordinator.updateVisibleRange()
    }

}

// MARK: - MetalCanvasView

/// NSView subclass used as NSScrollView.documentView in the vertical reader.
///
/// Architecture: the view's frame is the full stacked-pages document size
/// (tens of thousands of points tall). The backing layer is a plain CALayer
/// of the same bounds — so the scroll extents are correct — and a
/// CAMetalLayer sublayer is positioned over the visible clipView area on
/// every scroll/layout. The sublayer's bounds match the viewport, and its
/// drawableSize is the viewport in pixels, so the Metal-rendered drawable
/// composites 1:1 without any non-uniform scaling.
///
/// Prior versions used CAMetalLayer as the backing layer directly. With a
/// 100,000pt-tall backing layer and a viewport-sized drawable, CAMetalLayer's
/// default `contentsGravity = resize` stretched the drawable ~100× vertically
/// to fill the layer, which produced the extreme vertical-stretch bug in
/// vertical-scroll and vertical-double modes.
final class MetalCanvasView: NSView {
    var metalLayer: CAMetalLayer!
    /// Fires after every `layout()` completion. The Coordinator hooks this so
    /// it can trigger the first render AFTER the scrollView has committed
    /// layout — before that, clipView.bounds may still be (0,0) and
    /// CAMetalLayer's drawableSize will be zero, which makes nextDrawable()
    /// return nil and the page render silently no-op.
    var onLayoutCompleted: (() -> Void)?

    /// CRITICAL: use a flipped coordinate system (y=0 at top, increasing downward).
    /// The rest of the reader code — `pageYOffsets` (ascending from 0 for page 0),
    /// `updateVisibleRange()` binary search, `scrollToPage()`, and the vertex
    /// shader in Shaders.metal (`viewY = (docY - scrollOriginY) / viewportHeight`,
    /// then `ndcY = 1.0 - viewY*2`) all assume top-origin document coordinates.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let backing = CALayer()

        let metal = CAMetalLayer()
        metal.device = MTLCreateSystemDefaultDevice()
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = false
        metal.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        metal.contentsGravity = .topLeft
        backing.addSublayer(metal)
        self.metalLayer = metal
        return backing
    }

    /// Positions the CAMetalLayer sublayer over the visible clipView area and
    /// sizes the drawable to match (in pixels). Call from `layout()` and from
    /// the scroll-change handler before rendering.
    func updateMetalLayerFrame() {
        guard let metalLayer = metalLayer else { return }
        let visible: CGRect
        let topInset: CGFloat
        if let scrollView = enclosingScrollView {
            // clipView.bounds.origin is the scroll offset in documentView coords.
            // Since this view is isFlipped, y increases downward and clipView.bounds
            // maps directly to the visible region of our coordinate space.
            visible = scrollView.contentView.bounds
            topInset = scrollView.contentInsets.top
        } else {
            visible = bounds
            topInset = 0
        }
        let scale = metalLayer.contentsScale
        let maxDim: CGFloat = ReaderConstants.maxTextureDimension
        // Carve the top-inset band out of the visible rect before intersecting
        // with the documentView. The inset band lives visually at clipView Y
        // [0, topInset], which maps to doc Y [origin.y, origin.y + topInset].
        // CAMetalLayer's direct-to-surface compositing bypasses clipView
        // masksToBounds clipping, so if we leave the metalLayer frame covering
        // this band it bleeds over the SwiftUI top-bar overlay as soon as the
        // user scrolls the zoomed content past origin.y = -topInset.
        var safeVisible = visible
        if topInset > 0 {
            safeVisible.origin.y += topInset
            safeVisible.size.height -= topInset
        }
        let docFrame = CGRect(origin: .zero, size: bounds.size)
        let clamped = safeVisible.intersection(docFrame)
        let w = max(1, min(clamped.width * scale, maxDim))
        let h = max(1, min(clamped.height * scale, maxDim))
        guard w > 0, h > 0, clamped.width > 0, clamped.height > 0 else { return }

        // Disable implicit CA animation so the layer snaps to the scroll
        // position on each scroll event instead of tweening behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = clamped
        metalLayer.drawableSize = CGSize(width: w, height: h)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateMetalLayerFrame()
        onLayoutCompleted?()
    }
}

// MARK: - Coordinator

extension MetalPageView {
    /// Coordinator for `MetalPageView`. Stored properties live here; method
    /// implementations are split across sibling extension files (Layout,
    /// Render, Loupe, Zoom) to keep each concern in a focused, navigable file.
    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var metalView: MetalCanvasView?
        var renderer: MetalPageRenderer?
        var pageManager: MetalPageManager?
        var pages: [ComicPage] = []
        var pagesPerRow: Int = 1
        var containerWidth: CGFloat = 0
        var scale: CGFloat = 1.0
        var lastScale: CGFloat = 1.0

        /// Handle to the most-recent prefetch Task. On fast scroll, each scroll
        /// event would otherwise spawn a new Task that keeps decoding already-
        /// obsolete pages; cancelling the previous one lets the actor serve the
        /// current visible range first.
        var prefetchTask: Task<Void, Never>?

        /// The page-index range the in-flight prefetch task is decoding for.
        /// Used to dedupe identical re-triggers — when `updateVisibleRange`
        /// fires repeatedly during initial layout (multiple bounds-change
        /// notifications, layout-completed retries, etc.) for the same
        /// visible range, we must NOT cancel and respawn the task each time.
        /// Each cancel kills decode mid-flight and the texture never lands;
        /// dedupe lets the first task run to completion.
        var prefetchInFlightRange: ClosedRange<Int>?

        /// The visible range of the most-recent `updateVisibleRange()` call.
        /// Used by `onTextureReady()` to re-render after a prefetch upload
        /// completes (so pages that decode AFTER the last scroll event still
        /// get drawn without the user having to scroll again).
        var lastVisibleRange: ClosedRange<Int> = 0...0

        /// True while we still owe an initial render for the current layout.
        /// Set by `rebuildLayout` and consumed by `handleLayoutCompleted` —
        /// lets us retry the first render after the scrollView has sized
        /// its clipView / drawable, otherwise nextDrawable() returns nil
        /// and the page silently fails to paint on mode switch.
        var pendingInitialRender: Bool = false

        var sequentialToID: [Int] = []
        var idToSequential: [Int: Int] = [:]

        var pagePositions: [Int: CGRect] = [:]
        var pageYOffsets: [CGFloat] = []

        var lastContainerWidth: CGFloat = 0
        var lastPagesPerRow: Int = 0
        var layout: ReadingLayout = .verticalStack(pagesPerRow: 1)
        var currentPage: Int = 0
        var lastLayout: ReadingLayout = .verticalStack(pagesPerRow: 1)
        var lastCurrentPage: Int = -1

        var onPageChanged: (Int) -> Void = { _ in }
        var onOffsetChanged: (Double) -> Void = { _ in }
        var onMagnificationChanged: ((CGFloat) -> Void)?
        var onLoupeOverlay: ((LoupeOverlayState?) -> Void)?

        // MARK: - Loupe state
        /// Loupe is now rendered as a SwiftUI overlay inside the reader's
        /// clipped ZStack via `onLoupeOverlay`. The Coordinator only tracks
        /// the last-decoded image (to avoid redecoding per drag frame), the
        /// cursor-hide balance, and the NSEvent monitor itself.
        ///
        /// Tracks whether we currently hold the NSCursor.hide balance. Kept so
        /// hide/unhide calls stay paired — macOS auto-unhides the cursor when
        /// it moves outside the app window, which breaks naive pairing.
        var cursorHidden: Bool = false
        var loupeEventMonitor: Any?
        var zoomWheelMonitor: Any?
        var doubleClickMonitor: Any?
        var pinchMonitor: Any?
        var loupeImage: (page: Int, nsImage: NSImage)?
        /// The page the loupe is currently magnifying. Sticky across cursor
        /// excursions into row/column gaps and past document edges so the
        /// loupe never disappears mid-drag — same UX as the pre-Metal
        /// single/double-page ZoomableImageView, where the loupe simply
        /// fades its content to black when the cursor leaves the image
        /// bounds while staying visible until mouseUp. Reset on hideLoupe.
        var loupeActivePage: Int?
        /// True once a left-mouse-down has STARTED a loupe drag below the
        /// top-bar strip. While true, subsequent `.leftMouseDragged`
        /// events are processed regardless of where the cursor wanders
        /// (including into the top strip), so the loupe behaves
        /// symmetrically on all four edges. The strip-skip guard only
        /// gates the INITIAL `.leftMouseDown` — it keeps a click on the
        /// navbar from spawning a loupe.
        var loupeDragActive: Bool = false
        /// Monotonically-increasing token for async image-fetch Tasks. Each
        /// `updateLoupe` call bumps the token, and a Task only applies its
        /// result if the token still matches — so fast drags don't let a
        /// late-resolving stale Task paint over the newest request.
        var loupeTaskID: UInt64 = 0
        var loupeTask: Task<Void, Never>?
        let loupeRadius: CGFloat = 270

        init(
            onPageChanged: @escaping (Int) -> Void,
            onOffsetChanged: @escaping (Double) -> Void,
            onMagnificationChanged: ((CGFloat) -> Void)?,
            onLoupeOverlay: ((LoupeOverlayState?) -> Void)?
        ) {
            self.onPageChanged = onPageChanged
            self.onOffsetChanged = onOffsetChanged
            self.onMagnificationChanged = onMagnificationChanged
            self.onLoupeOverlay = onLoupeOverlay
        }

        deinit {
            if let monitor = loupeEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = zoomWheelMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = doubleClickMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = pinchMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if cursorHidden { NSCursor.unhide() }
        }

        // MARK: - Notification selectors

        // These three @objc methods MUST live in the class body, not in an
        // extension. NotificationCenter.addObserver(_, selector:) resolves
        // selectors via the Objective-C runtime; @objc extension methods on
        // `final class : NSObject` aren't always exposed reliably, which
        // silently breaks vertical-mode scroll-tracking (the symptom: pages
        // don't render past the initial position because scrollDidChange
        // never fires). The actual implementations are in
        // MetalPageView+Layout.swift as plain Swift methods.

        @objc func scrollDidChange(_ notification: Notification) {
            scrollDidChangeImpl()
        }

        @objc func magnificationDidChange(_ notification: Notification) {
            magnificationDidChangeImpl()
        }

        @objc func clipViewGeometryChanged(_ notification: Notification) {
            clipViewGeometryChangedImpl()
        }
    }
}
