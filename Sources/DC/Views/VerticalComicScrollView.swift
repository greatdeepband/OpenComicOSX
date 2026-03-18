import AppKit
import SwiftUI

/// Custom NSView that draws an NSImage scaled to fill its bounds exactly (aspect-fit).
private final class ComicPageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = image else { return }
        NSColor.black.setFill()
        dirtyRect.fill()
        // Scale to fill bounds while preserving aspect ratio (aspect-fit).
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let boundsAR = bounds.width / bounds.height
        let imgAR    = imgSize.width / imgSize.height
        let drawRect: NSRect
        if imgAR > boundsAR {
            // Image wider than bounds — fit width, letterbox top/bottom.
            let h = bounds.width / imgAR
            drawRect = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            // Image taller than bounds — fit height, pillarbox left/right.
            let w = bounds.height * imgAR
            drawRect = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
    }
}

/// NSViewRepresentable wrapping NSScrollView for vertical reading modes.
/// Replaces SwiftUI ScrollView+LazyVStack to enable:
/// - Exact pixel-position restore via NSScrollView.documentView.scroll(_:)
/// - Reliable scroll offset tracking via NSScrollView notifications
/// - Correct image scaling regardless of natural image size
struct VerticalComicScrollView: NSViewRepresentable {
    let pages: [ComicPage]
    let pagesPerRow: Int
    let scale: CGFloat
    let containerWidth: CGFloat
    /// Fractional offset (0–1) to restore on first appearance. Nil = start at top.
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

        let stack = NSStackView()
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

        // Constrain stack width so the scroll view doesn't expand horizontally.
        // Remove old width constraints first.
        stack.constraints.filter { $0.firstAttribute == .width }.forEach { stack.removeConstraint($0) }
        stack.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true

        scrollView.layoutSubtreeIfNeeded()
    }

    /// Creates a ComicPageView sized to `width` × proportional height.
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
            dcLog("[DC] NSSCROLL restore: fraction=\(fraction) docH=\(docH) visH=\(visH) maxOffset=\(maxOffset) targetY=\(targetY)")
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

            // Find the page view whose top edge is closest to the current scroll position.
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
