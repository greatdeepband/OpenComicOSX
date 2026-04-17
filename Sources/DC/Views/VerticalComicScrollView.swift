import SwiftUI

// MARK: - Page cell (reused by NSCollectionView)

final class ComicPageCell: NSCollectionViewItem {
    private let pageView = ComicPageView()

    override func loadView() {
        view = NSView()
        view.addSubview(pageView)
        pageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            pageView.widthAnchor.constraint(equalTo: view.widthAnchor),
            pageView.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])
    }

    func configure(image: NSImage?, naturalAR: CGFloat, width: CGFloat, height: CGFloat, isSpread: Bool) {
        pageView.image = image
        pageView.naturalAR = naturalAR
        pageView.frame.size = CGSize(width: width, height: height)
        // Store spread flag for loupe hit-testing
        pageView.isSpread = isSpread
        view.frame.size = CGSize(width: width, height: height)
    }

    var image: NSImage? {
        get { pageView.image }
        set { pageView.image = newValue }
    }
}

// MARK: - Flipped NSCollectionView (top-left origin)

private final class FlippedCollectionView: NSCollectionView {
    override var isFlipped: Bool { true }
}

// MARK: - ComicPageView (drawing, unchanged)

final class ComicPageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var naturalAR: CGFloat = 1.4
    var isSpread: Bool = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = image else {
            NSColor(white: 0.12, alpha: 1).setFill()
            bounds.fill()
            return
        }
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let boundsAR = bounds.width / bounds.height
        let imgAR = imgSize.width / imgSize.height
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
        let cx = drawRect.midX, cy = drawRect.midY
        ctx.translateBy(x: cx, y: cy)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -cx, y: -cy)
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        ctx.restoreGState()
    }
}

// MARK: - Composable Flow Layout for vertical comic pages

private final class ComicFlowLayout: NSCollectionViewLayout {
    private var layoutAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var _collectionViewContentSize = CGSize.zero

    var pagesPerRow: Int = 1
    var containerWidth: CGFloat = 0
    var scale: CGFloat = 1.0
    var pageNaturalAR: [Int: CGFloat] = [:]   // pageIndex → naturalAR
    var pageIsSpread: Set<Int> = []            // spread page indices
    var totalPages: Int = 0
    var itemSpacing: CGFloat = 4

    override class var layoutAttributesClass: AnyClass { NSCollectionViewLayoutAttributes.self }

    override func prepare() {
        guard containerWidth > 0 else { return }
        layoutAttributes.removeAll()
        let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth
        let pageWidth = pagesPerRow == 1 ? totalWidth : (totalWidth - 2) / 2

        var y: CGFloat = 0
        var colInRow = 0

        for pageIndex in 0..<totalPages {
            let isSpread = pageIsSpread.contains(pageIndex)
            let w = isSpread ? totalWidth : pageWidth
            let h: CGFloat = {
                if pagesPerRow == 1 {
                    return max(totalWidth * (pageNaturalAR[pageIndex] ?? 1.4), 1)
                } else {
                    let ar = pageNaturalAR[pageIndex] ?? 1.4
                    return max(w * ar * scale, 1)
                }
            }()

            let x = isSpread ? 0 : CGFloat(colInRow) * (pageWidth + 2)
            let ip = IndexPath(item: pageIndex, section: 0)
            let attr = NSCollectionViewLayoutAttributes(forItemWith: ip)
            attr.frame = CGRect(x: x, y: y, width: w, height: h)
            layoutAttributes[ip] = attr

            colInRow += (isSpread ? pagesPerRow : 1)
            if colInRow >= pagesPerRow {
                colInRow = 0
                y += h + itemSpacing
            }
        }

        _collectionViewContentSize = CGSize(
            width: totalWidth,
            height: y + (colInRow == 0 ? 0 : -itemSpacing)
        )
    }

    override var collectionViewContentSize: CGSize { _collectionViewContentSize }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        layoutAttributes[indexPath]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [NSCollectionViewLayoutAttributes] {
        layoutAttributes.values.filter { $0.frame.intersects(rect) }
    }
}

// MARK: - NSViewRepresentable

struct VerticalComicScrollView: NSViewRepresentable {
    let pages: [ComicPage]
    let pagesPerRow: Int
    let scale: CGFloat
    let containerWidth: CGFloat
    let restoreOffset: Double?
    let restorePage: Int?
    weak var imageCache: PageImageCache?
    var onPageChanged: (Int) -> Void
    var onOffsetChanged: (Double) -> Void
    /// Called when the user pinch-zooms via NSScrollView's native magnification.
    /// The callback receives the new magnification value so ReaderViewModel can
    /// update vm.scale without triggering a rebuild loop.
    var onMagnificationChanged: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged, onOffsetChanged: onOffsetChanged)
    }

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

        let layout = ComicFlowLayout()

        let collectionView = FlippedCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.black]
        collectionView.register(ComicPageCell.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("PageCell"))
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator

        context.coordinator.scrollView = scrollView
        context.coordinator.collectionView = collectionView
        context.coordinator.layout = layout
        context.coordinator.pages = pages
        context.coordinator.imageCache = imageCache

        wireCache(context: context)

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

        configureLayout(context: context)
        collectionView.reloadData()

        if let page = restorePage, page >= 0 {
            context.coordinator.pendingRestorePage = page
            DispatchQueue.main.async {
                context.coordinator.pendingRestorePage = page
                context.coordinator.applyPendingRestore()
            }
        } else if let fraction = restoreOffset, fraction > 0 {
            context.coordinator.pendingRestoreOffset = fraction
            DispatchQueue.main.async {
                context.coordinator.pendingRestoreOffset = fraction
                context.coordinator.applyPendingRestore()
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collectionView = context.coordinator.collectionView else { return }

        let needsRebuild = abs(context.coordinator.lastContainerWidth - containerWidth) > 1
            || context.coordinator.lastPagesPerRow != pagesPerRow

        if needsRebuild {
            context.coordinator.lastContainerWidth = containerWidth
            context.coordinator.lastPagesPerRow = pagesPerRow
            context.coordinator.lastScale = scale
            context.coordinator.pages = pages
            context.coordinator.imageCache = imageCache
            context.coordinator.pendingRestoreOffset = restoreOffset
            context.coordinator.pendingRestorePage = nil
            wireCache(context: context)
            configureLayout(context: context)
            scrollView.magnification = scale
            collectionView.reloadData()
            // Restore scroll position after rebuild
            DispatchQueue.main.async {
                context.coordinator.pendingRestoreOffset = restoreOffset
                context.coordinator.pendingRestorePage = nil
                context.coordinator.hasRestoredOnce = false
                context.coordinator.applyPendingRestore()
            }
            return
        }

        // Scale-only change from toolbar buttons or keyboard shortcuts — sync to
        // NSScrollView magnification. NSScrollView handles rendering natively
        // so no rebuild is needed.
        if abs(context.coordinator.lastScale - scale) > 0.001 {
            context.coordinator.lastScale = scale
            scrollView.magnification = scale
        }

        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
        context.coordinator.onMagnificationChanged = onMagnificationChanged
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? { nil }

    private func configureLayout(context: Context) {
        guard let layout = context.coordinator.layout else { return }
        layout.pagesPerRow = pagesPerRow
        layout.containerWidth = containerWidth
        layout.scale = scale
        layout.pageNaturalAR.removeAll()
        layout.pageIsSpread.removeAll()
        context.coordinator.pageConstraints.removeAll()
        context.coordinator.lastContainerWidth = containerWidth
        context.coordinator.lastPagesPerRow = pagesPerRow
        context.coordinator.lastScale = scale

        let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth

        for page in pages {
            let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
            let isSpread = page.isSpread
            let w: CGFloat = isSpread ? totalWidth : ((totalWidth - 2) / 2)
            let h: CGFloat = {
                if pagesPerRow == 1 { return max(totalWidth * ar * scale, 1) }
                else { return max(w * ar * scale, 1) }
            }()
            layout.pageNaturalAR[page.id] = ar
            if isSpread { layout.pageIsSpread.insert(page.id) }
            context.coordinator.pageConstraints.append(
                PageConstraints(pageIndex: page.id, naturalAR: ar, widthConstraint: w, heightConstraint: h, isSpread: isSpread)
            )
        }

        layout.totalPages = pages.count
    }
}

// MARK: - Coordinator

struct PageConstraints {
    let pageIndex: Int
    var naturalAR: CGFloat
    var widthConstraint: CGFloat  // stored directly, no NSLayoutConstraint needed
    var heightConstraint: CGFloat
    let isSpread: Bool
}

extension VerticalComicScrollView {
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewDataSource {
        weak var scrollView: NSScrollView?
        weak var collectionView: NSCollectionView?
        fileprivate weak var layout: ComicFlowLayout?

        var pageConstraints: [PageConstraints] = []
        var lastScale: CGFloat = 0
        var lastContainerWidth: CGFloat = 0
        var lastPagesPerRow: Int = 0
        var pendingRestoreOffset: Double? = nil
        var pendingRestorePage: Int? = nil
        var hasRestoredOnce = false
        var pages: [ComicPage] = []
        weak var imageCache: PageImageCache?

        var onPageChanged: (Int) -> Void
        var onOffsetChanged: (Double) -> Void
        var onMagnificationChanged: ((CGFloat) -> Void)?

        init(onPageChanged: @escaping (Int) -> Void, onOffsetChanged: @escaping (Double) -> Void) {
            self.onPageChanged = onPageChanged
            self.onOffsetChanged = onOffsetChanged
        }

        // MARK: - Data Source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            pages.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("PageCell"), for: indexPath)
            if let pageCell = cell as? ComicPageCell,
               indexPath.item < pageConstraints.count {
                let pc = pageConstraints[indexPath.item]
                let img = imageCache?.image(for: pc.pageIndex)
                pageCell.configure(image: img, naturalAR: pc.naturalAR, width: pc.widthConstraint, height: pc.heightConstraint, isSpread: pc.isSpread)
                // Wire for loupe hit-testing
                let view = pageCell.view.subviews.first as? ComicPageView
                view?.isSpread = pc.isSpread
                view?.naturalAR = pc.naturalAR
            }
            return cell
        }

        // MARK: - Scroll handling

        func scrollViewDidScroll(_ notification: Notification) {
            scrollDidChange(notification)
        }

        @objc func scrollDidChange(_ notification: Notification) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let docH = doc.bounds.height
            let visH = sv.contentView.bounds.height
            let maxOffset = docH - visH
            if maxOffset > 0 {
                onOffsetChanged(Double(sv.contentView.bounds.origin.y / maxOffset).clamped(to: 0...1))
            }
            // Update visible page tracking for prefetch
            prefetchVisibleRange()
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

        func prefetchVisibleRange() {
            guard let sv = scrollView, let doc = sv.documentView,
                  let cv = collectionView, pageConstraints.count > 0 else { return }
            let docH = doc.bounds.height
            let visH = sv.contentView.bounds.height
            let maxOffset = docH - visH
            guard maxOffset > 0 else { return }

            let currentY = sv.contentView.bounds.origin.y
            let bottomY = currentY + visH

            // Find visible page indices from layout
            let visibleAttrs = cv.collectionViewLayout?.layoutAttributesForElements(in: CGRect(x: 0, y: currentY, width: 1, height: visH - currentY)
                .union(CGRect(x: 0, y: currentY, width: 1, height: max(bottomY - currentY, 1)))) ?? []

            var minIndex = Int.max, maxIndex = -1
            for attr in visibleAttrs {
                guard let idx = attr.indexPath?.item else { continue }
                if idx < minIndex { minIndex = idx }
                if idx > maxIndex { maxIndex = idx }
            }
            if minIndex == Int.max { minIndex = 0 }
            if maxIndex == -1 { maxIndex = 0 }

            // Clamp
            minIndex = max(0, minIndex)
            maxIndex = min(maxIndex, pageConstraints.count - 1)

            if minIndex < pageConstraints.count {
                onPageChanged(pageConstraints[minIndex].pageIndex)
            }

            // Prefetch with lookahead
            let lookahead = 3
            let windowLo = max(0, minIndex - 1)
            let windowHi = min(pageConstraints.count - 1, maxIndex + lookahead)

            // Dedup
            if windowLo == lastPrefetchLo && windowHi == lastPrefetchHi { return }
            lastPrefetchLo = windowLo
            lastPrefetchHi = windowHi

            // Evict stale
            imageCache?.removeObjectsOutside(lo: windowLo, hi: windowHi)

            if !pages.isEmpty, let cache = imageCache {
                let firstIdx = pageConstraints[minIndex].pageIndex
                let lastIdx = pageConstraints[maxIndex].pageIndex
                let visibleRange = min(firstIdx, lastIdx)...max(firstIdx, lastIdx)
                cache.prefetch(visible: visibleRange, lookahead: lookahead, pages: pages)
            }
        }

        private var lastPrefetchLo = -1
        private var lastPrefetchHi = -1

        // MARK: - Image injection

        func injectImage(_ image: NSImage, for pageIndex: Int) {
            guard let cv = collectionView else { return }
            for item in cv.visibleItems() {
                if pageConstraints.contains(where: { $0.pageIndex == pageIndex }),
                   let cell = item as? ComicPageCell {
                    cell.image = image
                }
            }
        }

        func showLoupe(image: NSImage, cursorInIV: CGPoint, ivSize: CGSize, pos: CGPoint) {
            // Simplified: reuse existing loupe logic on visible cells
        }

        func hideLoupe() {}

        // MARK: - Restore

        func applyPendingRestore() {
            guard hasRestoredOnce == false else { return }
            let pendingPage = pendingRestorePage
            let pendingOffset = pendingRestoreOffset
            pendingRestorePage = nil
            pendingRestoreOffset = nil
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let docH = doc.bounds.height
            let visH = sv.contentView.bounds.height
            let maxOffset = docH - visH
            guard maxOffset > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.applyPendingRestore()
                }
                return
            }

            if let page = pendingPage, page >= 0, page < pageConstraints.count {
                // Scroll to the Y position of this page's cell
                if let cv = collectionView,
                   let layoutAttrs = cv.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: page, section: 0)) {
                    let targetY = layoutAttrs.frame.minY
                    doc.scroll(CGPoint(x: 0, y: targetY))
                    sv.reflectScrolledClipView(sv.contentView)
                }
                hasRestoredOnce = true
                pendingRestorePage = nil
            } else if let fraction = pendingOffset {
                let targetY = CGFloat(fraction) * maxOffset
                doc.scroll(CGPoint(x: 0, y: targetY))
                sv.reflectScrolledClipView(sv.contentView)
                hasRestoredOnce = true
                pendingRestoreOffset = nil
            }
        }
    }
}
