import SwiftUI
import AppKit

/// Metal-backed reader view using NSScrollView for scroll math
/// and CAMetalLayer for GPU rendering. Replaces the NSStackView
/// + NSImage pipeline for vertical and vertical-double modes.
struct MetalPageView: NSViewRepresentable {
    let pages: [ComicPage]
    let pagesPerRow: Int  // 1 = vertical single, 2 = vertical double
    let scale: CGFloat
    let containerWidth: CGFloat
    let restorePage: Int?
    let restoreOffset: Double?
    weak var imageCache: PageImageCache?

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
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.magnification = scale

        let metalView = MetalCanvasView(frame: .zero)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.frame = CGRect(x: 0, y: 0, width: containerWidth, height: 1000) // placeholder

        guard let renderer = MetalPageRenderer() else {
            fatalError("Metal is not available on this device")
        }

        let manager = MetalPageManager()

        context.coordinator.scrollView = scrollView
        context.coordinator.metalView = metalView
        context.coordinator.renderer = renderer
        context.coordinator.pageManager = manager
        context.coordinator.pages = pages
        context.coordinator.pagesPerRow = pagesPerRow
        context.coordinator.containerWidth = containerWidth
        context.coordinator.scale = scale

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

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
        context.coordinator.onMagnificationChanged = onMagnificationChanged

        let needsRebuild = context.coordinator.needsRebuild(
            containerWidth: containerWidth,
            pagesPerRow: pagesPerRow,
            pages: pages
        )

        if needsRebuild {
            context.coordinator.pages = pages
            context.coordinator.pagesPerRow = pagesPerRow
            context.coordinator.containerWidth = containerWidth
            context.coordinator.rebuildLayout()
        }

        if abs(context.coordinator.scale - scale) > 0.001 {
            context.coordinator.scale = scale
            scrollView.magnification = scale
        }

        context.coordinator.updateVisibleRange()
    }
}

// MARK: - MetalCanvasView

final class MetalCanvasView: NSView {
    var metalLayer: CAMetalLayer

    override init(frame frameRect: NSRect) {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        self.metalLayer = layer
        super.init(frame: frameRect)
        self.layer = layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        metalLayer.drawableSize = CGSize(
            width: bounds.width * (NSScreen.main?.backingScaleFactor ?? 2.0),
            height: bounds.height * (NSScreen.main?.backingScaleFactor ?? 2.0)
        )
    }
}

// MARK: - Coordinator

extension MetalPageView {
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var metalView: MetalCanvasView?
        var renderer: MetalPageRenderer?
        var pageManager: MetalPageManager?
        var pages: [ComicPage] = []
        var pagesPerRow: Int = 1
        var containerWidth: CGFloat = 0
        var scale: CGFloat = 1.0

        var pagePositions: [Int: CGRect] = [:]
        var pageYOffsets: [CGFloat] = []

        var lastContainerWidth: CGFloat = 0
        var lastPagesPerRow: Int = 0

        var onPageChanged: (Int) -> Void = { _ in }
        var onOffsetChanged: (Double) -> Void = { _ in }
        var onMagnificationChanged: ((CGFloat) -> Void)?

        init(
            onPageChanged: @escaping (Int) -> Void,
            onOffsetChanged: @escaping (Double) -> Void,
            onMagnificationChanged: ((CGFloat) -> Void)?
        ) {
            self.onPageChanged = onPageChanged
            self.onOffsetChanged = onOffsetChanged
            self.onMagnificationChanged = onMagnificationChanged
        }

        func needsRebuild(containerWidth: CGFloat, pagesPerRow: Int, pages: [ComicPage]) -> Bool {
            return abs(lastContainerWidth - containerWidth) > 1
                || lastPagesPerRow != pagesPerRow
        }

        func rebuildLayout() {
            guard let metalView = metalView else { return }

            pagePositions.removeAll()
            pageYOffsets.removeAll()

            let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth
            var y: CGFloat = 0
            var i = 0

            while i < pages.count {
                let page = pages[i]
                let ar = page.naturalSize.height / max(page.naturalSize.width, 1)

                if pagesPerRow == 1 {
                    let h = totalWidth * ar
                    let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                    pagePositions[page.id] = rect
                    pageYOffsets.append(y)
                    y += h + 4
                    i += 1
                } else {
                    // Vertical double: pair pages side by side
                    let pageWidth = (totalWidth - 2) / 2

                    if page.isSpread {
                        // Full-width spread
                        let h = totalWidth * ar
                        let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                        pagePositions[page.id] = rect
                        pageYOffsets.append(y)
                        y += h + 4
                        i += 1
                    } else {
                        // Left page
                        let leftH = pageWidth * ar
                        let leftRect = CGRect(x: 0, y: y, width: pageWidth, height: leftH)
                        pagePositions[page.id] = leftRect

                        // Right page (if exists and not a spread)
                        if i + 1 < pages.count && !pages[i + 1].isSpread {
                            let rightPage = pages[i + 1]
                            let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                            let rightH = pageWidth * rightAR
                            let rightRect = CGRect(x: pageWidth + 2, y: y, width: pageWidth, height: rightH)
                            pagePositions[rightPage.id] = rightRect
                            i += 2
                        } else {
                            i += 1
                        }
                        pageYOffsets.append(y)
                        let maxH = leftH + 4 // could be refined per-pair
                        y += maxH + 4
                    }
                }
            }

            let totalHeight = y
            metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            lastContainerWidth = containerWidth
            lastPagesPerRow = pagesPerRow

            metalView.needsDisplay = true
        }

        func scrollToPage(_ page: Int) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            guard page < pageYOffsets.count else { return }
            let targetY = pageYOffsets[page]
            doc.scroll(CGPoint(x: 0, y: targetY))
            sv.reflectScrolledClipView(sv.contentView)
            updateVisibleRange()
        }

        func scrollToFraction(_ fraction: Double) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let maxY = doc.bounds.height - sv.contentView.bounds.height
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

            // Binary search for first visible page
            var lo = 0, hi = pageYOffsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageYOffsets[mid] <= currentY { lo = mid } else { hi = mid - 1 }
            }
            let firstVisible = lo

            var lo2 = firstVisible, hi2 = pageYOffsets.count - 1
            while lo2 < hi2 {
                let mid = (lo2 + hi2 + 1) / 2
                if pageYOffsets[mid] < bottomY { lo2 = mid } else { hi2 = mid - 1 }
            }
            let lastVisible = lo2

            let visibleRange = firstVisible...lastVisible

            if !pages.isEmpty {
                let firstIdx = pages.indices.contains(firstVisible) ? pages[firstVisible].id : 0
                let lastIdx = pages.indices.contains(lastVisible) ? pages[lastVisible].id : firstIdx
                onPageChanged(firstIdx)
                triggerPrefetch(first: firstIdx, last: lastIdx)
            }

            render(visibleRange: visibleRange)
        }

        func triggerPrefetch(first: Int, last: Int) {
            guard let manager = pageManager, !pages.isEmpty else { return }
            let lookahead = 3
            let firstIdx = max(0, first - lookahead)
            let lastIdx = min(pages.count - 1, last + lookahead)

            Task {
                for idx in firstIdx...lastIdx {
                    let page = pages[idx]
                    // Extract image data from PageSource if available
                    if case .zipData(let archiveData, _) = page.source {
                        _ = await manager.decodePage(pageIndex: page.id, from: archiveData, entryIndex: idx)
                    }
                    // For .file and .zip sources, decoding happens via CGImageSource directly
                    // which requires file system access - skip prefetch for those types
                }
            }
        }

        func render(visibleRange: ClosedRange<Int>) {
            guard let metalView = metalView,
                  let renderer = renderer,
                  let pageManager = pageManager,
                  let drawable = metalView.metalLayer.nextDrawable(),
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }

            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            // Evict textures outside visible range first
            renderer.evictOutside(visibleRange)

            // Upload any decoded CVPixelBuffers to the texture ring before rendering
            Task {
                for pageIndex in visibleRange {
                    if let buffer = await pageManager.page(for: pageIndex) {
                        // Upload if not already in ring (upload() handles its own LRU)
                        if renderer.texture(for: pageIndex) == nil {
                            _ = renderer.upload(pixelBuffer: buffer, for: pageIndex)
                        }
                    }
                }
            }

            renderer.render(
                viewport: metalView.bounds,
                visibleRange: visibleRange,
                pagePositions: pagePositions,
                renderPassDescriptor: renderPassDescriptor,
                commandBuffer: commandBuffer
            )

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @objc func scrollDidChange(_ notification: Notification) {
            updateVisibleRange()
        }

        @objc func magnificationDidChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            onMagnificationChanged?(sv.magnification)
        }
    }
}
