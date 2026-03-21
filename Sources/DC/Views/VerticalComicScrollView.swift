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

private final class ComicPageView: NSView {
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

    override func rightMouseDown(with event: NSEvent) {
        NSCursor.hide()
        postLoupe(event: event)
    }
    override func rightMouseDragged(with event: NSEvent) {
        postLoupe(event: event)
    }
    override func rightMouseUp(with event: NSEvent) {
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
    /// Cache reference — used to pull decoded images and update page views when images arrive.
    weak var imageCache: PageImageCache?
    /// Incremented by ReaderViewModel each time a new page is decoded into the cache.
    /// Causes SwiftUI to call updateNSView, which calls refreshImages().
    let cacheVersion: Int
    var onPageChanged: (Int) -> Void
    var onOffsetChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged, onOffsetChanged: onOffsetChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

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

        context.coordinator.scrollView = scrollView
        buildPages(stack: stack, scrollView: scrollView, context: context)

        if let fraction = restoreOffset, fraction > 0 {
            context.coordinator.pendingRestoreOffset = fraction
            DispatchQueue.main.async { context.coordinator.applyPendingRestore() }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let stack = context.coordinator.stackView else { return }

        // Full rebuild only when the column layout changes.
        let needsRebuild = context.coordinator.lastContainerWidth != containerWidth
            || context.coordinator.lastPagesPerRow != pagesPerRow

        if needsRebuild {
            context.coordinator.lastContainerWidth = containerWidth
            context.coordinator.lastPagesPerRow = pagesPerRow
            context.coordinator.lastScale = scale
            buildPages(stack: stack, scrollView: scrollView, context: context)
            return
        }

        // Scale-only change: update constraints in place.
        if context.coordinator.lastScale != scale {
            context.coordinator.lastScale = scale
            applyScale(stack: stack, scrollView: scrollView, context: context)
        }

        // Push any newly decoded images into their page views.
        refreshImages(context: context)

        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged

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
                                    widthConstraint: wc, heightConstraint: hc, rowConstraint: nil)
                )
            }
        } else {
            let pageWidth = (totalWidth - 2) / 2
            for i in stride(from: 0, to: pages.count, by: 2) {
                let row = FlippedStackView()
                row.orientation = .horizontal
                row.spacing = 2
                row.alignment = .top
                row.translatesAutoresizingMaskIntoConstraints = false

                let leftPage = pages[i]
                let leftAR = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
                let leftImage = imageCache?.image(for: leftPage.id)
                let (leftV, leftWC, leftHC) = makePageView(
                    image: leftImage, naturalAR: leftAR, width: pageWidth, heightScale: scale
                )
                row.addArrangedSubview(leftV)
                context.coordinator.pageViews.append((pageIndex: leftPage.id, view: leftV))

                let rowWC = row.widthAnchor.constraint(equalToConstant: totalWidth)
                rowWC.isActive = true

                context.coordinator.pageConstraints.append(
                    PageConstraints(view: leftV, pageIndex: leftPage.id, naturalAR: leftAR,
                                    widthConstraint: leftWC, heightConstraint: leftHC, rowConstraint: rowWC)
                )

                if i + 1 < pages.count {
                    let rightPage = pages[i + 1]
                    let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                    let rightImage = imageCache?.image(for: rightPage.id)
                    let (rightV, rightWC, rightHC) = makePageView(
                        image: rightImage, naturalAR: rightAR, width: pageWidth, heightScale: scale
                    )
                    row.addArrangedSubview(rightV)
                    context.coordinator.pageConstraints.append(
                        PageConstraints(view: rightV, pageIndex: rightPage.id, naturalAR: rightAR,
                                        widthConstraint: rightWC, heightConstraint: rightHC, rowConstraint: nil)
                    )
                }

                stack.addArrangedSubview(row)
            }
        }

        stack.constraints.filter { $0.firstAttribute == .width }.forEach { stack.removeConstraint($0) }
        let stackWC = stack.widthAnchor.constraint(equalToConstant: totalWidth)
        stackWC.isActive = true
        context.coordinator.stackWidthConstraint = stackWC

        scrollView.layoutSubtreeIfNeeded()

        context.coordinator.loupeOverlay?.pageData = context.coordinator.pageConstraints.map {
            ($0.view, imageCache?.image(for: $0.pageIndex))
        }

        DispatchQueue.main.async { self.addLoupeOverlay(to: scrollView, context: context) }
    }

    // MARK: - Push decoded images into existing page views (no rebuild)

    private func refreshImages(context: Context) {
        guard let cache = imageCache else { return }
        var updated = 0
        var stillMissing: [Int] = []
        for pc in context.coordinator.pageConstraints {
            guard let v = pc.view as? ComicPageView else { continue }
            if v.image == nil {
                if let img = cache.image(for: pc.pageIndex) {
                    v.image = img
                    updated += 1
                } else {
                    stillMissing.append(pc.pageIndex)
                }
            }
        }
        if updated > 0 {
            DCLogger.shared.log("REFRESH pushed \(updated) image(s) into page views")
        }
        if !stillMissing.isEmpty {
            DCLogger.shared.log("REFRESH still nil pages: \(stillMissing)")
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
                let naturalH = pageWidth * pc.naturalAR
                pc.heightConstraint.constant = max(naturalH * scale, 1)
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
        let naturalAR: CGFloat
        let widthConstraint: NSLayoutConstraint
        let heightConstraint: NSLayoutConstraint
        let rowConstraint: NSLayoutConstraint?
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
        var hasRestoredOnce = false

        var onPageChanged: (Int) -> Void
        var onOffsetChanged: (Double) -> Void

        var loupeOverlay: VerticalLoupeOverlayView?
        var loupeHostingView: NSHostingView<AnyView>?

        init(onPageChanged: @escaping (Int) -> Void, onOffsetChanged: @escaping (Double) -> Void) {
            self.onPageChanged = onPageChanged
            self.onOffsetChanged = onOffsetChanged
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
            guard !hasRestoredOnce,
                  let fraction = pendingRestoreOffset,
                  let sv = scrollView,
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
            let targetY = CGFloat(fraction) * maxOffset
            doc.scroll(CGPoint(x: 0, y: targetY))
            sv.reflectScrolledClipView(sv.contentView)
            hasRestoredOnce = true
            pendingRestoreOffset = nil
        }

        @objc func scrollDidChange(_ notification: Notification) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let docH = doc.bounds.height
            let visH = sv.contentView.bounds.height
            let maxOffset = docH - visH
            guard maxOffset > 0 else { return }
            let currentY = sv.contentView.bounds.origin.y
            let fraction = Double(currentY / maxOffset).clamped(to: 0...1)
            onOffsetChanged(fraction)

            var bestPage = 0
            var bestDist = CGFloat.greatestFiniteMagnitude
            for entry in pageViews {
                let frameInDoc = entry.view.convert(entry.view.bounds, to: doc)
                let dist = abs(frameInDoc.minY - currentY)
                if dist < bestDist {
                    bestDist = dist
                    bestPage = entry.pageIndex
                }
            }
            onPageChanged(bestPage)
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
