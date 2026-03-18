import Foundation
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var currentPage: Int = 0
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var readingMode: ReadingMode = .singlePage
    /// Updated by ReaderView via GeometryReader so toolbar actions have the real size.
    @Published var containerSize: CGSize = CGSize(width: 900, height: 600)

    let comic: Comic

    var pageCount: Int { comic.pages.count }
    var currentImage: NSImage? {
        guard currentPage < comic.pages.count else { return nil }
        return comic.pages[currentPage].image
    }

    let minScale: CGFloat = 0.1
    let maxScale: CGFloat = 8.0

    init(comic: Comic) {
        self.comic = comic
    }

    // MARK: - Navigation

    func nextPage() {
        let step = readingMode == .doublePage ? 2 : 1
        guard currentPage < pageCount - 1 else { return }
        currentPage = min(currentPage + step, pageCount - 1)
        resetZoom()
    }

    func previousPage() {
        let step = readingMode == .doublePage ? 2 : 1
        guard currentPage > 0 else { return }
        currentPage = max(currentPage - step, 0)
        resetZoom()
    }

    func goTo(page: Int) {
        guard page >= 0 && page < pageCount else { return }
        currentPage = page
        resetZoom()
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

    /// Scales so the image width fills the container width exactly.
    func fitToWidth(containerWidth: CGFloat) {
        guard let img = currentImage, img.size.width > 0 else { return }
        // ZoomableImageView uses scaledToFit inside the container.
        // scale=1 means the image is already fitted to the container.
        // To fill the width we need to find what scale makes the fitted image
        // expand to fill the full width.
        let imgAR = img.size.width / img.size.height
        let conAR = containerWidth / containerSize.height
        // At scale=1 the fitted width is:
        let fittedWidth: CGFloat = imgAR > conAR
            ? containerWidth                          // image is wider — already fills width
            : containerSize.height * imgAR            // image is taller — fitted width < container
        let targetScale = containerWidth / fittedWidth
        withAnimation(.easeOut(duration: 0.2)) {
            scale = targetScale.clamped(to: minScale...maxScale)
            offset = .zero
        }
    }

    /// 1 image pixel = 1 screen point.
    func zoomToActualSize() {
        guard let img = currentImage, img.size.width > 0 else { return }
        // At scale=1 the image is fitted to the container.
        // Actual size means the image renders at its natural point size.
        let imgAR = img.size.width / img.size.height
        let conAR = containerSize.width / containerSize.height
        let fittedWidth: CGFloat = imgAR > conAR
            ? containerSize.width
            : containerSize.height * imgAR
        // Scale needed so fittedWidth * scale == img.size.width
        let actualScale = img.size.width / fittedWidth
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
    case singlePage    = "Single Page"
    case doublePage    = "Double Page"
    case verticalScroll = "Vertical Scroll"
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
