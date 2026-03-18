import AppKit
import SwiftUI

// MARK: - Flipped NSStackView (top-left origin, like UIKit)

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - Loupe notification

struct LoupeInfo {
    let image: NSImage
    let cursorInImageView: CGPoint
    let imageViewSize: CGSize
    /// Cursor position in window coordinates (AppKit, bottom-left origin).
    let positionInWindow: CGPoint
}

extension Notification.Name {
    static let loupeBegan  = Notification.Name("VerticalLoupeBegan")
    static let loupeMoved  = Notification.Name("VerticalLoupeMoved")
    static let loupeEnded  = Notification.Name("VerticalLoupeEnded")
}

// MARK: - Page drawing view

private final class ComicPageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    // MARK: Right-click loupe

    override func rightMouseDown(with event: NSEvent) {
        NSCursor.hide()
        postLoupe(event: event, name: .loupeBegan)
    }
    override func rightMouseDragged(with event: NSEvent) {
        postLoupe(event: event, name: .loupeMoved)
    }
    override func rightMouseUp(with event: NSEvent) {
        NSCursor.unhide()
        NotificationCenter.default.post(name: .loupeEnded, object: nil)
    }

    private func postLoupe(event: NSEvent, name: Notification.Name) {
        guard let image = image else { return }
        // Cursor in this view's flipped coordinate space.
        let localPt = convert(event.locationInWindow, from: nil)
        // Raw window coordinates (bottom-left origin) — SwiftUI overlay will convert.
        let windowPt = event.locationInWindow
        // Compute image-view size (aspect-fit within this view's bounds).
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let boundsAR = bounds.width / bounds.height
        let imgAR    = imgSize.width / imgSize.height
        let ivSize: CGSize
        if imgAR > boundsAR {
            ivSize = CGSize(width: bounds.width, height: bounds.width / imgAR)
        } else {
            ivSize = CGSize(width: bounds.height * imgAR, height: bounds.height)
        }
        let ox = (bounds.width  - ivSize.width)  / 2
        let oy = (bounds.height - ivSize.height) / 2
        let cursorInIV = CGPoint(x: localPt.x - ox, y: localPt.y - oy)
        let info = LoupeInfo(image: image,
                             cursorInImageView: cursorInIV,
                             imageViewSize: ivSize,
                             positionInWindow: windowPt)
        NotificationCenter.default.post(name: name, object: info)
    }

    // Must match the container — top-left origin.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = image else { return }
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        // Aspect-fit: scale image to fill bounds width, centre vertically.
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

        // When the view is flipped (isFlipped=true), NSGraphicsContext has a
        // vertical flip transform applied. NSImage.draw(in:) is not flip-aware,
        // so we must counter-rotate the context around the draw rect's centre.
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // Translate to the centre of the draw rect, flip, translate back.
        let cx = drawRect.midX
        let cy = drawRect.midY
        ctx.translateBy(x: cx, y: cy)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -cx, y: -cy)
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        ctx.restoreGState()
    }
}

// MARK: - NSViewRepresentable

struct VerticalComicScrollView: NSViewRepresentable {
    let pages: [ComicPage]
    let pagesPerRow: Int
    let scale: CGFloat
    let containerWidth: CGFloat
    let restoreOffset: Double?
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
        let needsRebuild = context.coordinator.lastScale != scale
            || context.coordinator.lastContainerWidth != containerWidth
            || context.coordinator.lastPagesPerRow != pagesPerRow

        if needsRebuild {
            context.coordinator.lastScale = scale
            context.coordinator.lastContainerWidth = containerWidth
            context.coordinator.lastPagesPerRow = pagesPerRow
            buildPages(stack: stack, scrollView: scrollView, context: context)
        }
    }

    private func buildPages(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        context.coordinator.pageViews.removeAll()

        let totalWidth = containerWidth * scale

        if pagesPerRow == 1 {
            for page in pages {
                let v = makePageView(image: page.image, width: totalWidth)
                stack.addArrangedSubview(v)
                context.coordinator.pageViews.append((pageIndex: page.id, view: v))
            }
        } else {
            let pageWidth = (totalWidth - 2) / 2
            for i in stride(from: 0, to: pages.count, by: 2) {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 2
                row.alignment = .top
                row.translatesAutoresizingMaskIntoConstraints = false

                let leftPage = pages[i]
                let leftV = makePageView(image: leftPage.image, width: pageWidth)
                row.addArrangedSubview(leftV)
                context.coordinator.pageViews.append((pageIndex: leftPage.id, view: leftV))

                if i + 1 < pages.count {
                    let rightPage = pages[i + 1]
                    let rightV = makePageView(image: rightPage.image, width: pageWidth)
                    row.addArrangedSubview(rightV)
                }

                row.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true
                stack.addArrangedSubview(row)
            }
        }

        // Remove old width constraints and add new one.
        stack.constraints.filter { $0.firstAttribute == .width }.forEach { stack.removeConstraint($0) }
        stack.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true

        scrollView.layoutSubtreeIfNeeded()
    }

    private func makePageView(image: NSImage, width: CGFloat) -> ComicPageView {
        let v = ComicPageView()
        v.image = image
        v.translatesAutoresizingMaskIntoConstraints = false
        let ar = image.size.height / max(image.size.width, 1)
        let h = max(width * ar, 1)
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var scrollView: NSScrollView?
        var stackView: NSStackView?
        var pageViews: [(pageIndex: Int, view: NSView)] = []
        var lastScale: CGFloat = 0
        var lastContainerWidth: CGFloat = 0
        var lastPagesPerRow: Int = 0
        var pendingRestoreOffset: Double? = nil
        var hasRestoredOnce = false

        var onPageChanged: (Int) -> Void
        var onOffsetChanged: (Double) -> Void

        init(onPageChanged: @escaping (Int) -> Void, onOffsetChanged: @escaping (Double) -> Void) {
            self.onPageChanged = onPageChanged
            self.onOffsetChanged = onOffsetChanged
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
