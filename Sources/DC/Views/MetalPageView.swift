import SwiftUI
import AppKit
import Metal

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

    var onPageChanged: (Int) -> Void
    var onOffsetChanged: (Double) -> Void
    var onMagnificationChanged: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPageChanged: onPageChanged,
            onOffsetChanged: onOffsetChanged,
            onMagnificationChanged: onMagnificationChanged
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
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
            scrollView.minMagnification = 0.1
            scrollView.maxMagnification = 8.0
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
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
        context.coordinator.onMagnificationChanged = onMagnificationChanged

        let needsRebuild = context.coordinator.needsRebuild(
            containerWidth: containerWidth,
            pagesPerRow: pagesPerRow,
            pages: pages,
            layout: layout,
            currentPage: currentPage,
            scale: scale
        )

        if needsRebuild {
            context.coordinator.pages = pages
            context.coordinator.pagesPerRow = pagesPerRow
            context.coordinator.containerWidth = containerWidth
            context.coordinator.layout = layout
            context.coordinator.currentPage = currentPage
            context.coordinator.rebuildLayout()
            context.coordinator.lastLayout = layout
            context.coordinator.lastCurrentPage = currentPage
        }

        if abs(context.coordinator.lastScale - scale) > 0.001 {
            context.coordinator.lastScale = scale
            context.coordinator.scale = scale
            switch layout {
            case .verticalStack:
                scrollView.magnification = scale
            case .singlePage, .doubleSpread:
                // Scale drives frame resize via rebuildLayout; already
                // triggered above when needsRebuild detected the scale-induced
                // layout change. Nothing more to do here.
                break
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
        if let clipView = enclosingScrollView?.contentView {
            // clipView.bounds.origin is the scroll offset in documentView coords.
            // Since this view is isFlipped, y increases downward and clipView.bounds
            // maps directly to the visible region of our coordinate space.
            visible = clipView.bounds
        } else {
            visible = bounds
        }
        let scale = metalLayer.contentsScale
        let maxDim: CGFloat = 16384
        // Clamp the sublayer frame to the documentView's own bounds. If the
        // clipView is larger than the documentView (zoomed out / small page),
        // clipView.bounds can have a negative origin — drawing there would put
        // the sublayer off the documentView, which visually leaks over sibling
        // chrome like the reader top bar. Intersect with documentView bounds.
        let docFrame = CGRect(origin: .zero, size: bounds.size)
        let clamped = visible.intersection(docFrame)
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
    }
}

extension MetalPageView {
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
        private var prefetchTask: Task<Void, Never>?

        /// The visible range of the most-recent `updateVisibleRange()` call.
        /// Used by `onTextureReady()` to re-render after a prefetch upload
        /// completes (so pages that decode AFTER the last scroll event still
        /// get drawn without the user having to scroll again).
        private var lastVisibleRange: ClosedRange<Int> = 0...0

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

        // MARK: - Loupe state
        /// Hosts the MagnifierView inside a borderless child NSPanel.
        /// Using a panel (rather than a subview of window.contentView) avoids
        /// having SwiftUI's WindowGroup-managed hosting view clobber the
        /// loupe during its own layout passes.
        private var loupePanel: NSPanel?
        private var loupeHost: NSHostingView<AnyView>?
        /// Tracks whether we currently hold the NSCursor.hide balance. Kept so
        /// hide/unhide calls stay paired — macOS auto-unhides the cursor when
        /// it moves outside the app window, which breaks naive pairing.
        private var cursorHidden: Bool = false
        /// The page index the loupe panel currently hosts. Used to decide
        /// whether to replace the hosting view wholesale when the page
        /// changes (belt-and-suspenders around NSHostingView/AnyView rootView
        /// updates occasionally retaining stale SwiftUI state).
        private var loupeHostPage: Int?
        private var loupeEventMonitor: Any?
        private var zoomWheelMonitor: Any?
        private var doubleClickMonitor: Any?
        private var pinchMonitor: Any?
        private var loupeImage: (page: Int, nsImage: NSImage)?
        /// Monotonically-increasing token for async image-fetch Tasks. Each
        /// `updateLoupe` call bumps the token, and a Task only applies its
        /// result if the token still matches — so fast drags don't let a
        /// late-resolving stale Task paint over the newest request.
        private var loupeTaskID: UInt64 = 0
        private var loupeTask: Task<Void, Never>?
        private let loupeRadius: CGFloat = 270

        init(
            onPageChanged: @escaping (Int) -> Void,
            onOffsetChanged: @escaping (Double) -> Void,
            onMagnificationChanged: ((CGFloat) -> Void)?
        ) {
            self.onPageChanged = onPageChanged
            self.onOffsetChanged = onOffsetChanged
            self.onMagnificationChanged = onMagnificationChanged
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

        func needsRebuild(containerWidth: CGFloat, pagesPerRow: Int, pages: [ComicPage], layout: ReadingLayout, currentPage: Int, scale: CGFloat) -> Bool {
            if abs(lastContainerWidth - containerWidth) > 1 { return true }
            if lastPagesPerRow != pagesPerRow { return true }
            if lastLayout != layout { return true }
            // For non-vertical layouts, a page-turn or scale change requires a
            // layout rebuild because pagePositions / pageYOffsets must reflect
            // the new page / zoomed frame size.
            switch layout {
            case .singlePage, .doubleSpread:
                if lastCurrentPage != currentPage { return true }
                if abs(lastScale - scale) > 0.001 { return true }
            case .verticalStack:
                break
            }
            return false
        }

        func rebuildLayout() {
            guard let metalView = metalView else { return }

            pagePositions.removeAll()
            pageYOffsets.removeAll()

            sequentialToID = pages.map { $0.id }
            idToSequential.removeAll()
            for (seqIdx, pageID) in sequentialToID.enumerated() {
                idToSequential[pageID] = seqIdx
            }

            switch layout {
            case .verticalStack:
                rebuildVerticalStack()
            case .singlePage:
                rebuildSinglePage()
            case .doubleSpread:
                rebuildDoubleSpread()
            }

            lastContainerWidth = containerWidth
            lastPagesPerRow = pagesPerRow

            metalView.needsDisplay = true
        }

        /// Stacks every page top-to-bottom at `containerWidth * scale` (for
        /// `pagesPerRow == 1`) or split side-by-side honoring `.isSpread`
        /// (for `pagesPerRow == 2`). Matches the pre-step-A behaviour exactly.
        private func rebuildVerticalStack() {
            guard let metalView = metalView else { return }
            let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth
            var y: CGFloat = 0

            if pagesPerRow == 1 {
                for i in 0..<pages.count {
                    let page = pages[i]
                    let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                    let h = totalWidth * ar
                    let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                    pagePositions[page.id] = rect
                    pageYOffsets.append(y)
                    y += h + 4
                }
            } else {
                var i = 0
                while i < pages.count {
                    let page = pages[i]

                    if page.isSpread {
                        let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                        let h = totalWidth * ar
                        let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                        pagePositions[page.id] = rect
                        pageYOffsets.append(y)
                        y += h + 4
                        i += 1
                    } else {
                        let pageWidth = (totalWidth - 2) / 2
                        let leftAR = page.naturalSize.height / max(page.naturalSize.width, 1)
                        let leftH = pageWidth * leftAR
                        let leftRect = CGRect(x: 0, y: y, width: pageWidth, height: leftH)
                        pagePositions[page.id] = leftRect
                        pageYOffsets.append(y)

                        var rightH: CGFloat = leftH
                        if i + 1 < pages.count && !pages[i + 1].isSpread {
                            let rightPage = pages[i + 1]
                            let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                            rightH = pageWidth * rightAR
                            let rightRect = CGRect(x: pageWidth + 2, y: y, width: pageWidth, height: rightH)
                            pagePositions[rightPage.id] = rightRect
                            pageYOffsets.append(y)
                            i += 2
                        } else {
                            i += 1
                        }

                        y += max(leftH, rightH) + 4
                    }
                }
            }

            let totalHeight = y
            metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        }

        /// One page fits to the viewport width (at `scale = 1.0`) at natural
        /// aspect ratio. Zoom is achieved by scaling the documentView frame
        /// so NSScrollView treats the zoomed size as the real document size —
        /// this avoids CAMetalLayer compositing issues that `magnification`
        /// introduces on macOS.
        private func rebuildSinglePage() {
            guard let metalView = metalView else { return }
            guard currentPage >= 0 && currentPage < pages.count else {
                metalView.frame = CGRect(x: 0, y: 0, width: max(1, containerWidth), height: 1)
                return
            }
            let page = pages[currentPage]
            let baseWidth = containerWidth
            let pageAR = page.naturalSize.height / max(page.naturalSize.width, 1)
            let scaledWidth = baseWidth * scale
            let scaledHeight = scaledWidth * pageAR

            let rect = CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)
            pagePositions[page.id] = rect
            pageYOffsets.append(0)

            metalView.frame = CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)
        }

        /// One or two pages side-by-side for a double-page spread. If the
        /// current page is a natural spread (`.isSpread`), it fills the
        /// document full-width and there is no right page. Otherwise the
        /// current page occupies the left slot and `currentPage + 1` (if
        /// it exists and isn't itself a spread) occupies the right slot.
        /// Zoom via frame-resize (no magnification transform).
        private func rebuildDoubleSpread() {
            guard let metalView = metalView else { return }
            guard currentPage >= 0 && currentPage < pages.count else {
                metalView.frame = CGRect(x: 0, y: 0, width: max(1, containerWidth), height: 1)
                return
            }

            let leftPage = pages[currentPage]
            let totalWidth = containerWidth * scale

            if leftPage.isSpread {
                let ar = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
                let h = totalWidth * ar
                let rect = CGRect(x: 0, y: 0, width: totalWidth, height: h)
                pagePositions[leftPage.id] = rect
                pageYOffsets.append(0)
                metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: h)
                return
            }

            let pageWidth = (totalWidth - 2) / 2
            let leftAR = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
            let leftH = pageWidth * leftAR
            let leftRect = CGRect(x: 0, y: 0, width: pageWidth, height: leftH)
            pagePositions[leftPage.id] = leftRect
            pageYOffsets.append(0)

            var rightH: CGFloat = leftH
            let rightIdx = currentPage + 1
            if rightIdx < pages.count && !pages[rightIdx].isSpread {
                let rightPage = pages[rightIdx]
                let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                rightH = pageWidth * rightAR
                let rightRect = CGRect(x: pageWidth + 2, y: 0, width: pageWidth, height: rightH)
                pagePositions[rightPage.id] = rightRect
                pageYOffsets.append(0)
            }

            let spreadHeight = max(leftH, rightH)
            metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: spreadHeight)
        }

        func scrollToPage(_ page: Int) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            guard page >= 0 && page < pageYOffsets.count else { return }
            let targetY = pageYOffsets[page]
            doc.scroll(CGPoint(x: 0, y: targetY))
            sv.reflectScrolledClipView(sv.contentView)
            updateVisibleRange()
        }

        func scrollToFraction(_ fraction: Double) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let maxY = doc.bounds.height - sv.contentView.bounds.height
            guard maxY > 0 else { return }
            let targetY = CGFloat(fraction) * maxY
            doc.scroll(CGPoint(x: 0, y: targetY))
            sv.reflectScrolledClipView(sv.contentView)
            updateVisibleRange()
        }

        func updateVisibleRange() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let docH = doc.bounds.height
            let visH = sv.contentView.bounds.height
            let maxY = docH - visH
            let fraction = maxY > 0 ? Double(sv.contentView.bounds.origin.y / maxY) : 0
            onOffsetChanged(fraction)

            let currentY = sv.contentView.bounds.origin.y
            let bottomY = currentY + visH

            var lo = 0, hi = pageYOffsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageYOffsets[mid] <= currentY { lo = mid } else { hi = mid - 1 }
            }
            // Walk left over duplicate Ys (vertical-double: left+right pages
            // share the same Y) so `firstVisible` is the leftmost page of its row.
            var firstVisible = lo
            while firstVisible > 0 && pageYOffsets[firstVisible - 1] == pageYOffsets[firstVisible] {
                firstVisible -= 1
            }

            var lo2 = firstVisible, hi2 = pageYOffsets.count - 1
            while lo2 < hi2 {
                let mid = (lo2 + hi2 + 1) / 2
                if pageYOffsets[mid] < bottomY { lo2 = mid } else { hi2 = mid - 1 }
            }
            // Walk right over duplicate Ys so `lastVisible` is the rightmost
            // page of its row. Without this, the right page of the last visible
            // row would be skipped in double-page mode.
            var lastVisible = lo2
            while lastVisible + 1 < pageYOffsets.count
                && pageYOffsets[lastVisible + 1] == pageYOffsets[lastVisible] {
                lastVisible += 1
            }

            let visibleRange = firstVisible...lastVisible

            onPageChanged(firstVisible)
            lastVisibleRange = visibleRange
            triggerPrefetch(first: firstVisible, last: lastVisible)

            // Reposition the CAMetalLayer sublayer to cover the visible clipView
            // area before rendering — the sublayer moves with scroll, so the
            // drawable always composites 1:1 against the visible viewport.
            metalView?.updateMetalLayerFrame()

            // Defer the render call by one runloop tick. This ensures the NSScrollView
            // layout pass has fully completed and committed the CAMetalLayer before we
            // call nextDrawable(). Without this defer, Metal can abort with "failed to
            // create drawable texture" because the layer hasn't been presented yet.
            DispatchQueue.main.async { [weak self] in
                self?.render(visibleRange: visibleRange)
            }
        }

        func triggerPrefetch(first: Int, last: Int) {
            guard let manager = pageManager, !pages.isEmpty else { return }
            let lookahead = 3
            let firstIdx = max(0, first - lookahead)
            let lastIdx = min(pages.count - 1, last + lookahead)

            // Visible pages first, then lookahead fanning outward. This way the
            // actually on-screen pages decode before any prefetch neighbour,
            // and stale lookahead work from a prior scroll can't delay them.
            var order: [Int] = []
            for i in first...last where i >= 0 && i < pages.count { order.append(i) }
            var offset = 1
            while order.count < (lastIdx - firstIdx + 1) {
                let after = last + offset
                let before = first - offset
                if after <= lastIdx { order.append(after) }
                if before >= firstIdx { order.append(before) }
                offset += 1
            }

            // Cancel any in-flight prefetch — its remaining pages may already be
            // off-screen, and we don't want it competing with the new order on
            // the actor's queue.
            prefetchTask?.cancel()

            prefetchTask = Task { [weak self] in
                for seqIdx in order {
                    if Task.isCancelled { return }
                    guard let self = self, seqIdx < self.pages.count else { continue }
                    let page = self.pages[seqIdx]
                    // Skip if already uploaded — avoids re-decode cost.
                    if self.renderer?.texture(for: seqIdx) != nil { continue }
                    guard let buffer = await manager.decodePage(pageIndex: seqIdx, from: page.source) else {
                        continue
                    }
                    if Task.isCancelled { return }
                    if self.renderer?.texture(for: seqIdx) == nil {
                        _ = self.renderer?.upload(pixelBuffer: buffer, for: seqIdx)
                    }
                    // Re-render the current visible range so pages whose uploads
                    // landed AFTER the last scroll-driven render still appear.
                    // Hops back to @MainActor; only does real work if the page
                    // is still in the visible range at the time the render runs.
                    await MainActor.run {
                        self.onTextureReady(seqIdx)
                    }
                }
            }
        }

        /// Called on the main actor when a prefetch upload completes. If the
        /// uploaded page is still within the most-recent visible range, we
        /// trigger a render so the user sees the page without needing to
        /// scroll again.
        func onTextureReady(_ seqIdx: Int) {
            guard lastVisibleRange.contains(seqIdx) else { return }
            render(visibleRange: lastVisibleRange)
        }

        @MainActor
        func render(visibleRange: ClosedRange<Int>) {
            guard let metalView = metalView,
                  let renderer = renderer else { return }

            // Ensure the CAMetalLayer sublayer is positioned over the current
            // visible viewport and sized to match, so nextDrawable() gives us a
            // texture matching the on-screen region. updateMetalLayerFrame
            // handles both the frame (position) and drawableSize (in pixels).
            metalView.updateMetalLayerFrame()

            guard let drawable = metalView.metalLayer.nextDrawable() else { return }

            guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }

            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            var renderPositions: [Int: CGRect] = [:]
            for seqIdx in visibleRange {
                guard seqIdx < pages.count else { continue }
                let pageID = pages[seqIdx].id
                if let rect = pagePositions[pageID] {
                    renderPositions[seqIdx] = rect
                }
            }

            let clipView = scrollView?.contentView
            let viewportRect = clipView?.bounds ?? metalView.bounds
            let scrollOriginY = clipView?.bounds.origin.y ?? 0

            renderer.render(
                viewport: viewportRect,
                scrollOriginY: scrollOriginY,
                visibleRange: visibleRange,
                pagePositions: renderPositions,
                renderPassDescriptor: renderPassDescriptor,
                commandBuffer: commandBuffer
            )

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @objc func scrollDidChange(_ notification: Notification) {
            updateVisibleRange()

            // If the loupe is active and the user scrolled without moving the
            // mouse, no leftMouseDragged event fires — so the page under the
            // (fixed-on-screen) cursor has changed but the loupe still shows
            // the old page. Refresh explicitly using the live cursor location.
            guard loupePanel != nil,
                  let scrollView = scrollView,
                  let window = scrollView.window else { return }
            let screenPt = NSEvent.mouseLocation
            let windowPt = window.convertPoint(fromScreen: screenPt)
            let svLocal = scrollView.convert(windowPt, from: nil)
            guard scrollView.bounds.contains(svLocal) else { return }
            // Reassert cursor hidden in case anything between events unhid it.
            hideCursorIfNeeded()
            updateLoupe(at: windowPt, in: window)
        }

        @objc func magnificationDidChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            switch layout {
            case .verticalStack:
                lastScale = sv.magnification
                scale = sv.magnification
                onMagnificationChanged?(sv.magnification)
                recenterIfContentFits()
            case .singlePage, .doubleSpread:
                // We don't use magnification for these layouts; if a
                // notification ever arrives (e.g. magnification forced to 1
                // via range clamping), ignore it.
                break
            }
        }

        /// In single/double-page layouts, re-centre the documentView within
        /// the clipView whenever zooming leaves the content smaller than the
        /// viewport. Called after magnificationDidChange and from the cmd-
        /// scroll-wheel monitor. Vertical modes are skipped — they intentionally
        /// allow the user to scroll freely.
        func recenterIfContentFits() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            switch layout {
            case .verticalStack: return
            case .singlePage, .doubleSpread: break
            }
            let clip = sv.contentView
            // clipView.bounds is in documentView-local coords, scaled by
            // `magnification`. An unzoomed single-page document has the same
            // width as the clipView; when zoomed out, the clipView bounds are
            // LARGER than the document — negative origin centres visually by
            // default in NSScrollView, but the doc can also drift when the
            // user scrolled and then zoomed back out.
            let docSize = doc.frame.size
            let visibleSize = clip.bounds.size
            var newOrigin = clip.bounds.origin
            if visibleSize.width > docSize.width {
                newOrigin.x = (docSize.width - visibleSize.width) / 2
            } else {
                newOrigin.x = max(0, min(newOrigin.x, docSize.width - visibleSize.width))
            }
            if visibleSize.height > docSize.height {
                newOrigin.y = (docSize.height - visibleSize.height) / 2
            } else {
                newOrigin.y = max(0, min(newOrigin.y, docSize.height - visibleSize.height))
            }
            if newOrigin != clip.bounds.origin {
                clip.scroll(to: newOrigin)
                sv.reflectScrolledClipView(clip)
            }
        }

        // MARK: - Loupe

        /// Installs a window-local left-mouse monitor. Unlike an overlay
        /// view, the monitor doesn't consume events — scroll/pinch still work.
        /// Left-click-and-hold activates the loupe to match the single/double
        /// page modes (ZoomableImageView also routes left-click to the loupe).
        func installLoupeMonitor() {
            guard loupeEventMonitor == nil else { return }
            loupeEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handleLoupeEvent(event)
                return event
            }
        }

        /// ⌘+scroll-wheel adjusts zoom. In single/double layouts zoom is
        /// applied via `onMagnificationChanged` → `vm.scale` → frame-resize
        /// (never via scrollView.magnification, which causes CAMetalLayer
        /// compositing to bypass ancestor clipping). In vertical mode the
        /// event is passed through so NSScrollView handles it natively.
        func installZoomWheelMonitor() {
            guard zoomWheelMonitor == nil else { return }
            zoomWheelMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self] event in
                guard let self = self,
                      let scrollView = self.scrollView,
                      event.window === scrollView.window,
                      event.modifierFlags.contains(.command) else {
                    return event
                }
                switch self.layout {
                case .singlePage, .doubleSpread: break
                case .verticalStack: return event
                }
                // Apply a proportional step to our own `scale` state (flows
                // through ReaderViewModel → SwiftUI → rebuildLayout). We do
                // NOT touch scrollView.magnification in single/double modes.
                let step: CGFloat = 1 + CGFloat(event.scrollingDeltaY) * 0.01
                let newScale = self.scale * step
                let clamped = min(max(newScale, 0.25), 8.0)
                self.onMagnificationChanged?(clamped)
                return nil // consume the event
            }
        }

        /// Double-click inside the metal view resets zoom to 1.0.
        /// Drives scale via `onMagnificationChanged` → `vm.scale` → frame-resize
        /// rather than scrollView.magnification (single/double modes only).
        func installDoubleClickMonitor() {
            guard doubleClickMonitor == nil else { return }
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                guard let self = self,
                      let scrollView = self.scrollView,
                      event.clickCount == 2,
                      event.window === scrollView.window else {
                    return event
                }
                switch self.layout {
                case .singlePage, .doubleSpread: break
                case .verticalStack: return event
                }
                // Ensure the click is inside the scroll area (not on toolbar).
                let svLocal = scrollView.convert(event.locationInWindow, from: nil)
                guard scrollView.bounds.contains(svLocal) else { return event }
                // Reset zoom via the scale binding rather than magnification.
                self.onMagnificationChanged?(1.0)
                return nil
            }
        }

        /// Trackpad pinch gesture → updates `vm.scale` via the onMagnificationChanged
        /// callback. Replaces the NSScrollView.magnification pinch path for
        /// single/double layouts, which don't use NSScrollView magnification.
        func installPinchMonitor() {
            guard pinchMonitor == nil else { return }
            pinchMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .magnify
            ) { [weak self] event in
                guard let self = self,
                      let scrollView = self.scrollView,
                      event.window === scrollView.window else {
                    return event
                }
                switch self.layout {
                case .singlePage, .doubleSpread: break
                case .verticalStack: return event
                }
                let step: CGFloat = 1 + event.magnification
                let newScale = self.scale * step
                let clamped = min(max(newScale, 0.25), 8.0)
                self.onMagnificationChanged?(clamped)
                return nil
            }
        }

        private func handleLoupeEvent(_ event: NSEvent) {
            guard let scrollView = scrollView,
                  let window = scrollView.window,
                  event.window === window else { return }

            // Only react when the cursor is over the scrollView area.
            let svLocal = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(svLocal) else {
                // Still tear down on mouse-up if the user dragged off the
                // scroll area before releasing.
                if event.type == .leftMouseUp {
                    showCursorIfNeeded()
                    hideLoupe()
                }
                return
            }

            switch event.type {
            case .leftMouseDown:
                hideCursorIfNeeded()
                updateLoupe(at: event.locationInWindow, in: window)
            case .leftMouseDragged:
                // Defensive re-hide: macOS can auto-unhide the cursor on certain
                // focus or panel events during a drag, so keep asserting hidden
                // while the user is still holding the left button.
                hideCursorIfNeeded()
                updateLoupe(at: event.locationInWindow, in: window)
            case .leftMouseUp:
                showCursorIfNeeded()
                hideLoupe()
            default:
                break
            }
        }

        private func hideCursorIfNeeded() {
            guard !cursorHidden else { return }
            NSCursor.hide()
            cursorHidden = true
        }

        private func showCursorIfNeeded() {
            guard cursorHidden else { return }
            NSCursor.unhide()
            cursorHidden = false
        }

        /// Resolves the page under the cursor, fetches its NSImage, and shows
        /// the loupe. Coordinates are derived by asking the documentView itself
        /// to convert the window-local point — this avoids every manual
        /// flip/offset calculation and matches whatever coordinate system the
        /// documentView is using (isFlipped = true here).
        private func updateLoupe(at windowPt: CGPoint, in window: NSWindow) {
            guard let scrollView = scrollView,
                  let documentView = scrollView.documentView else { return }

            loupeTaskID &+= 1
            loupeTask?.cancel()

            let docPt = documentView.convert(windowPt, from: nil)
            let seqIdx = findSequentialIndex(at: docPt)
            guard seqIdx >= 0, seqIdx < pages.count else {
                Task { await DCLogger.shared.log("[loupe] miss pg seqIdx=\(seqIdx) docPt=\(docPt)") }
                return
            }

            let pageID = sequentialToID[seqIdx]
            guard let pageRect = pagePositions[pageID] else { return }
            let cursorInImage = CGPoint(
                x: docPt.x - pageRect.minX,
                y: docPt.y - pageRect.minY
            )
            let imageViewSize = pageRect.size

            Task { await DCLogger.shared.log("[loupe] win=\(windowPt) doc=\(docPt) pg=\(seqIdx) rect=\(pageRect) cursor=\(cursorInImage)") }

            if let cached = loupeImage, cached.page == seqIdx {
                showMagnifier(image: cached.nsImage,
                              page: seqIdx,
                              cursor: cursorInImage,
                              imageViewSize: imageViewSize,
                              windowPt: windowPt,
                              in: window)
                return
            }

            if let img = pageManager?.nsImage(for: seqIdx) {
                loupeImage = (seqIdx, img)
                showMagnifier(image: img,
                              page: seqIdx,
                              cursor: cursorInImage,
                              imageViewSize: imageViewSize,
                              windowPt: windowPt,
                              in: window)
                return
            }

            guard let pageManager = pageManager else { return }
            let pageSource = pages[seqIdx].source
            let myID = loupeTaskID
            loupeTask = Task { [weak self] in
                var buffer = await pageManager.page(for: seqIdx)
                if buffer == nil {
                    buffer = await pageManager.decodePage(pageIndex: seqIdx, from: pageSource)
                }
                guard !Task.isCancelled,
                      let b = buffer,
                      let nsImage = Coordinator.nsImage(from: b) else { return }
                await MainActor.run {
                    guard let self = self, self.loupeTaskID == myID else { return }
                    self.loupeImage = (seqIdx, nsImage)
                    self.showMagnifier(image: nsImage,
                                       page: seqIdx,
                                       cursor: cursorInImage,
                                       imageViewSize: imageViewSize,
                                       windowPt: windowPt,
                                       in: window)
                }
            }
        }

        private func showMagnifier(image: NSImage,
                                   page: Int,
                                   cursor: CGPoint,
                                   imageViewSize: CGSize,
                                   windowPt: CGPoint,
                                   in window: NSWindow) {
            let loupePx = loupeRadius
            let size = NSSize(width: loupePx * 2, height: loupePx * 2)

            // NSPanel is positioned in screen coords (bottom-left origin).
            let screenPt = window.convertPoint(toScreen: windowPt)
            let panelFrame = NSRect(
                x: screenPt.x - loupePx,
                y: screenPt.y - loupePx,
                width: size.width,
                height: size.height
            )

            let magnifier = MagnifierView(
                image: image,
                cursorInImageView: cursor,
                imageViewSize: imageViewSize
            ).id(page)
            let wrapped = AnyView(magnifier)

            // Reuse the panel when the page hasn't changed — only the cursor
            // and panel frame need updating. When the page changes, build a
            // brand-new NSHostingView so no SwiftUI state can carry over.
            if let panel = loupePanel, let host = loupeHost, loupeHostPage == page {
                host.rootView = wrapped
                panel.setFrame(panelFrame, display: true)
                return
            }

            // Page changed (or first show): tear down any existing host and
            // build fresh.
            if let oldHost = loupeHost {
                oldHost.removeFromSuperview()
                loupeHost = nil
            }

            let panel: NSPanel
            if let existing = loupePanel {
                panel = existing
                panel.setFrame(panelFrame, display: true)
            } else {
                let p = NSPanel(
                    contentRect: panelFrame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = false
                p.level = .floating
                p.ignoresMouseEvents = true
                p.hidesOnDeactivate = false
                p.isMovableByWindowBackground = false
                window.addChildWindow(p, ordered: .above)
                loupePanel = p
                panel = p
            }

            let host = NSHostingView(rootView: wrapped)
            host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host
            loupeHost = host
            loupeHostPage = page
        }

        func hideLoupe() {
            // Invalidate any in-flight fetch so its showMagnifier doesn't run
            // after the user has released right-click.
            loupeTaskID &+= 1
            loupeTask?.cancel()
            loupeTask = nil

            if let panel = loupePanel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            loupePanel = nil
            loupeHost = nil
            loupeHostPage = nil
            showCursorIfNeeded()
        }

        /// Converts a 32BGRA CVPixelBuffer into an NSImage by snapshotting
        /// pixel memory into a CGImage. Called off the main actor; the result
        /// is Sendable (NSImage + CGImage are value-semantic enough here).
        nonisolated private static func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
            return makeNSImageFromPixelBuffer(pixelBuffer)
        }

        /// Binary search: finds the sequential index whose page rect contains `docPt.y`.
        /// Returns -1 if not found.
        private func findSequentialIndex(at docPt: CGPoint) -> Int {
            guard !pageYOffsets.isEmpty else { return -1 }

            var lo = 0, hi = pageYOffsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageYOffsets[mid] <= docPt.y { lo = mid } else { hi = mid - 1 }
            }

            // In vertical-double mode, left and right pages of a row share the
            // same Y offset. Walk over all pages at this Y and return the one
            // whose horizontal bounds contain docPt.x.
            var idx = lo
            while idx > 0 && pageYOffsets[idx - 1] == pageYOffsets[idx] {
                idx -= 1
            }
            let rowY = pageYOffsets[idx]
            while idx < pageYOffsets.count && pageYOffsets[idx] == rowY {
                let pageID = sequentialToID[idx]
                if let rect = pagePositions[pageID],
                   docPt.x >= rect.minX && docPt.x <= rect.maxX,
                   docPt.y >= rect.minY && docPt.y <= rect.maxY {
                    return idx
                }
                idx += 1
            }
            return -1
        }
    }
}
