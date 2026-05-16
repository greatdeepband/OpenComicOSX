import Foundation
import SwiftUI

// MARK: - ReaderViewModel

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var currentPage: Int = 0
    @Published var scale: CGFloat = 1.0
    @Published var readingMode: ReadingMode = .singlePage
    /// Updated by ReaderView via GeometryReader so toolbar actions have the real size.
    @Published var containerSize: CGSize = CGSize(width: 900, height: 600)

    let comic: Comic
    /// Shared decode cache for every reading mode (single, double, vertical,
    /// vertical-double). Owns both the CVPixelBuffer ring and the NSImage
    /// fast-path cache. Injected into `MetalPageView` so all modes use one
    /// decode pipeline.
    let pageManager = MetalPageManager()

    var pageCount: Int { comic.pages.count }

    /// Natural size for a page — used for layout before the image is decoded.
    func naturalSize(for index: Int) -> CGSize {
        guard index < comic.pages.count else { return CGSize(width: 1, height: 1) }
        return comic.pages[index].naturalSize
    }

    let minScale: CGFloat = ReaderConstants.nativeMagnificationMin
    let maxScale: CGFloat = ReaderConstants.nativeMagnificationMax

    var isRestoringPosition: Bool = false
    var scrollOffsetFraction: Double = 0.0
    /// pagesPerRow the live `scrollOffsetFraction` was last computed against.
    /// Vertical-single (1) and vertical-double (2) have very different doc
    /// heights, so a fraction saved in one is meaningless in the other —
    /// applying it would jump the user to a wrong page on mode switch.
    var scrollOffsetPagesPerRow: Int = 1
    private(set) var savedScrollOffset: Double? = nil

    /// Background task that decodes a low-res thumbnail for every page in
    /// the comic. Used as the render-path placeholder when full-res isn't
    /// ready. Fired on init, runs at `.background` priority so foreground
    /// per-visible-range prefetch keeps actor priority. Cancelled on
    /// deinit (comic close).
    private var preScanTask: Task<Void, Never>?

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
        // Kick off initial prefetch. All four reading modes drive their own
        // re-renders via MetalPageView's onTextureReady callback path; no
        // SwiftUI cache-version bump is needed here.
        triggerPrefetch()

        // Background thumbnail pre-scan. Decodes a low-res placeholder for
        // every page so the render path can show a blurry-but-legible
        // preview when full-res decode hasn't caught up to a fast scroll.
        // Detached at `.background` priority — foreground prefetch retains
        // actor priority via `Task.yield()` calls inside `preScanThumbnails`.
        let manager = pageManager
        let pagesSnapshot = comic.pages
        preScanTask = Task.detached(priority: .background) {
            await manager.preScanThumbnails(pages: pagesSnapshot)
        }
    }

    deinit {
        preScanTask?.cancel()
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
        }
    }

    func zoomIn() {
        withAnimation(.easeOut(duration: ReaderConstants.zoomAnimationDuration)) {
            scale = min(scale * ReaderConstants.wheelZoomStep, maxScale)
        }
    }

    func zoomOut() {
        withAnimation(.easeOut(duration: ReaderConstants.zoomAnimationDuration)) {
            scale = max(scale / ReaderConstants.wheelZoomStep, minScale)
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
