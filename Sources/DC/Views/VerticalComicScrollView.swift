import SwiftUI

// MARK: - Flipped NSStackView (top-left origin, like UIKit)

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }

    /// NSStackView's default hitTest routes events to the wrong subview in horizontal
    /// layouts. Override to do a proper frame-based hit-test across arranged subviews.
    ///
    /// NSView.hitTest(_:) contract: point is in the RECEIVER'S superview coordinate space.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPt = convert(point, from: superview)
        guard bounds.contains(localPt) else { return nil }
        for subview in arrangedSubviews.reversed() {
            if let hit = subview.hitTest(localPt) { return hit }
        }
        return self
    }
}

// MARK: - Page drawing view

final class ComicPageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    /// Natural aspect ratio (height/width) used for layout before image is decoded.
    var naturalAR: CGFloat = 1.4

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = image else {
            // Draw a subtle placeholder while the image is loading.
            NSColor(white: 0.12, alpha: 1).setFill()
            bounds.fill()
            return
        }
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        let boundsAR = bounds.width / bounds.height
        let imgAR    = imgSize.width / imgSize.height
        let drawRect: NSRect
        if imgAR > boundsAR {
            let h = bounds.width / imgAR
            drawRect = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * imgAR
            drawRect = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let cx = drawRect.midX
        let cy = drawRect.midY
        ctx.translateBy(x: cx, y: cy)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -cx, y: -cy)
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        ctx.restoreGState()
    }
}

// MARK: - Native loupe overlay NSView

/// A transparent NSView that sits as a direct sibling of the NSScrollView inside
/// the NSViewRepresentable's host view. It captures right-click events across the
/// entire scroll area — including cross-page drags — without interfering with the
/// scroll view's native scroll/pan handling.
final class VerticalLoupeOverlayView: NSView {
    var onLoupeUpdate: ((NSImage, CGPoint, CGSize, CGPoint) -> Void)?
    var onLoupeEnd: (() -> Void)?

    weak var scrollView: NSScrollView?

    /// Page data for hit-testing: (pageView, image) pairs.
    /// Image may be nil if not yet decoded — in that case loupe is skipped.
    var pageData: [(view: NSView, image: NSImage?)] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        NSCursor.hide()
        postLoupe(event: event)
    }
    override func mouseDragged(with event: NSEvent) {
        postLoupe(event: event)
    }
    override func mouseUp(with event: NSEvent) {
        NSCursor.unhide()
        onLoupeEnd?()
    }

    private func postLoupe(event: NSEvent) {
        guard let sv = scrollView else { return }

        let overlayPt = convert(event.locationInWindow, from: nil)
        let scrollOffset = sv.contentView.bounds.origin
        let docPt = NSPoint(x: overlayPt.x + scrollOffset.x,
                            y: overlayPt.y + scrollOffset.y)

        guard let (pageView, image) = hitTestPage(docPt: docPt, in: sv),
              let img = image else { return }

        let pageFrameInDoc = pageView.convert(pageView.bounds, to: sv.documentView)
        let localX = docPt.x - pageFrameInDoc.minX
        let localY = docPt.y - pageFrameInDoc.minY

        let imgSize = img.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let pageW = pageFrameInDoc.width
        let pageH = pageFrameInDoc.height
        let imgAR = imgSize.width / imgSize.height
        let conAR = pageW / pageH
        let ivSize: CGSize = imgAR > conAR
            ? CGSize(width: pageW, height: pageW / imgAR)
            : CGSize(width: pageH * imgAR, height: pageH)
        let ox = (pageW - ivSize.width)  / 2
        let oy = (pageH - ivSize.height) / 2
        let cursorInIV = CGPoint(x: localX - ox, y: localY - oy)

        onLoupeUpdate?(img, cursorInIV, ivSize, overlayPt)
    }

    private func hitTestPage(docPt: NSPoint, in sv: NSScrollView) -> (NSView, NSImage?)? {
        for (pageView, image) in pageData {
            let frameInDoc = pageView.convert(pageView.bounds, to: sv.documentView)
            if frameInDoc.contains(docPt) { return (pageView, image) }
        }
        return nil
    }
}

// MARK: - NSViewRepresentable

struct VerticalComicScrollView: NSViewRepresentable {
    let pages: [ComicPage]
    let pagesPerRow: Int
    let scale: CGFloat
    let containerWidth: CGFloat
    let restoreOffset: Double?
    /// Page index to restore to — preferred over restoreOffset when switching between
    /// vertical modes where fractional offsets are layout-dependent and inaccurate.
    let restorePage: Int?
    /// Cache reference — used to pull decoded images during layout builds.
    weak var imageCache: PageImageCache?
    var onPageChanged: (Int) -> Void
    var onOffsetChanged: (Double) -> Void
    var onMagnificationChanged: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged, onOffsetChanged: onOffsetChanged)
    }

    /// Wires the cache's onPageReady callback to the coordinator's O(1) injection.
    /// Called once after makeNSView and again after every full rebuild.
    private func wireCache(context: Context) {
        guard let cache = imageCache else { return }
        let coordinator = context.coordinator
        cache.onPageReady = { [weak coordinator] pageIndex, image in
            coordinator?.injectImage(image, for: pageIndex)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        // Enable native pinch-to-zoom via NSScrollView magnification.
        // Pages are built at scale=1 and NSScrollView handles all zoom rendering.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.magnification = scale

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.stackView = stack
        scrollView.documentView = stack

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
        // Observe NSScrollView magnification changes (trackpad pinch).
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        context.coordinator.scrollView = scrollView
        context.coordinator.pages = pages
        context.coordinator.imageCache = imageCache

        // Wire onPageReady BEFORE buildPages so no decode completions are missed.
        wireCache(context: context)
        buildPages(stack: stack, scrollView: scrollView, context: context)
        print("[DEBUG] makeNSView: restorePage=\(String(describing: restorePage)), restoreOffset=\(String(describing: restoreOffset))")
        Task { await DCLogger.shared.log("makeNSView: restorePage=\(String(describing: restorePage)), restoreOffset=\(String(describing: restoreOffset))") }

        // Restore by page number (preferred) or by scroll fraction.
        if let page = restorePage, page >= 0 {
            context.coordinator.pendingRestorePage = page
            print("[DEBUG] makeNSView: scheduling page restore to page \(page)")
            Task { await DCLogger.shared.log("makeNSView: scheduling page restore to page \(page)") }
            // Capture page in the closure so updateNSView can't wipe it before applyPendingRestore runs.
            let capturedPage = page
            DispatchQueue.main.async { context.coordinator.pendingRestorePage = capturedPage; context.coordinator.applyPendingRestore() }
        } else if let fraction = restoreOffset, fraction > 0 {
            context.coordinator.pendingRestoreOffset = fraction
            print("[DEBUG] makeNSView: scheduling fraction restore to \(fraction)")
            Task { await DCLogger.shared.log("makeNSView: scheduling fraction restore to \(fraction)") }
            let capturedFraction = fraction
            DispatchQueue.main.async { context.coordinator.pendingRestoreOffset = capturedFraction; context.coordinator.applyPendingRestore() }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let stack = context.coordinator.stackView else { return }

        // Full rebuild only when the column layout changes.
        let needsRebuild = abs(context.coordinator.lastContainerWidth - containerWidth) > 1
            || context.coordinator.lastPagesPerRow != pagesPerRow
        Task { await DCLogger.shared.log("updateNSView: needsRebuild=\(needsRebuild) (containerW: \(context.coordinator.lastContainerWidth)->\(containerWidth), pagesPerRow: \(context.coordinator.lastPagesPerRow)->\(pagesPerRow))") }

        if needsRebuild {
            // Capture current scroll fraction before tearing down the layout.
            let priorFraction: Double
            let docH0 = scrollView.documentView?.bounds.height ?? 0
            let visH0 = scrollView.contentView.bounds.height
            let maxOff0 = docH0 - visH0
            if maxOff0 > 0 {
                priorFraction = Double(scrollView.contentView.bounds.origin.y / maxOff0).clamped(to: 0...1)
            } else {
                priorFraction = 0
            }
            context.coordinator.lastContainerWidth = containerWidth
            context.coordinator.lastPagesPerRow = pagesPerRow
            context.coordinator.lastScale = scale
            context.coordinator.pages = pages
            context.coordinator.imageCache = imageCache
            // Update pending offset so the async restore uses the correct saved offset for this mode.
            // Also reset hasRestoredOnce so the async restore fires even after a prior restore.
            context.coordinator.pendingRestoreOffset = restoreOffset
            context.coordinator.pendingRestorePage = nil
            context.coordinator.hasRestoredOnce = false
            wireCache(context: context)
            buildPages(stack: stack, scrollView: scrollView, context: context)
            // Restore scroll position after rebuild.
            let docH1 = scrollView.documentView?.bounds.height ?? 0
            let visH1 = scrollView.contentView.bounds.height
            let maxOff1 = docH1 - visH1
            if maxOff1 > 0 {
                let targetY = CGFloat(priorFraction) * maxOff1
                scrollView.documentView?.scroll(CGPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            // Prefetch visible pages after rebuild so images load without requiring a manual scroll.
            context.coordinator.prefetchVisibleRange()
            let logMsg = "UPDATE rebuild complete, pagesPerRow=\(pagesPerRow), priorFraction=\(priorFraction), pendingRestoreOffset=\(String(describing: restoreOffset)), pendingRestorePage=\(String(describing: context.coordinator.pendingRestorePage))"
            Task { await DCLogger.shared.log(logMsg) }
            return
        }

        // Scale-only change: sync to NSScrollView magnification. NSScrollView
        // handles rendering natively so no constraint rebuild is needed.
        if abs(context.coordinator.lastScale - scale) > 0.001 {
            context.coordinator.lastScale = scale
            scrollView.magnification = scale
        }

        // Sync any images that arrived before the cache callback was wired (e.g. on restore).
        syncInitialImages(context: context)

        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
        context.coordinator.onMagnificationChanged = onMagnificationChanged

        if let overlay = context.coordinator.loupeOverlay {
            overlay.frame = scrollView.bounds
            // Keep loupe page data current with latest decoded images.
            overlay.pageData = context.coordinator.pageConstraints.map {
                ($0.view, imageCache?.image(for: $0.pageIndex))
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        nil
    }

    // MARK: - Loupe overlay setup

    private func addLoupeOverlay(to scrollView: NSScrollView, context: Context) {
        guard context.coordinator.loupeOverlay == nil else { return }
        let overlay = VerticalLoupeOverlayView()
        overlay.frame = scrollView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.scrollView = scrollView
        overlay.pageData = context.coordinator.pageConstraints.map {
            ($0.view, imageCache?.image(for: $0.pageIndex))
        }

        let coordinator = context.coordinator
        overlay.onLoupeUpdate = { [weak coordinator] image, cursorInIV, ivSize, pos in
            coordinator?.showLoupe(image: image, cursorInIV: cursorInIV, ivSize: ivSize, pos: pos)
        }
        overlay.onLoupeEnd = { [weak coordinator] in
            coordinator?.hideLoupe()
        }

        scrollView.superview?.addSubview(overlay)
        context.coordinator.loupeOverlay = overlay
    }

    // MARK: - Full page build (called only on layout changes)

     private func buildPages(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        context.coordinator.pageViews.removeAll()
        context.coordinator.pageConstraints.removeAll()
        let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth
        if pagesPerRow == 1 {
            for page in pages {
                let cachedImage = imageCache?.image(for: page.id)
                let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                let (v, wc, hc) = makePageView(
                    image: cachedImage,
                    naturalAR: ar,
                    width: totalWidth
                )
                stack.addArrangedSubview(v)
                context.coordinator.pageViews.append((pageIndex: page.id, view: v))
                context.coordinator.pageConstraints.append(
                    PageConstraints(view: v, pageIndex: page.id, naturalAR: ar,
                                    widthConstraint: wc, heightConstraint: hc, rowConstraint: nil, isSpread: false)
                )
            }
        } else {
            let pageWidth = (totalWidth - 2) / 2
            var i = 0
            while i < pages.count {
                let leftPage = pages[i]
                let leftAR = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
                let leftImage = imageCache?.image(for: leftPage.id)

                if leftPage.isSpread {
                    // Double-scan spread: render full-width in its own row, consume only this page.
                    let row = FlippedStackView()
                    row.orientation = .horizontal
                    row.spacing = 0
                    row.alignment = .top
                    row.translatesAutoresizingMaskIntoConstraints = false

                    let (spreadV, spreadWC, spreadHC) = makePageView(
                        image: leftImage, naturalAR: leftAR, width: totalWidth, heightScale: scale
                    )
                    row.addArrangedSubview(spreadV)
                    context.coordinator.pageViews.append((pageIndex: leftPage.id, view: spreadV))

                    let rowWC = row.widthAnchor.constraint(equalToConstant: totalWidth)
                    rowWC.isActive = true

                    context.coordinator.pageConstraints.append(
                        PageConstraints(view: spreadV, pageIndex: leftPage.id, naturalAR: leftAR,
                                        widthConstraint: spreadWC, heightConstraint: spreadHC,
                                        rowConstraint: rowWC, isSpread: true)
                    )
                    stack.addArrangedSubview(row)
                    i += 1  // spread occupies one page slot
                } else {
                    // Normal pair row.
                    let row = FlippedStackView()
                    row.orientation = .horizontal
                    row.spacing = 2
                    row.alignment = .top
                    row.translatesAutoresizingMaskIntoConstraints = false

                    let (leftV, leftWC, leftHC) = makePageView(
                        image: leftImage, naturalAR: leftAR, width: pageWidth, heightScale: scale
                    )
                    row.addArrangedSubview(leftV)
                    context.coordinator.pageViews.append((pageIndex: leftPage.id, view: leftV))

                    let rowWC = row.widthAnchor.constraint(equalToConstant: totalWidth)
                    rowWC.isActive = true

                    context.coordinator.pageConstraints.append(
                        PageConstraints(view: leftV, pageIndex: leftPage.id, naturalAR: leftAR,
                                        widthConstraint: leftWC, heightConstraint: leftHC,
                                        rowConstraint: rowWC, isSpread: false)
                    )

                    // Right page — only if it exists and is not itself a spread.
                    if i + 1 < pages.count && !pages[i + 1].isSpread {
                        let rightPage = pages[i + 1]
                        let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                        let rightImage = imageCache?.image(for: rightPage.id)
                        let (rightV, rightWC, rightHC) = makePageView(
                            image: rightImage, naturalAR: rightAR, width: pageWidth, heightScale: scale
                        )
                        row.addArrangedSubview(rightV)
                        context.coordinator.pageConstraints.append(
                            PageConstraints(view: rightV, pageIndex: rightPage.id, naturalAR: rightAR,
                                            widthConstraint: rightWC, heightConstraint: rightHC,
                                            rowConstraint: nil, isSpread: false)
                        )
                        i += 2  // consumed both pages
                    } else {
                        i += 1  // right slot is a spread or end-of-comic — leave it for next iteration
                    }
                    stack.addArrangedSubview(row)
                }
            }
        }

        stack.constraints.filter { $0.firstAttribute == .width }.forEach { stack.removeConstraint($0) }
        let stackWC = stack.widthAnchor.constraint(equalToConstant: totalWidth)
        stackWC.isActive = true
        context.coordinator.stackWidthConstraint = stackWC

        scrollView.layoutSubtreeIfNeeded()

        // Build the O(1) page-view lookup dictionary and O(log n) Y-offset table.
        // In vertical double mode, each row contains two pages (left + right) at the
        // same Y position. We only advance Y when we encounter a left-page (one with
        // a rowConstraint), otherwise we'd double-count every row's height.
        context.coordinator.pageViewsByIndex.removeAll(keepingCapacity: true)
        var yOffsets: [CGFloat] = []
        yOffsets.reserveCapacity(pages.count)
        var y: CGFloat = 0
        for pc in context.coordinator.pageConstraints {
            guard let v = pc.view as? ComicPageView else { continue }
            context.coordinator.pageViewsByIndex[pc.pageIndex] = v
            yOffsets.append(y)
            // Only advance Y for left-pages (rowConstraint != nil) or single-column pages.
            // Right-pages share the same row Y — do not increment.
            if pagesPerRow == 1 || pc.rowConstraint != nil {
                y += pc.heightConstraint.constant + 4  // 4pt stack spacing
            }
        }
        context.coordinator.pageYOffsets = yOffsets

        // Correct heights for pages already in cache — cache hits won't fire onPageReady
        // so injectImage would never run for them. Same correction, applied once here.
        var anyHeightChanged = false
        for idx in context.coordinator.pageConstraints.indices {
            let pc = context.coordinator.pageConstraints[idx]
            guard let img = imageCache?.image(for: pc.pageIndex) else { continue }
            let imgAR = img.size.height / max(img.size.width, 1)
            let correctedH = pc.widthConstraint.constant * imgAR
            if abs(correctedH - pc.heightConstraint.constant) > 1 {
                context.coordinator.pageConstraints[idx].heightConstraint.constant = correctedH
                context.coordinator.pageConstraints[idx].naturalAR = imgAR
                anyHeightChanged = true
            }
        }
        if anyHeightChanged {
            context.coordinator.rebuildYOffsets()
            scrollView.layoutSubtreeIfNeeded()
        }

        context.coordinator.loupeOverlay?.pageData = context.coordinator.pageConstraints.map {
            ($0.view, imageCache?.image(for: $0.pageIndex))
        }

        DispatchQueue.main.async { self.addLoupeOverlay(to: scrollView, context: context) }
    }

    // MARK: - One-time sync on layout build (not on every cache update)

    /// Pushes any images already in the cache into their page views.
    /// Called only during layout builds and on the first updateNSView after open.
    /// Ongoing updates are handled by the O(1) onPageReady callback.
    /// Note: the v.image == nil guard has been intentionally removed so that stale
    /// images are always replaced when the cache has a fresher copy.
    private func syncInitialImages(context: Context) {
        guard let cache = imageCache else { return }
        var updated = 0
        var anyHeightChanged = false
        for idx in context.coordinator.pageConstraints.indices {
            let pc = context.coordinator.pageConstraints[idx]
            guard let v = pc.view as? ComicPageView else { continue }
            guard let img = cache.image(for: pc.pageIndex) else { continue }
            v.image = img
            updated += 1
            // Apply the same AR correction as injectImage — SYNC is the path that runs
            // after spurious rebuilds where injectImage won't fire again (cache hit).
            let imgAR = img.size.height / max(img.size.width, 1)
            let correctedH = pc.widthConstraint.constant * imgAR
            if abs(correctedH - pc.heightConstraint.constant) > 1 {
                context.coordinator.pageConstraints[idx].heightConstraint.constant = correctedH
                context.coordinator.pageConstraints[idx].naturalAR = imgAR
                anyHeightChanged = true
            }
        }
        if anyHeightChanged {
            context.coordinator.rebuildYOffsets()
        }
        if updated > 0 {
            Task { await DCLogger.shared.log("SYNC pushed \(updated) cached image(s) into page views on layout") }
        } else {
            Task { await DCLogger.shared.log("SYNC no cached images found during layout — page views will load via onPageReady") }
        }
    }

    // MARK: - In-place scale update (no view recreation)

    private func applyScale(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        if pagesPerRow == 1 {
            let totalWidth = containerWidth * scale
            for pc in context.coordinator.pageConstraints {
                pc.widthConstraint.constant  = totalWidth
                pc.heightConstraint.constant = max(totalWidth * pc.naturalAR, 1)
            }
            context.coordinator.stackWidthConstraint?.constant = totalWidth
        } else {
            let pageWidth = (containerWidth - 2) / 2
            for pc in context.coordinator.pageConstraints {
                // Spread pages use full container width; normal pages use half width.
                let w = pc.isSpread ? containerWidth : pageWidth
                pc.widthConstraint.constant  = w
                pc.heightConstraint.constant = max(w * pc.naturalAR * scale, 1)
                pc.rowConstraint?.constant   = containerWidth
            }
        }
        scrollView.layoutSubtreeIfNeeded()
    }

    // MARK: - Factory

    private func makePageView(image: NSImage?, naturalAR: CGFloat, width: CGFloat, heightScale: CGFloat = 1.0) -> (ComicPageView, NSLayoutConstraint, NSLayoutConstraint) {
        let v = ComicPageView()
        v.image = image
        v.naturalAR = naturalAR
        v.translatesAutoresizingMaskIntoConstraints = false
        let h = max(width * naturalAR * heightScale, 1)
        let wc = v.widthAnchor.constraint(equalToConstant: width)
        let hc = v.heightAnchor.constraint(equalToConstant: h)
        wc.isActive = true
        hc.isActive = true
        return (v, wc, hc)
    }

    // MARK: - Coordinator

    struct PageConstraints {
        let view: NSView
        let pageIndex: Int
        var naturalAR: CGFloat
        let widthConstraint: NSLayoutConstraint
        let heightConstraint: NSLayoutConstraint
        let rowConstraint: NSLayoutConstraint?
        /// True when this page is a double-scan spread occupying a full-width row.
        let isSpread: Bool
    }

    final class Coordinator: NSObject {
        var scrollView: NSScrollView?
        var stackView: NSStackView?
        var pageViews: [(pageIndex: Int, view: NSView)] = []
        var pageConstraints: [PageConstraints] = []
        var stackWidthConstraint: NSLayoutConstraint?
        var lastScale: CGFloat = 0
        var lastContainerWidth: CGFloat = 0
        var lastPagesPerRow: Int = 0
        var pendingRestoreOffset: Double? = nil
        var pendingRestorePage: Int? = nil
        var hasRestoredOnce = false

        /// Kept in sync with the SwiftUI struct so scrollDidChange can call viewport prefetch.
        var pages: [ComicPage] = []
        weak var imageCache: PageImageCache?

        /// O(1) lookup: page index → its ComicPageView. Rebuilt on every layout change.
        var pageViewsByIndex: [Int: ComicPageView] = [:]

        /// Sorted cumulative Y-offsets for each page (in page-constraint order).
        /// Used for O(log n) binary search in scrollDidChange.
        var pageYOffsets: [CGFloat] = []

        var onPageChanged: (Int) -> Void
        var onOffsetChanged: (Double) -> Void
        var onMagnificationChanged: ((CGFloat) -> Void)?

        var loupeOverlay: VerticalLoupeOverlayView?
        var loupeHostingView: NSHostingView<AnyView>?

        init(onPageChanged: @escaping (Int) -> Void, onOffsetChanged: @escaping (Double) -> Void) {
            self.onPageChanged = onPageChanged
            self.onOffsetChanged = onOffsetChanged
        }

        /// Recomputes the cumulative Y-offset table from current constraint heights.
        /// Must be called whenever any heightConstraint.constant changes so that
        /// scroll-position tracking and viewport-prefetch stay accurate.
        func rebuildYOffsets() {
            var offsets: [CGFloat] = []
            offsets.reserveCapacity(pageConstraints.count)
            var y: CGFloat = 0
            for pc in pageConstraints {
                offsets.append(y)
                if lastPagesPerRow == 1 || pc.rowConstraint != nil {
                    y += pc.heightConstraint.constant + 4
                }
            }
            pageYOffsets = offsets
        }
        /// O(1) image injection — called by the cache's onPageReady callback.
        /// Looks up the NSView directly and sets its image without any loop or SwiftUI re-render.
        func injectImage(_ image: NSImage, for pageIndex: Int) {
            pageViewsByIndex[pageIndex]?.image = image
            // Correct the height constraint to match the decoded image's actual AR.
            // naturalSize from metadata may differ slightly from the real decoded dimensions
            // (e.g. WebP pages with variable heights). This eliminates letterbox artefacts.
            if let idx = pageConstraints.firstIndex(where: { $0.pageIndex == pageIndex }) {
                let imgAR = image.size.height / max(image.size.width, 1)
                let correctedH = pageConstraints[idx].widthConstraint.constant * imgAR
                if abs(correctedH - pageConstraints[idx].heightConstraint.constant) > 1 {
                    pageConstraints[idx].heightConstraint.constant = correctedH
                    // Persist the real AR so applyScale() never reverts to the metadata value.
                    pageConstraints[idx].naturalAR = imgAR
                    stackView?.layoutSubtreeIfNeeded()
                    // Keep the Y-offset table consistent with the corrected height.
                    rebuildYOffsets()
                }
            }
            // Keep loupe data current.
            if let overlay = loupeOverlay {
                for i in 0..<overlay.pageData.count {
                    if overlay.pageData[i].view === pageViewsByIndex[pageIndex] {
                        overlay.pageData[i] = (overlay.pageData[i].view, image)
                        break
                    }
                }
            }
            Task { await DCLogger.shared.log("INJECT page \(pageIndex) — image set directly on NSView") }
        }

        func showLoupe(image: NSImage, cursorInIV: CGPoint, ivSize: CGSize, pos: CGPoint) {
            let loupeView = MagnifierView(image: image, cursorInImageView: cursorInIV, imageViewSize: ivSize)
            let radius: CGFloat = 270
            let frame = NSRect(x: pos.x - radius, y: pos.y - radius, width: radius * 2, height: radius * 2)

            if let hv = loupeHostingView {
                hv.rootView = AnyView(loupeView)
                hv.frame = frame
            } else if let overlay = loupeOverlay {
                let hv = NSHostingView(rootView: AnyView(loupeView))
                hv.frame = frame
                overlay.addSubview(hv)
                loupeHostingView = hv
            }
        }

        func hideLoupe() {
            loupeHostingView?.removeFromSuperview()
            loupeHostingView = nil
        }

        func applyPendingRestore() {
            guard hasRestoredOnce == false else { return }
            // Capture pending values immediately so they can't be wiped by a concurrent
            // updateNSView before we use them.
            let pendingPage = pendingRestorePage
            let pendingOffset = pendingRestoreOffset
            pendingRestorePage = nil
            pendingRestoreOffset = nil
            guard let sv = scrollView,
                  let doc = sv.documentView else { return }
            let docH = doc.bounds.height
            let visH = sv.contentView.bounds.height
            let maxOffset = docH - visH
            guard maxOffset > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.applyPendingRestore()
                }
                return
            }

            if let page = pendingPage, page >= 0 {
                // Restore by page index — use the binary-search Y-offset table.
                let offsets = pageYOffsets
                print("[DEBUG] applyPendingRestore: page=\(page), offsets.count=\(offsets.count)")
                guard page < offsets.count else {
                    hasRestoredOnce = true
                    pendingRestorePage = nil
                print("[DEBUG] applyPendingRestore: page out of bounds, skipping")
                Task { await DCLogger.shared.log("applyPendingRestore: page out of bounds (page=\(page), offsets.count=\(offsets.count))") }
                return
                }
                let targetY = offsets[page]
                doc.scroll(CGPoint(x: 0, y: targetY))
                sv.reflectScrolledClipView(sv.contentView)
                hasRestoredOnce = true
                pendingRestorePage = nil
                prefetchVisibleRange()
                print("[DEBUG] RESTORE applying saved page=\(page) (Y=\(Int(targetY)))")
                Task { await DCLogger.shared.log("RESTORE applying saved page=\(page) (fraction=0.\(Int(targetY / maxOffset * 1000)))") }
            } else if let fraction = pendingOffset {
                let targetY = CGFloat(fraction) * maxOffset
                doc.scroll(CGPoint(x: 0, y: targetY))
                sv.reflectScrolledClipView(sv.contentView)
                hasRestoredOnce = true
                pendingRestoreOffset = nil
                prefetchVisibleRange()
                print("[DEBUG] RESTORE applying saved offset=\(fraction) (Y=\(Int(targetY)))")
                Task { await DCLogger.shared.log("RESTORE applying saved offset=\(fraction) (Y=\(Int(targetY)))") }
            } else {
                print("[DEBUG] applyPendingRestore: nothing to restore (both pendingRestorePage and pendingRestoreOffset are nil)")
                Task { await DCLogger.shared.log("applyPendingRestore: nothing to restore (pendingRestorePage=\(String(describing: pendingRestorePage)), pendingRestoreOffset=\(String(describing: pendingRestoreOffset)))") }
            }
        }

        /// O(log n) prefetch trigger — called both on scroll and on restore.
        func prefetchVisibleRange() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let docH = doc.bounds.height
            let visH = sv.contentView.bounds.height
            let maxOffset = docH - visH
            guard maxOffset > 0 else { return }

            let currentY = sv.contentView.bounds.origin.y
            let fraction = Double(currentY / maxOffset).clamped(to: 0...1)
            onOffsetChanged(fraction)
            let offsets = pageYOffsets
            guard !offsets.isEmpty else { return }

            var lo = 0, hi = offsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if offsets[mid] <= currentY { lo = mid } else { hi = mid - 1 }
            }
            let firstVisible = lo

            let bottomY = currentY + visH
            var lo2 = firstVisible, hi2 = offsets.count - 1
            while lo2 < hi2 {
                let mid = (lo2 + hi2 + 1) / 2
                if offsets[mid] < bottomY { lo2 = mid } else { hi2 = mid - 1 }
            }
            let lastVisible = lo2

            let bestPage = pageConstraints.indices.contains(firstVisible)
                ? pageConstraints[firstVisible].pageIndex : 0
            onPageChanged(bestPage)

            if !pages.isEmpty, let cache = imageCache {
                let firstIdx = pageConstraints.indices.contains(firstVisible)
                    ? pageConstraints[firstVisible].pageIndex : 0
                let lastIdx  = pageConstraints.indices.contains(lastVisible)
                    ? pageConstraints[lastVisible].pageIndex : firstIdx
                let visibleRange = min(firstIdx, lastIdx)...max(firstIdx, lastIdx)
                cache.prefetch(visible: visibleRange, lookahead: 3, pages: pages)
            }
        }

        @objc func scrollDidChange(_ notification: Notification) {
            prefetchVisibleRange()
            Task { await DCLogger.shared.log("scrollDidChange: prefetchVisibleRange called") }
        }

        /// Called when the user pinch-zooms via NSScrollView's native magnification.
        /// Pushes the new magnification back to ReaderViewModel so the toolbar UI
        /// stays in sync. We intentionally do NOT call applyPendingRestore here —
        /// scroll position is already correct, and re-applying restore would jump
        /// the scroll position after a pinch gesture.
        @objc func magnificationDidChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            onMagnificationChanged?(sv.magnification)
        }
    }
}

