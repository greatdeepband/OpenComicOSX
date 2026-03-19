import AppKit
import SwiftUI

// MARK: - Flipped NSStackView (top-left origin, like UIKit)

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - Page drawing view
// Right-click loupe is no longer handled here — a single SwiftUI MouseCatcher
// overlay on the scroll view handles all right-click events in one coordinate space.

private final class ComicPageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = image else { return }
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

// MARK: - Loupe hit-test result

/// Returned by hitTestPage(at:) so the SwiftUI loupe overlay can position
/// MagnifierView correctly without any AppKit coordinate conversions.
struct PageHitResult {
    /// The image to magnify.
    let image: NSImage
    /// Cursor position relative to the rendered image rect inside the page view,
    /// in the page view's own coordinate space (top-left origin, already accounting
    /// for aspect-fit letterboxing).
    let cursorInImageView: CGPoint
    /// The rendered (aspect-fit) size of the image inside the page view.
    let imageViewSize: CGSize
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
    /// Called once after makeNSView so the parent view can hold a reference to the
    /// coordinator for hit-testing (loupe). The coordinator is stable for the lifetime
    /// of the view — it is safe to capture and reuse.
    var onCoordinatorReady: ((Coordinator) -> Void)? = nil

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

        // Notify the parent that the coordinator is ready for hit-testing.
        DispatchQueue.main.async { onCoordinatorReady?(context.coordinator) }

        if let fraction = restoreOffset, fraction > 0 {
            context.coordinator.pendingRestoreOffset = fraction
            DispatchQueue.main.async { context.coordinator.applyPendingRestore() }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let stack = context.coordinator.stackView else { return }

        let needsRebuild = context.coordinator.lastContainerWidth != containerWidth
            || context.coordinator.lastPagesPerRow != pagesPerRow

        if needsRebuild {
            context.coordinator.lastContainerWidth = containerWidth
            context.coordinator.lastPagesPerRow = pagesPerRow
            context.coordinator.lastScale = scale
            buildPages(stack: stack, scrollView: scrollView, context: context)
            return
        }

        if context.coordinator.lastScale != scale {
            context.coordinator.lastScale = scale
            applyScale(stack: stack, scrollView: scrollView, context: context)
        }

        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
    }

    // MARK: - Page hit test (called by SwiftUI loupe overlay)

    /// Given a cursor position in the scroll view's visible (clipped) coordinate space
    /// (top-left origin, matching SwiftUI), returns loupe parameters for the page under
    /// the cursor, or nil if no page is hit.
    ///
    /// This is the key function that makes Option 3 work: instead of each ComicPageView
    /// posting AppKit notifications with raw window coordinates, the SwiftUI MouseCatcher
    /// calls this once per drag event and gets back everything MagnifierView needs —
    /// all in a consistent coordinate space with no manual Y-flip.
    func hitTestPage(at pointInScrollView: CGPoint, coordinator: Coordinator) -> PageHitResult? {
        guard let sv = coordinator.scrollView,
              let doc = sv.documentView else { return nil }

        // Convert from scroll view's visible (clip) coords to document coords.
        // The clip view has top-left origin (flipped); the document view also has
        // top-left origin because FlippedStackView.isFlipped = true.
        let scrollOffset = sv.contentView.bounds.origin
        let pointInDoc = CGPoint(
            x: pointInScrollView.x + scrollOffset.x,
            y: pointInScrollView.y + scrollOffset.y
        )

        for pc in coordinator.pageConstraints {
            // Get the page view's frame in the document view's coordinate space.
            let frameInDoc = pc.view.convert(pc.view.bounds, to: doc)

            guard frameInDoc.contains(pointInDoc) else { continue }

            // Cursor relative to this page view's top-left corner.
            let localX = pointInDoc.x - frameInDoc.minX
            let localY = pointInDoc.y - frameInDoc.minY
            let pageSize = frameInDoc.size

            // Compute the aspect-fit rendered image rect within the page view.
            let imgSize = pc.image.size
            guard imgSize.width > 0, imgSize.height > 0 else { continue }
            let pageAR = pageSize.width / pageSize.height
            let imgAR  = imgSize.width  / imgSize.height
            let ivSize: CGSize = imgAR > pageAR
                ? CGSize(width: pageSize.width,  height: pageSize.width  / imgAR)
                : CGSize(width: pageSize.height * imgAR, height: pageSize.height)

            let ox = (pageSize.width  - ivSize.width)  / 2
            let oy = (pageSize.height - ivSize.height) / 2
            let cursorInIV = CGPoint(x: localX - ox, y: localY - oy)

            return PageHitResult(image: pc.image, cursorInImageView: cursorInIV, imageViewSize: ivSize)
        }
        return nil
    }

    // MARK: - Full page build

    private func buildPages(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        context.coordinator.pageViews.removeAll()
        context.coordinator.pageConstraints.removeAll()

        let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth

        if pagesPerRow == 1 {
            for page in pages {
                let (v, wc, hc) = makePageView(image: page.image, width: totalWidth)
                stack.addArrangedSubview(v)
                context.coordinator.pageViews.append((pageIndex: page.id, view: v))
                context.coordinator.pageConstraints.append(
                    PageConstraints(view: v, image: page.image, widthConstraint: wc, heightConstraint: hc, rowConstraint: nil)
                )
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
                let (leftV, leftWC, leftHC) = makePageView(image: leftPage.image, width: pageWidth, heightScale: scale)
                row.addArrangedSubview(leftV)
                context.coordinator.pageViews.append((pageIndex: leftPage.id, view: leftV))

                let rowWC = row.widthAnchor.constraint(equalToConstant: totalWidth)
                rowWC.isActive = true

                context.coordinator.pageConstraints.append(
                    PageConstraints(view: leftV, image: leftPage.image, widthConstraint: leftWC, heightConstraint: leftHC, rowConstraint: rowWC)
                )

                if i + 1 < pages.count {
                    let rightPage = pages[i + 1]
                    let (rightV, rightWC, rightHC) = makePageView(image: rightPage.image, width: pageWidth, heightScale: scale)
                    row.addArrangedSubview(rightV)
                    context.coordinator.pageConstraints.append(
                        PageConstraints(view: rightV, image: rightPage.image, widthConstraint: rightWC, heightConstraint: rightHC, rowConstraint: nil)
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
    }

    // MARK: - In-place scale update

    private func applyScale(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        if pagesPerRow == 1 {
            let totalWidth = containerWidth * scale
            for pc in context.coordinator.pageConstraints {
                let ar = pc.image.size.height / max(pc.image.size.width, 1)
                pc.widthConstraint.constant  = totalWidth
                pc.heightConstraint.constant = max(totalWidth * ar, 1)
            }
            context.coordinator.stackWidthConstraint?.constant = totalWidth
        } else {
            let totalWidth = containerWidth
            let pageWidth = (totalWidth - 2) / 2
            for pc in context.coordinator.pageConstraints {
                let naturalH = pageWidth * (pc.image.size.height / max(pc.image.size.width, 1))
                pc.heightConstraint.constant = max(naturalH * scale, 1)
            }
        }
        scrollView.layoutSubtreeIfNeeded()
    }

    // MARK: - Factory

    private func makePageView(image: NSImage, width: CGFloat, heightScale: CGFloat = 1.0) -> (ComicPageView, NSLayoutConstraint, NSLayoutConstraint) {
        let v = ComicPageView()
        v.image = image
        v.translatesAutoresizingMaskIntoConstraints = false
        let ar = image.size.height / max(image.size.width, 1)
        let h = max(width * ar * heightScale, 1)
        let wc = v.widthAnchor.constraint(equalToConstant: width)
        let hc = v.heightAnchor.constraint(equalToConstant: h)
        wc.isActive = true
        hc.isActive = true
        return (v, wc, hc)
    }

    // MARK: - Coordinator

    struct PageConstraints {
        let view: NSView
        let image: NSImage
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
