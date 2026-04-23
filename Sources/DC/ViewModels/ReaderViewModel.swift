import Foundation
import SwiftUI

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
    /// Shared decode cache for every reading mode (single, double, vertical,
    /// vertical-double). Owns both the CVPixelBuffer ring and the NSImage
    /// fast-path cache. Injected into `MetalPageView` so vertical modes use
    /// the same instance the single/double path reads from.
    let pageManager = MetalPageManager()

    var pageCount: Int { comic.pages.count }

    /// Returns the cached image for the current page (may be nil while decoding).
    var currentImage: NSImage? {
        pageManager.nsImage(for: currentPage)
    }

    /// Returns the cached image for a given page index (may be nil while decoding).
    func image(for index: Int) -> NSImage? {
        pageManager.nsImage(for: index)
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
        pageManager.onPageReadyNSImage = { [weak self] index, _ in
            guard let self = self else { return }
            // Only bump for pages SwiftUI is actively rendering — the current
            // page, and the current + 1 slot for double-page mode. Prefetched
            // far-neighbours should not trigger re-renders.
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
        pageManager.prefetch(around: currentPage, pages: comic.pages)
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
