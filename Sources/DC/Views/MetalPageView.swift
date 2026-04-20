import SwiftUI
import AppKit
import Metal

// MARK: - MetalLoupeOverlayView

/// A transparent NSView that sits as a sibling of the NSScrollView inside the
/// NSViewRepresentable's host view. It captures right-click events across the
/// entire scroll area and fires loupe update callbacks.
final class MetalLoupeOverlayView: NSView {
    /// Called with (document-space point, overlay-space cursor point)
    var onLoupeUpdate: ((CGPoint, CGPoint) -> Void)?
    var onLoupeEnd: (() -> Void)?

    weak var scrollView: NSScrollView?

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
        // Document-space point (accounts for scroll position)
        let docPt = CGPoint(
            x: overlayPt.x + scrollOffset.x,
            y: overlayPt.y + scrollOffset.y
        )

        // Also pass the overlay-space cursor position for loupe window placement
        let cursorPt = CGPoint(x: overlayPt.x, y: overlayPt.y)
        onLoupeUpdate?(docPt, cursorPt)
    }
}

// MARK: - LoupeMetalView

/// NSView subclass that owns a CAMetalLayer and renders the loupe texture
/// via a blit encoder in draw().
final class LoupeMetalView: NSView {
    var loupeTexture: MTLTexture?
    var loupeSize: CGSize = .zero

    private let metalLayer = CAMetalLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        wantsLayer = true
        layer = metalLayer
    }

    override func layout() {
        super.layout()
        metalLayer.drawableSize = CGSize(
            width: bounds.width * (NSScreen.main?.backingScaleFactor ?? 2.0),
            height: bounds.height * (NSScreen.main?.backingScaleFactor ?? 2.0)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let texture = loupeTexture,
              let drawable = metalLayer.nextDrawable(),
              let device = metalLayer.device,
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - MetalLoupeView

/// SwiftUI wrapper around LoupeMetalView — renders the 2× magnified loupe
/// texture produced by MetalPageRenderer.renderLoupe().
struct MetalLoupeView: NSViewRepresentable {
    let loupeTexture: MTLTexture?
    let loupeSize: CGSize

    func makeNSView(context: Context) -> LoupeMetalView {
        LoupeMetalView()
    }

    func updateNSView(_ nsView: LoupeMetalView, context: Context) {
        nsView.loupeTexture = loupeTexture
        nsView.loupeSize = loupeSize
        nsView.setBoundsSize(loupeSize)
        nsView.needsDisplay = true
    }
}

// MARK: - MetalPageView

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

        // Add loupe overlay as sibling of scroll view
        DispatchQueue.main.async {
            self.addLoupeOverlay(to: scrollView, context: context)
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

    // MARK: - Loupe overlay

    private func addLoupeOverlay(to scrollView: NSScrollView, context: Context) {
        guard context.coordinator.loupeOverlay == nil else { return }

        let overlay = MetalLoupeOverlayView()
        overlay.frame = scrollView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.scrollView = scrollView

        let coordinator = context.coordinator
        overlay.onLoupeUpdate = { [weak coordinator] docPt, cursorPt in
            coordinator?.showLoupe(docPt: docPt, cursorOverlayPt: cursorPt)
        }
        overlay.onLoupeEnd = { [weak coordinator] in
            coordinator?.hideLoupe()
        }

        scrollView.superview?.addSubview(overlay)
        context.coordinator.loupeOverlay = overlay
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
        var lastScale: CGFloat = 1.0

        var sequentialToID: [Int] = []
        var idToSequential: [Int: Int] = [:]

        var pagePositions: [Int: CGRect] = [:]
        var pageYOffsets: [CGFloat] = []

        /// Spreads map for vertical-double mode: left sequential index → SpreadInfo.
        var spreads: [Int: SpreadInfo] = [:]

        var lastContainerWidth: CGFloat = 0
        var lastPagesPerRow: Int = 0

        var onPageChanged: (Int) -> Void = { _ in }
        var onOffsetChanged: (Double) -> Void = { _ in }
        var onMagnificationChanged: ((CGFloat) -> Void)?

        // MARK: - Loupe state
        var loupeOverlay: MetalLoupeOverlayView?
        var loupeHostingView: NSHostingView<AnyView>?
        @objc dynamic var loupeTexture: MTLTexture?
        @objc dynamic var loupeSize: CGSize = .zero
        private let loupeRadius: CGFloat = 270
        private let loupeMagnification: CGFloat = 2.0

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
            spreads.removeAll()

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

                        let leftSeqIdx = i

                        var rightH: CGFloat = leftH
                        var rightSeqIdx: Int?
                        if i + 1 < pages.count && !pages[i + 1].isSpread {
                            let rightPage = pages[i + 1]
                            let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                            rightH = pageWidth * rightAR
                            let rightRect = CGRect(x: pageWidth + 2, y: y, width: pageWidth, height: rightH)
                            pagePositions[rightPage.id] = rightRect
                            rightSeqIdx = i + 1
                            i += 2
                        } else {
                            i += 1
                        }

                        let spreadRect = CGRect(x: 0, y: y, width: totalWidth, height: max(leftH, rightH))
                        if let rSeq = rightSeqIdx {
                            spreads[leftSeqIdx] = SpreadInfo(rightIndex: rSeq, rect: spreadRect)
                        }

                        y += max(leftH, rightH) + 4
                    }
                }
            }

            renderer?.setSpreads(spreads)

            let totalHeight = y
            metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            lastContainerWidth = containerWidth
            lastPagesPerRow = pagesPerRow

            metalView.needsDisplay = true
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
            let firstVisible = lo

            var lo2 = firstVisible, hi2 = pageYOffsets.count - 1
            while lo2 < hi2 {
                let mid = (lo2 + hi2 + 1) / 2
                if pageYOffsets[mid] < bottomY { lo2 = mid } else { hi2 = mid - 1 }
            }
            let lastVisible = lo2

            let visibleRange = firstVisible...lastVisible

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
                    if let buffer = await manager.decodePage(pageIndex: seqIdx, from: page.source) {
                        _ = buffer
                    }
                }
            }
        }

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

            renderer.evictOutside(visibleRange)

            for seqIdx in visibleRange {
                guard seqIdx < pages.count else { continue }
                if let buffer = await pageManager.page(for: seqIdx) {
                    if renderer.texture(for: seqIdx) == nil {
                        _ = renderer.upload(pixelBuffer: buffer, for: seqIdx)
                    }
                }
            }

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

        // MARK: - Loupe

        /// Shows or updates the loupe at the given document-space point and
        /// overlay-space cursor position.
        func showLoupe(docPt: CGPoint, cursorOverlayPt: CGPoint) {
            guard let renderer = renderer else { return }

            // Find which page this point falls in
            let seqIdx = findSequentialIndex(at: docPt)
            guard seqIdx >= 0, seqIdx < pages.count else { return }

            // Get the texture for this page (check spread first in double mode)
            var texture: MTLTexture?
            if pagesPerRow == 2, let spread = spreads[seqIdx] {
                texture = renderer.spreadTexture(for: seqIdx) ?? renderer.texture(for: seqIdx)
                    ?? renderer.texture(for: spread.rightIndex)
            } else {
                texture = renderer.texture(for: seqIdx)
            }

            guard let srcTexture = texture else { return }

            // Compute page rect in document space
            let pageID = sequentialToID[seqIdx]
            guard let pageRect = pagePositions[pageID] else { return }

            // Normalised cursor position within the page (0-1, bottom-left origin)
            let cursorNormX = (docPt.x - pageRect.minX) / pageRect.width
            let cursorNormY = (docPt.y - pageRect.minY) / pageRect.height

            // Cursor in image (pixel) space — use texture dimensions
            let cursorTexX = cursorNormX
            let cursorTexY = cursorNormY

            let loupePx = loupeRadius
            let loupeDisplaySize = CGSize(width: loupePx * 2, height: loupePx * 2)

            // Render the loupe texture
            guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
            let loupeTex = renderer.renderLoupe(
                srcTexture: srcTexture,
                cursorTexCoord: CGPoint(x: cursorTexX, y: cursorTexY),
                loupeRadiusPx: loupeRadius / CGFloat(loupeMagnification),
                targetSize: loupeDisplaySize,
                commandBuffer: commandBuffer
            )
            commandBuffer.commit()

            guard let resultTex = loupeTex else { return }

            // Build the SwiftUI loupe view
            let loupeView = MetalLoupeView(
                loupeTexture: resultTex,
                loupeSize: loupeDisplaySize
            )

            let frame = NSRect(
                x: cursorOverlayPt.x - loupePx,
                y: cursorOverlayPt.y - loupePx,
                width: loupePx * 2,
                height: loupePx * 2
            )

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

        /// Binary search: finds the sequential index whose page rect contains `docPt.y`.
        /// Returns -1 if not found.
        private func findSequentialIndex(at docPt: CGPoint) -> Int {
            guard !pageYOffsets.isEmpty else { return -1 }

            var lo = 0, hi = pageYOffsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageYOffsets[mid] <= docPt.y { lo = mid } else { hi = mid - 1 }
            }

            let idx = lo
            let pageID = sequentialToID[idx]
            guard let rect = pagePositions[pageID] else { return -1 }

            // Check if point is within the horizontal bounds of this page
            if docPt.x >= rect.minX && docPt.x <= rect.maxX &&
               docPt.y >= rect.minY && docPt.y <= rect.maxY {
                return idx
            }
            return -1
        }
    }
}
