import AppKit
import SwiftUI

/// An NSViewRepresentable wrapping NSScrollView for the vertical reading modes.
/// Unlike SwiftUI ScrollView + LazyVStack, this allows:
/// - Exact pixel-position restore via NSScrollView.documentView.scroll(_:)
/// - Reliable scroll offset tracking via NSScrollView notifications
/// - No LazyVStack rendering limitations (all pages are laid out upfront)
struct VerticalComicScrollView: NSViewRepresentable {
    let pages: [ComicPage]
    let pagesPerRow: Int
    let scale: CGFloat
    let containerWidth: CGFloat
    /// Fractional offset (0–1) to restore on first appearance. Nil = start at top.
    let restoreOffset: Double?
    /// Called when the visible page changes.
    var onPageChanged: (Int) -> Void
    /// Called when the scroll offset fraction changes.
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

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.stackView = stack

        let clipView = scrollView.contentView
        clipView.drawsBackground = false

        scrollView.documentView = stack

        // Observe scroll position changes.
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
        context.coordinator.containerWidth = containerWidth
        context.coordinator.pagesPerRow = pagesPerRow

        buildPages(stack: stack, scrollView: scrollView, context: context)

        // Restore scroll position after layout.
        if let fraction = restoreOffset, fraction > 0 {
            context.coordinator.pendingRestoreOffset = fraction
            DispatchQueue.main.async {
                context.coordinator.applyPendingRestore()
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let stack = context.coordinator.stackView else { return }
        let needsRebuild = context.coordinator.lastScale != scale ||
                           context.coordinator.lastContainerWidth != containerWidth ||
                           context.coordinator.lastPagesPerRow != pagesPerRow

        if needsRebuild {
            context.coordinator.lastScale = scale
            context.coordinator.lastContainerWidth = containerWidth
            context.coordinator.lastPagesPerRow = pagesPerRow
            buildPages(stack: stack, scrollView: scrollView, context: context)
        }
    }

    private func buildPages(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        // Remove existing views.
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        context.coordinator.pageViews.removeAll()

        let totalWidth = containerWidth * scale

        if pagesPerRow == 1 {
            for page in pages {
                let iv = makeImageView(image: page.image, width: totalWidth)
                stack.addArrangedSubview(iv)
                context.coordinator.pageViews.append((pageIndex: page.id, view: iv))
            }
        } else {
            let pageWidth = (totalWidth - 2) / 2
            let stride2 = stride(from: 0, to: pages.count, by: 2)
            for i in stride2 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 2
                row.alignment = .top

                let leftPage = pages[i]
                let leftIV = makeImageView(image: leftPage.image, width: pageWidth)
                row.addArrangedSubview(leftIV)
                context.coordinator.pageViews.append((pageIndex: leftPage.id, view: leftIV))

                if i + 1 < pages.count {
                    let rightPage = pages[i + 1]
                    let rightIV = makeImageView(image: rightPage.image, width: pageWidth)
                    row.addArrangedSubview(rightIV)
                    // Don't track right page separately — left page index represents the row.
                }

                stack.addArrangedSubview(row)
            }
        }

        // Pin stack width to scroll view.
        stack.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true

        scrollView.layoutSubtreeIfNeeded()
    }

    private func makeImageView(image: NSImage, width: CGFloat) -> NSImageView {
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyDown
        iv.imageAlignment = .alignCenter
        // Height proportional to image aspect ratio.
        let ar = image.size.height / max(image.size.width, 1)
        let h = width * ar
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: width).isActive = true
        iv.heightAnchor.constraint(equalToConstant: h).isActive = true
        return iv
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var scrollView: NSScrollView?
        var stackView: NSStackView?
        var pageViews: [(pageIndex: Int, view: NSView)] = []
        var lastScale: CGFloat = 0
        var lastContainerWidth: CGFloat = 0
        var lastPagesPerRow: Int = 0
        var containerWidth: CGFloat = 0
        var pagesPerRow: Int = 1
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
                // Layout not ready yet, retry.
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

            // Determine visible page: find the page view whose frame top is closest to the scroll position.
            let scrollTop = sv.contentView.bounds.origin.y
            var bestPage = 0
            var bestDist = CGFloat.greatestFiniteMagnitude
            for entry in pageViews {
                let frameInDoc = entry.view.convert(entry.view.bounds, to: doc)
                let dist = abs(frameInDoc.minY - scrollTop)
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
