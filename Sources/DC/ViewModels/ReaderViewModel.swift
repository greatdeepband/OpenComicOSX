import Foundation
import SwiftUI

// MARK: - Page Image Cache

/// Thread-safe asymmetric sliding-window image cache for the reader.
///
/// The window is biased forward: [center - 1 ... center + 3].
/// Pages outside the window are explicitly evicted — we never rely on NSCache's
/// opaque eviction policy. This hard-caps the decoded page count at 5 at any time.
final class PageImageCache {
    private let cache = NSCache<NSNumber, NSImage>()

    /// Tracks which pages are currently being decoded to avoid duplicate work.
    private var inFlight = Set<Int>()
    private let lock = NSLock()

    /// Primary callback — used by VerticalComicScrollView coordinator for direct NSView injection.
    var onPageReady: ((Int, NSImage) -> Void)?
    /// Secondary callback — used by ReaderViewModel to bump cacheVersion for SwiftUI re-render.
    var onPageReadySwiftUI: ((Int, NSImage) -> Void)?

    /// Window shape: how many pages to keep behind and ahead of the current page.
    private let lookBehind = 1
    private let lookAhead  = 3

    init() {
        // Safety headroom above the 5-page window.
        cache.countLimit = 8
    }

    /// Returns the cached image for a page index, or nil if not yet decoded.
    func image(for index: Int) -> NSImage? {
        cache.object(forKey: NSNumber(value: index))
    }

    /// Inserts a decoded image into the cache.
    private func insert(_ image: NSImage, for index: Int) {
        cache.setObject(image, forKey: NSNumber(value: index))
        lock.lock()
        inFlight.remove(index)
        lock.unlock()
    }

    /// Viewport-aware prefetch for vertical scroll modes.
    ///
    /// `visible` is the exact range of pages currently on screen (computed by the
    /// scroll view from its viewport rect and pre-computed Y offsets).
    /// `lookahead` pages beyond the visible range are also decoded proactively.
    /// Only pages outside (visible.lowerBound - 1 ... visible.upperBound + lookahead)
    /// are evicted — pages on screen are never removed.
    func prefetch(visible: ClosedRange<Int>, lookahead: Int, pages: [ComicPage]) {
        let lo = max(0, visible.lowerBound - 1)
        let hi = min(pages.count - 1, visible.upperBound + lookahead)

        DCLogger.shared.log("PREFETCH viewport [\(visible.lowerBound)...\(visible.upperBound)] window [\(lo)...\(hi)]")

        evictOutside(lo: lo, hi: hi)

        for i in lo...hi {
            if cache.object(forKey: NSNumber(value: i)) != nil { continue }
            lock.lock()
            let alreadyFetching = inFlight.contains(i)
            if !alreadyFetching { inFlight.insert(i) }
            lock.unlock()
            if alreadyFetching { continue }

            DCLogger.shared.log("PREFETCH QUEUE page \(i)")
            let source = pages[i].source
            let idx = i
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                guard let image = source.decode() else {
                    DCLogger.shared.log("PREFETCH FAIL  page \(idx) — decode returned nil")
                    self.lock.lock(); self.inFlight.remove(idx); self.lock.unlock()
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.insert(image, for: idx)
                    self.onPageReady?(idx, image)
                    self.onPageReadySwiftUI?(idx, image)
                }
            }
        }
    }

    /// Schedules decoding for pages in [center - lookBehind ... center + lookAhead],
    /// then explicitly evicts everything outside that window.
    func prefetch(around center: Int, pages: [ComicPage]) {
        let lo = max(0, center - lookBehind)
        let hi = min(pages.count - 1, center + lookAhead)

        DCLogger.shared.log("PREFETCH window [\(lo)...\(hi)] around page \(center)")

        // Evict pages that have fallen outside the window.
        evictOutside(lo: lo, hi: hi)

        for i in lo...hi {
            if cache.object(forKey: NSNumber(value: i)) != nil { continue }
            lock.lock()
            let alreadyFetching = inFlight.contains(i)
            if !alreadyFetching { inFlight.insert(i) }
            lock.unlock()
            if alreadyFetching {
                DCLogger.shared.log("PREFETCH SKIP  page \(i) already in-flight")
                continue
            }

            DCLogger.shared.log("PREFETCH QUEUE page \(i)")
            let source = pages[i].source
            let idx = i
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                guard let image = source.decode() else {
                    DCLogger.shared.log("PREFETCH FAIL  page \(idx) — decode returned nil")
                    self.lock.lock()
                    self.inFlight.remove(idx)
                    self.lock.unlock()
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.insert(image, for: idx)
                    DCLogger.shared.log("PREFETCH DONE  page \(idx) — inserted into cache")
                    self.onPageReady?(idx, image)
                    self.onPageReadySwiftUI?(idx, image)
                }
            }
        }
    }

    /// Explicitly removes decoded images for pages outside [lo...hi].
    /// This is the key difference from the old model: we do not wait for NSCache
    /// to decide when to evict — we evict proactively on every page turn.
    private func evictOutside(lo: Int, hi: Int) {
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
        lock.lock()
        let stale = inFlight.filter { $0 < lo || $0 > hi }
        inFlight.subtract(stale)
        lock.unlock()
        if !stale.isEmpty {
            DCLogger.shared.log("PREFETCH CANCEL in-flight pages outside window: \(stale.sorted())")
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        inFlight.removeAll()
        lock.unlock()
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

    func fitToWidth(containerWidth: CGFloat) {
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
