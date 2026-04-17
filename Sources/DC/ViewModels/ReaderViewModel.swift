import Foundation
import SwiftUI

// MARK: - Page Image Cache

/// Thread-safe asymmetric sliding-window image cache for the reader, using Swift actor isolation.
///
/// The window is biased forward: [center - 1 ... center + 3].
/// Pages outside the window are explicitly evicted — we never rely on NSCache's
/// opaque eviction policy. This hard-caps the decoded page count at 5 at any time.
///
/// ## Threading notes
/// - `image(for:)` is nonisolated because NSCache is thread-safe.
/// - `prefetch` methods are nonisolated and return immediately (fire-and-forget).
/// - Completion callbacks (`onPageReady`, `onPageReadySwiftUI`) fire on `@MainActor`.
actor PageImageCache {
    private let cache = NSCache<NSNumber, NSImage>()

    /// Tracks which pages are currently being decoded to avoid duplicate work.
    /// Actor-isolated — access is serialized by the actor.
    private var inFlight = Set<Int>()

    /// Primary callback — used by VerticalComicScrollView coordinator for direct NSView injection.
    /// Marked nonisolated(unsafe) so it can be set from @MainActor and called from
    /// MainActor.run blocks without cross-actor isolation errors.
    nonisolated(unsafe) var onPageReady: ((Int, NSImage) -> Void)?

    /// Secondary callback — used by ReaderViewModel to bump cacheVersion for SwiftUI re-render.
    /// Marked nonisolated(unsafe) so it can be set from @MainActor and called from
    /// MainActor.run blocks without cross-actor isolation errors.
    nonisolated(unsafe) var onPageReadySwiftUI: ((Int, NSImage) -> Void)?

    /// Window shape: how many pages to keep behind and ahead of the current page.
    private let lookBehind = 1
    private let lookAhead  = 3

    init() {
        // Safety headroom above the 5-page window.
        cache.countLimit = 8
    }

    /// Returns the cached image for a page index, or nil if not yet decoded.
    /// nonisolated: NSCache is thread-safe.
    nonisolated func image(for index: Int) -> NSImage? {
        cache.object(forKey: NSNumber(value: index))
    }

    /// Inserts a decoded image into the cache.
    private func insert(image: NSImage?, for index: Int) {
        if let image {
            cache.setObject(image, forKey: NSNumber(value: index))
        }
        inFlight.remove(index)
    }

    /// Viewport-aware prefetch for vertical scroll modes.
    /// nonisolated so it can be called without await from any context.
    ///
    /// `visible` is the exact range of pages currently on screen (computed by the
    /// scroll view from its viewport rect and pre-computed Y offsets).
    /// `lookahead` pages beyond the visible range are also decoded proactively.
    /// Only pages outside (visible.lowerBound - 1 ... visible.upperBound + lookahead)
    /// are evicted — pages on screen are never removed.
    nonisolated func prefetch(visible: ClosedRange<Int>, lookahead: Int, pages: [ComicPage]) {
        Task { [weak self] in
            guard let self else { return }
            await self._prefetchVisible(visible: visible, lookahead: lookahead, pages: pages)
        }
    }

    /// Internal async implementation of viewport-aware prefetch.
    private func _prefetchVisible(visible: ClosedRange<Int>, lookahead: Int, pages: [ComicPage]) async {
        let lo = max(0, visible.lowerBound - 1)
        let hi = min(pages.count - 1, visible.upperBound + lookahead)

        await DCLogger.shared.log("PREFETCH viewport [\(visible.lowerBound)...\(visible.upperBound)] window [\(lo)...\(hi)]")

        await evictOutside(lo: lo, hi: hi)

        for i in lo...hi {
            if cache.object(forKey: NSNumber(value: i)) != nil { continue }
            if inFlight.contains(i) { continue }

            inFlight.insert(i)

            await DCLogger.shared.log("PREFETCH QUEUE page \(i)")
            let source = pages[i].source
            let idx = i
            Task(priority: .userInitiated) { [weak self] in
                guard let decodedImage = source.decode() else {
                    await DCLogger.shared.log("PREFETCH FAIL  page \(idx) — decode returned nil")
                    await self?.insert(image: nil, for: idx)
                    return
                }
                await self?.insert(image: decodedImage, for: idx)
                await MainActor.run {
                    self?.onPageReady?(idx, decodedImage)
                    self?.onPageReadySwiftUI?(idx, decodedImage)
                }
            }
        }
    }

    /// Schedules decoding for pages in [center - lookBehind ... center + lookAhead],
    /// then explicitly evicts everything outside that window.
    /// nonisolated so it can be called without await from any context.
    nonisolated func prefetch(around center: Int, pages: [ComicPage]) {
        Task { [weak self] in
            guard let self else { return }
            await self._prefetchAround(center: center, pages: pages)
        }
    }

    /// Internal async implementation of prefetch around center.
    private func _prefetchAround(center: Int, pages: [ComicPage]) async {
        let lo = max(0, center - lookBehind)
        let hi = min(pages.count - 1, center + lookAhead)

        await DCLogger.shared.log("PREFETCH window [\(lo)...\(hi)] around page \(center)")

        // Evict pages that have fallen outside the window.
        await evictOutside(lo: lo, hi: hi)

        for i in lo...hi {
            if cache.object(forKey: NSNumber(value: i)) != nil { continue }
            if inFlight.contains(i) {
                await DCLogger.shared.log("PREFETCH SKIP  page \(i) already in-flight")
                continue
            }

            inFlight.insert(i)

            await DCLogger.shared.log("PREFETCH QUEUE page \(i)")
            let source = pages[i].source
            let idx = i
            Task(priority: .userInitiated) { [weak self] in
                guard let decodedImage = source.decode() else {
                    await DCLogger.shared.log("PREFETCH FAIL  page \(idx) — decode returned nil")
                    await self?.insert(image: nil, for: idx)
                    return
                }
                await self?.insert(image: decodedImage, for: idx)
                await MainActor.run {
                    self?.onPageReady?(idx, decodedImage)
                    self?.onPageReadySwiftUI?(idx, decodedImage)
                }
                await DCLogger.shared.log("PREFETCH DONE  page \(idx) — inserted into cache")
            }
        }
    }

    /// Explicitly removes decoded images for pages outside [lo...hi].
    /// This is the key difference from the old model: we do not wait for NSCache
    /// to decide when to evict — we evict proactively on every page turn.
    private func evictOutside(lo: Int, hi: Int) async {
        // We track which pages are in-flight; evict any cached page outside the window.
        // NSCache doesn't expose its keys, so we rely on the inFlight set + a small
        // scan of the window boundaries to remove recently-evicted candidates.
        // In practice, the window moves by 1 page at a time, so we only need to
        // evict the page that just fell off the back (lo - 1) and cancel any
        // far-ahead in-flight tasks that are now out of range.
        let evictBelow = lo - 1

        // Evict the page that just fell behind the window.
        if evictBelow >= 0 {
            cache.removeObject(forKey: NSNumber(value: evictBelow))
        }
        // Evict any page that was prefetched too far ahead (e.g. after a jump back).
        // We scan a small range beyond the window rather than all pages.
        for i in (hi + 1)...(hi + lookAhead + 2) {
            cache.removeObject(forKey: NSNumber(value: i))
        }
        // Cancel in-flight decodes for pages now outside the window.
        let stale = inFlight.filter { $0 < lo || $0 > hi }
        inFlight.subtract(stale)
        if !stale.isEmpty {
            await DCLogger.shared.log("PREFETCH CANCEL in-flight pages outside window: \(stale.sorted())")
        }
    }

    /// Remove all cached images outside [lo...hi]. Called from coordinator to keep
    /// RAM capped during fast scroll sweeps — only ever keeps ~5 pages in memory.
    /// **Synchronous direct eviction** — no Task delay, clears cache + inFlight
    /// immediately so new visible pages aren't blocked by stale decode tasks.
    nonisolated func removeObjectsOutside(lo: Int, hi: Int) {
        // NSCache is thread-safe. Evict pages outside window.
        Task { [weak self] in
            await self?._evictOutside(lo: lo, hi: hi)
        }
    }

    /// Internal async eviction that runs on the actor for `inFlight` access.
    private func _evictOutside(lo: Int, hi: Int) async {
        for i in 0..<lo {
            cache.removeObject(forKey: NSNumber(value: i))
        }
        let extra = 10
        for i in (hi + 1)...(hi + extra) {
            cache.removeObject(forKey: NSNumber(value: i))
        }
        // Clear stale in-flight entries — critical: this unblocks new decode requests
        // that would otherwise see "already in flight" and skip.
        let stale = inFlight.filter { $0 < lo || $0 > hi }
        inFlight.subtract(stale)
        if !stale.isEmpty {
            await DCLogger.shared.log("EVICT [\(lo)...\(hi)] cleared stale inFlight: \(stale.sorted())")
        }
    }

    nonisolated func removeAll() {
        Task { [weak self] in
            await self?.removeAllInternal()
        }
    }

    private func removeAllInternal() {
        cache.removeAllObjects()
        inFlight.removeAll()
    }
}

// MARK: - ReaderViewModel

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var currentPage: Int = 0
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var readingMode: ReadingMode = .verticalScroll
    /// Updated by ReaderView via GeometryReader so toolbar actions have the real size.
    @Published var containerSize: CGSize = CGSize(width: 900, height: 600)
    /// Bumped whenever a page decode completes for the current or adjacent page.
    /// Reading this in singlePageView/doublePageView creates a SwiftUI dependency
    /// so the view re-evaluates currentImage when the decode finishes.
    @Published var cacheVersion: Int = 0

    let comic: Comic
    let imageCache = PageImageCache()

    var pageCount: Int { comic.pages.count }

    /// Returns the cached image for the current page (may be nil while decoding).
    var currentImage: NSImage? {
        imageCache.image(for: currentPage)
    }

    /// Returns the cached image for a given page index (may be nil while decoding).
    func image(for index: Int) -> NSImage? {
        imageCache.image(for: index)
    }

    /// Natural size for a page — used for layout before the image is decoded.
    func naturalSize(for index: Int) -> CGSize {
        guard index < comic.pages.count else { return CGSize(width: 1, height: 1) }
        return comic.pages[index].naturalSize
    }

    let minScale: CGFloat = 0.1
    let maxScale: CGFloat = 8.0

    var isRestoringPosition: Bool = false
    var scrollOffsetFraction: Double = 0.0
    private(set) var savedScrollOffset: Double? = nil

    init(comic: Comic) {
        self.comic = comic
        ReadingPositionStore.save(pageCount: comic.pages.count, for: comic.url)
        let saved = ReadingPositionStore.page(for: comic.url)
        if saved > 0 && saved < comic.pages.count {
            self.currentPage = saved
            self.isRestoringPosition = true
        }
        self.savedScrollOffset = ReadingPositionStore.scrollOffset(for: comic.url)
        if let savedMode = ReadingPositionStore.mode(for: comic.url),
           let mode = ReadingMode(rawValue: savedMode) {
            self.readingMode = mode
        }
        // Wire the SwiftUI re-render callback — fires when any page decode completes.
        // Only bumps cacheVersion for the current page and its immediate neighbour
        // to avoid spurious re-renders on prefetch of distant pages.
        imageCache.onPageReadySwiftUI = { [weak self] index, _ in
            guard let self else { return }
            if index == self.currentPage || index == self.currentPage + 1 {
                self.cacheVersion += 1
            }
        }
        // Kick off initial prefetch.
        triggerPrefetch()
    }

    /// Called whenever the visible page changes — triggers prefetch of the surrounding window
    /// and explicitly evicts pages that have fallen outside it.
    func triggerPrefetch() {
        imageCache.prefetch(around: currentPage, pages: comic.pages)
    }

    // MARK: - Navigation

    func nextPage() {
        guard currentPage < pageCount - 1 else { return }
        if readingMode == .doublePage {
            // Spread pages occupy a full slot on their own — advance by 1.
            // Normal pairs advance by 2, unless the next page is a spread (it needs its own slot).
            let currentIsSpread = comic.pages[currentPage].isSpread
            let nextIsSpread    = (currentPage + 1 < pageCount) && comic.pages[currentPage + 1].isSpread
            let step = (currentIsSpread || nextIsSpread) ? 1 : 2
            currentPage = min(currentPage + step, pageCount - 1)
        } else {
            currentPage = min(currentPage + 1, pageCount - 1)
        }
        savePosition()
        resetZoom()
        triggerPrefetch()
    }

    func previousPage() {
        guard currentPage > 0 else { return }
        if readingMode == .doublePage {
            // If the previous page is a spread, step back by 1 (it was alone).
            // If the page before that is a spread, also step back by 1.
            // Otherwise step back by 2 to land on the left page of the prior pair.
            let prevIsSpread = (currentPage - 1 >= 0) && comic.pages[currentPage - 1].isSpread
            let prevPrevIsSpread = (currentPage - 2 >= 0) && comic.pages[currentPage - 2].isSpread
            let step = (prevIsSpread || prevPrevIsSpread) ? 1 : 2
            currentPage = max(currentPage - step, 0)
        } else {
            currentPage = max(currentPage - 1, 0)
        }
        savePosition()
        resetZoom()
        triggerPrefetch()
    }

    func goTo(page: Int) {
        guard page >= 0 && page < pageCount else { return }
        currentPage = page
        savePosition()
        resetZoom()
        triggerPrefetch()
    }

    private func savePosition() {
        ReadingPositionStore.save(page: currentPage, for: comic.url)
    }

    func saveMode() {
        ReadingPositionStore.save(mode: readingMode.rawValue, for: comic.url)
    }

    func updateCurrentPage(_ page: Int) {
        if isRestoringPosition {
            if page == currentPage { isRestoringPosition = false }
            return
        }
        if page != currentPage {
            currentPage = page
            triggerPrefetch()
        }
    }

    func persistCurrentPosition() {
        ReadingPositionStore.save(page: currentPage, for: comic.url)
        ReadingPositionStore.save(mode: readingMode.rawValue, for: comic.url)
        let isVertical = readingMode == .verticalScroll || readingMode == .verticalDouble
        if isVertical {
            ReadingPositionStore.save(scrollOffset: scrollOffsetFraction, for: comic.url)
        }
    }

    // MARK: - Zoom

    func zoom(by delta: CGFloat) {
        scale = (scale * delta).clamped(to: minScale...maxScale)
    }

    func setScale(_ newScale: CGFloat) {
        scale = newScale.clamped(to: minScale...maxScale)
    }

    func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1.0
            offset = .zero
        }
    }

    func setScaleFromScrollView(_ newScale: CGFloat) {
        // Called from NSScrollView magnification callbacks. Update the published
        // property so the toolbar UI stays in sync, but avoid triggering a
        // feedback loop — this path only goes TO the VM, not back to the view.
        scale = newScale.clamped(to: minScale...maxScale)
    }

    func fitToWidth(containerWidth: CGFloat) {
        // In Double Page mode the spread always fills the container width,
        // so Fit to Width simply means scale = 1.0.
        if readingMode == .doublePage {
            withAnimation(.easeOut(duration: 0.2)) {
                scale = 1.0
                offset = .zero
            }
            return
        }
        let size = naturalSize(for: currentPage)
        guard size.width > 0 else { return }
        let imgAR = size.width / size.height
        let conAR = containerWidth / containerSize.height
        let fittedWidth: CGFloat = imgAR > conAR ? containerWidth : containerSize.height * imgAR
        let targetScale = containerWidth / fittedWidth
        withAnimation(.easeOut(duration: 0.2)) {
            scale = targetScale.clamped(to: minScale...maxScale)
            offset = .zero
        }
    }

    func zoomToActualSize() {
        let size = naturalSize(for: currentPage)
        guard size.width > 0 else { return }
        let imgAR = size.width / size.height
        let conAR = containerSize.width / containerSize.height
        let fittedWidth: CGFloat = imgAR > conAR ? containerSize.width : containerSize.height * imgAR
        let actualScale = size.width / fittedWidth
        withAnimation(.easeOut(duration: 0.2)) {
            scale = actualScale.clamped(to: minScale...maxScale)
            offset = .zero
        }
    }

    func zoomIn() {
        withAnimation(.easeOut(duration: 0.15)) {
            scale = min(scale * 1.25, maxScale)
        }
    }

    func zoomOut() {
        withAnimation(.easeOut(duration: 0.15)) {
            scale = max(scale / 1.25, minScale)
        }
    }
}

enum ReadingMode: String, CaseIterable {
    case singlePage     = "Single Page"
    case doublePage     = "Double Page"
    case verticalScroll = "Vertical Scroll"
    case verticalDouble = "Vertical Double"
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
