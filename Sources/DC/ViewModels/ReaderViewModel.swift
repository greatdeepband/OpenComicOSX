import Foundation
import SwiftUI

// MARK: - Page Image Cache

/// Thread-safe sliding-window image cache for the reader.
/// Holds at most `countLimit` decoded pages. NSCache evicts automatically under memory pressure.
final class PageImageCache {
    private let cache = NSCache<NSNumber, NSImage>()
    private let windowSize: Int

    /// Tracks which pages are currently being decoded to avoid duplicate work.
    private var inFlight = Set<Int>()
    private let lock = NSLock()

    init(windowSize: Int = 10) {
        self.windowSize = windowSize
        cache.countLimit = windowSize * 2   // a bit of headroom
    }

    /// Returns the cached image for a page index, or nil if not yet decoded.
    func image(for index: Int) -> NSImage? {
        cache.object(forKey: NSNumber(value: index))
    }

    /// Inserts a decoded image into the cache.
    func insert(_ image: NSImage, for index: Int) {
        cache.setObject(image, forKey: NSNumber(value: index))
        lock.lock()
        inFlight.remove(index)
        lock.unlock()
    }

    /// Asynchronously decodes pages in the window [center-half ... center+half].
    /// Calls `onReady(index)` on the main thread when a page becomes available.
    func prefetch(around center: Int, pages: [ComicPage], onReady: @escaping (Int) -> Void) {
        let half = windowSize / 2
        let lo = max(0, center - half)
        let hi = min(pages.count - 1, center + half)

        for i in lo...hi {
            guard cache.object(forKey: NSNumber(value: i)) == nil else { continue }
            lock.lock()
            let alreadyFetching = inFlight.contains(i)
            if !alreadyFetching { inFlight.insert(i) }
            lock.unlock()
            guard !alreadyFetching else { continue }

            let source = pages[i].source
            let idx = i
            Task.detached(priority: .userInitiated) {
                guard let image = source.decode() else { return }
                await MainActor.run {
                    self.insert(image, for: idx)
                    onReady(idx)
                }
            }
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
    /// Fires when a page image becomes available in the cache (triggers view refresh).
    @Published var cacheVersion: Int = 0

    let comic: Comic
    let imageCache = PageImageCache(windowSize: 10)

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
    var scrollContentHeight: CGFloat = 0.0
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
        // Kick off initial prefetch.
        triggerPrefetch()
    }

    /// Called whenever the visible page changes — triggers prefetch of the surrounding window.
    func triggerPrefetch() {
        imageCache.prefetch(around: currentPage, pages: comic.pages) { [weak self] _ in
            self?.cacheVersion += 1
        }
    }

    // MARK: - Navigation

    func nextPage() {
        let step = readingMode == .doublePage ? 2 : 1
        guard currentPage < pageCount - 1 else { return }
        currentPage = min(currentPage + step, pageCount - 1)
        savePosition()
        resetZoom()
        triggerPrefetch()
    }

    func previousPage() {
        let step = readingMode == .doublePage ? 2 : 1
        guard currentPage > 0 else { return }
        currentPage = max(currentPage - step, 0)
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
