import AppKit
import SwiftUI

// MARK: - Flipped NSStackView (top-left origin, like UIKit)

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }

    /// NSStackView's default hitTest can route events to the wrong subview in horizontal
    /// layouts. Override to do a proper frame-based hit-test across arranged subviews.
    ///
    /// NSView.hitTest(_:) contract: point is in the RECEIVER'S superview coordinate space.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Convert from superview space to our own bounds space.
        let localPt = convert(point, from: superview)
        guard bounds.contains(localPt) else { return nil }
        // For each arranged subview, pass the point in OUR coordinate space
        // (which is the subview's superview space — exactly what hitTest expects).
        for subview in arrangedSubviews.reversed() {
            if let hit = subview.hitTest(localPt) { return hit }
        }
        return self
    }
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
        let localPt  = convert(event.locationInWindow, from: nil)
        let windowPt = event.locationInWindow
        let imgSize  = image.size
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

        // ── DEBUG LOUPE ──────────────────────────────────────────────────────
        // Frame of this view in window coordinates (for diagnosing wrong-view hit-test)
        let frameInWindow = convert(bounds, to: nil)
        let debugLine = "[LOUPE-DEBUG] isFlipped=\(isFlipped) superFlipped=\(superview?.isFlipped ?? false)\n" +
            "[LOUPE-DEBUG] frameInWindow=(\(frameInWindow.minX),\(frameInWindow.minY) \(frameInWindow.width)x\(frameInWindow.height))\n" +
            "[LOUPE-DEBUG] bounds=(\(bounds.width)x\(bounds.height)) imgSize=(\(imgSize.width)x\(imgSize.height)) imgAR=\(String(format:"%.3f",imgAR)) boundsAR=\(String(format:"%.3f",boundsAR))\n" +
            "[LOUPE-DEBUG] windowPt=(\(windowPt.x),\(windowPt.y)) localPt=(\(localPt.x),\(localPt.y))\n" +
            "[LOUPE-DEBUG] ivSize=(\(ivSize.width)x\(ivSize.height)) offset=(\(ox),\(oy)) cursorInIV=(\(cursorInIV.x),\(cursorInIV.y))\n"
        if let data = debugLine.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/loupe_debug.txt")
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
        // ─────────────────────────────────────────────────────────────────────

        let info = LoupeInfo(image: image,
                             cursorInImageView: cursorInIV,
                             imageViewSize: ivSize,
                             positionInWindow: windowPt)
        NotificationCenter.default.post(name: name, object: info)
    }

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

        // Full rebuild only when the column layout changes (pagesPerRow or containerWidth).
        // Scale changes are handled by updating constraints in-place — no view recreation.
        let needsRebuild = context.coordinator.lastContainerWidth != containerWidth
            || context.coordinator.lastPagesPerRow != pagesPerRow

        if needsRebuild {
            context.coordinator.lastContainerWidth = containerWidth
            context.coordinator.lastPagesPerRow = pagesPerRow
            context.coordinator.lastScale = scale
            buildPages(stack: stack, scrollView: scrollView, context: context)
            return
        }

        // Scale-only change: update existing constraints without touching the view hierarchy.
        if context.coordinator.lastScale != scale {
            context.coordinator.lastScale = scale
            applyScale(stack: stack, scrollView: scrollView, context: context)
        }

        // Keep callbacks current.
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
    }

    // MARK: - Full page build (called only on layout changes)

    private func buildPages(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        context.coordinator.pageViews.removeAll()
        context.coordinator.pageConstraints.removeAll()

        // Single-column: total width scales with zoom so pages grow wider.
        // Double-column: total width is pinned to containerWidth (no horizontal scroll);
        //   zoom only increases page height, making the column taller to scroll through.
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
            // In double-column mode the height of each page is scaled:
            //   naturalHeight = pageWidth * (imageHeight / imageWidth)
            //   scaledHeight  = naturalHeight * scale
            for i in stride(from: 0, to: pages.count, by: 2) {
                let row = FlippedStackView()   // Must be flipped so convert(from:nil) works correctly in child ComicPageViews
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

        // Stack-level width constraint.
        stack.constraints.filter { $0.firstAttribute == .width }.forEach { stack.removeConstraint($0) }
        let stackWC = stack.widthAnchor.constraint(equalToConstant: totalWidth)
        stackWC.isActive = true
        context.coordinator.stackWidthConstraint = stackWC

        scrollView.layoutSubtreeIfNeeded()
    }

    // MARK: - In-place scale update (no view recreation)

    /// Updates only the NSLayoutConstraint constants for all pages and the stack width.
    /// This avoids tearing down and recreating any NSView, keeping memory flat and
    /// eliminating the visible flash that the old buildPages()-on-zoom approach caused.
    private func applyScale(stack: NSStackView, scrollView: NSScrollView, context: Context) {
        if pagesPerRow == 1 {
            // Single-column: width and height both scale.
            let totalWidth = containerWidth * scale
            for pc in context.coordinator.pageConstraints {
                let ar = pc.image.size.height / max(pc.image.size.width, 1)
                pc.widthConstraint.constant  = totalWidth
                pc.heightConstraint.constant = max(totalWidth * ar, 1)
            }
            context.coordinator.stackWidthConstraint?.constant = totalWidth
        } else {
            // Double-column: width is pinned to containerWidth; only height scales.
            // This keeps both pages visible without horizontal scrolling.
            let totalWidth = containerWidth
            let pageWidth = (totalWidth - 2) / 2
            for pc in context.coordinator.pageConstraints {
                let naturalH = pageWidth * (pc.image.size.height / max(pc.image.size.width, 1))
                pc.heightConstraint.constant = max(naturalH * scale, 1)
                // widthConstraint and rowConstraint are already correct (pinned to containerWidth).
            }
            // Stack width stays at containerWidth — no update needed.
        }

        scrollView.layoutSubtreeIfNeeded()
    }

    // MARK: - Factory

    /// Creates a ComicPageView and returns it together with its width and height constraints
    /// so the coordinator can update them in-place later without a full rebuild.
    /// `heightScale` is applied on top of the natural aspect-ratio height.
    /// For single-column pages this is the same as the width scale (width already includes scale).
    /// For double-column pages the width is fixed; only height is scaled.
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

    /// Holds the live NSLayoutConstraints for each page so applyScale() can update
    /// them without recreating any views.
    struct PageConstraints {
        let view: NSView
        let image: NSImage
        let widthConstraint: NSLayoutConstraint
        let heightConstraint: NSLayoutConstraint
        /// The row NSStackView's width constraint (only set for the left page in each pair;
        /// nil for right pages and all single-column pages).
        let rowConstraint: NSLayoutConstraint?
    }

    final class Coordinator: NSObject {
        var scrollView: NSScrollView?
        var stackView: NSStackView?
        var pageViews: [(pageIndex: Int, view: NSView)] = []
        /// Per-page layout constraints for in-place scale updates.
        var pageConstraints: [PageConstraints] = []
        /// The stack view's own width constraint.
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
