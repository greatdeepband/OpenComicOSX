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
        // Initialize lastScale to current scale so first updateNSView doesn't trigger scale sync
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

        if abs(context.coordinator.lastScale - scale) > 0.001 {
            context.coordinator.lastScale = scale
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
        /// Tracks the last scale we synced TO the NSScrollView to avoid feedback loops.
        var lastScale: CGFloat = 1.0

        /// Maps sequential index → page id (stable across rebuilds).
        var sequentialToID: [Int] = []
        /// Maps page id → sequential index.
        var idToSequential: [Int: Int] = [:]

        var pagePositions: [Int: CGRect] = [:]
        /// Cumulative Y-offset table for binary search (sequential index → Y).
        var pageYOffsets: [CGFloat] = []

        /// Spreads map for vertical-double mode: left sequential index → SpreadInfo.
        var spreads: [Int: SpreadInfo] = [:]

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

        /// Rebuilds the layout from scratch: recomputes all position tables and
        /// rebuilds the sequential↔pageID mapping to match the current pages array.
        func rebuildLayout() {
            guard let metalView = metalView else { return }

            pagePositions.removeAll()
            pageYOffsets.removeAll()
            spreads.removeAll()

            // Build sequential index → page ID map
            sequentialToID = pages.map { $0.id }
            idToSequential.removeAll()
            for (seqIdx, pageID) in sequentialToID.enumerated() {
                idToSequential[pageID] = seqIdx
            }

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
                // Vertical double: pair pages side by side
                var i = 0
                while i < pages.count {
                    let page = pages[i]

                    if page.isSpread {
                        // Full-width spread: occupies its own row
                        let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                        let h = totalWidth * ar
                        let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                        pagePositions[page.id] = rect
                        pageYOffsets.append(y)
                        y += h + 4
                        i += 1
                    } else {
                        // Pair: left + right pages in same row at same Y
                        let pageWidth = (totalWidth - 2) / 2
                        let leftAR = page.naturalSize.height / max(page.naturalSize.width, 1)
                        let leftH = pageWidth * leftAR
                        let leftRect = CGRect(x: 0, y: y, width: pageWidth, height: leftH)
                        pagePositions[page.id] = leftRect

                        // Record Y for left page (sequential index i)
                        pageYOffsets.append(y)

                        let leftSeqIdx = i // capture before potential increment

                        var rightH: CGFloat = leftH
                        var rightRect: CGRect?
                        var rightSeqIdx: Int?
                        if i + 1 < pages.count && !pages[i + 1].isSpread {
                            let rightPage = pages[i + 1]
                            let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                            rightH = pageWidth * rightAR
                            rightRect = CGRect(x: pageWidth + 2, y: y, width: pageWidth, height: rightH)
                            pagePositions[rightPage.id] = rightRect
                            rightSeqIdx = i + 1
                            i += 2
                        } else {
                            i += 1
                        }

                        // Build spread info for the renderer
                        let spreadRect = CGRect(x: 0, y: y, width: totalWidth, height: max(leftH, rightH))
                        if let rSeq = rightSeqIdx, let _ = rightRect {
                            spreads[leftSeqIdx] = SpreadInfo(rightIndex: rSeq, rect: spreadRect)
                        }

                        // Advance Y by the max of the two page heights plus spacing
                        y += max(leftH, rightH) + 4
                    }
                }
            }

            // Push spreads to renderer so it can manage spread textures
            renderer?.setSpreads(spreads)

            let totalHeight = y
            metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            lastContainerWidth = containerWidth
            lastPagesPerRow = pagesPerRow

            metalView.needsDisplay = true
        }

        /// Restores scroll position by page index (sequential index).
        func scrollToPage(_ page: Int) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            guard page >= 0 && page < pageYOffsets.count else { return }
            let targetY = pageYOffsets[page]
            doc.scroll(CGPoint(x: 0, y: targetY))
            sv.reflectScrolledClipView(sv.contentView)
            updateVisibleRange()
        }

        /// Restores scroll position by fractional offset (0.0–1.0).
        func scrollToFraction(_ fraction: Double) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let maxY = doc.bounds.height - sv.contentView.bounds.height
            guard maxY > 0 else { return }
            let targetY = CGFloat(fraction) * maxY
            doc.scroll(CGPoint(x: 0, y: targetY))
            sv.reflectScrolledClipView(sv.contentView)
            updateVisibleRange()
        }

        /// Finds the sequential page index at the center of the viewport.
        private func sequentialIndexAtCenter() -> Int {
            guard let sv = scrollView else { return 0 }
            let currentY = sv.contentView.bounds.origin.y
            let visH = sv.contentView.bounds.height
            let centerY = currentY + visH / 2

            var lo = 0, hi = pageYOffsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageYOffsets[mid] <= centerY { lo = mid } else { hi = mid - 1 }
            }
            return lo
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

            // Binary search for first visible page (sequential index)
            var lo = 0, hi = pageYOffsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageYOffsets[mid] <= currentY { lo = mid } else { hi = mid - 1 }
            }
            let firstVisible = lo

            // Binary search for last visible page
            var lo2 = firstVisible, hi2 = pageYOffsets.count - 1
            while lo2 < hi2 {
                let mid = (lo2 + hi2 + 1) / 2
                if pageYOffsets[mid] < bottomY { lo2 = mid } else { hi2 = mid - 1 }
            }
            let lastVisible = lo2

            let visibleRange = firstVisible...lastVisible

            // Report page to ViewModel using SEQUENTIAL index (not page ID)
            // The ViewModel.currentPage is also a sequential index.
            onPageChanged(firstVisible)
            triggerPrefetch(first: firstVisible, last: lastVisible)

            Task { [weak self] in
                await self?.render(visibleRange: visibleRange)
            }
        }

        func triggerPrefetch(first: Int, last: Int) {
            guard let manager = pageManager, !pages.isEmpty else { return }
            let lookahead = 3
            let firstIdx = max(0, first - lookahead)
            let lastIdx = min(pages.count - 1, last + lookahead)

            Task {
                for seqIdx in firstIdx...lastIdx {
                    guard seqIdx < pages.count else { continue }
                    let page = pages[seqIdx]
                    // Decode page from its source (handles .zipData, .file, .pdf, etc.)
                    // Pass the SEQUENTIAL index as the key — MetalPageManager stores
                    // decoded pages by sequential index so texture lookups are consistent.
                    if let buffer = await manager.decodePage(pageIndex: seqIdx, from: page.source) {
                        _ = buffer
                    }
                }
            }
        }

        /// Render the visible page range. Uses SEQUENTIAL indices throughout —
        /// sequentialToID translates to page IDs for MetalPageManager lookups
        /// and pagePositions lookups.
        @MainActor
        func render(visibleRange: ClosedRange<Int>) async {
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

            // Synchronously upload visible pages — needed for the current frame
            for seqIdx in visibleRange {
                guard seqIdx < pages.count else { continue }
                if let buffer = await pageManager.page(for: seqIdx) {
                    if renderer.texture(for: seqIdx) == nil {
                        _ = renderer.upload(pixelBuffer: buffer, for: seqIdx)
                    }
                }
            }

            // For vertical-double mode: compose spread textures from paired pages
            if pagesPerRow == 2 {
                for leftIdx in visibleRange {
                    guard let spread = spreads[leftIdx] else { continue }
                    let leftRect = pagePositions[pages[leftIdx].id] ?? .zero
                    let rightRect = pagePositions[pages[spread.rightIndex].id] ?? .zero
                    _ = renderer.composeSpread(
                        leftIndex: leftIdx,
                        rightIndex: spread.rightIndex,
                        leftRect: leftRect,
                        rightRect: rightRect,
                        commandBuffer: commandBuffer
                    )
                }
            }

            // Build page positions for this render pass using SEQUENTIAL indices
            var renderPositions: [Int: CGRect] = [:]
            for seqIdx in visibleRange {
                guard seqIdx < pages.count else { continue }
                let pageID = pages[seqIdx].id
                if let rect = pagePositions[pageID] {
                    renderPositions[seqIdx] = rect
                }
            }

            renderer.render(
                viewport: metalView.bounds,
                visibleRange: visibleRange,
                pagePositions: renderPositions,
                renderPassDescriptor: renderPassDescriptor,
                commandBuffer: commandBuffer,
                spreads: pagesPerRow == 2 ? spreads : [:]
            )

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @objc func scrollDidChange(_ notification: Notification) {
            updateVisibleRange()
        }

        @objc func magnificationDidChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            lastScale = sv.magnification
            scale = sv.magnification
            onMagnificationChanged?(sv.magnification)
        }
    }
}
