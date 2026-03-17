import Foundation
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var currentPage: Int = 0
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var readingMode: ReadingMode = .singlePage

    let comic: Comic

    var pageCount: Int { comic.pages.count }
    var currentImage: NSImage? {
        guard currentPage < comic.pages.count else { return nil }
        return comic.pages[currentPage].image
    }

    // Zoom limits
    let minScale: CGFloat = 0.5
    let maxScale: CGFloat = 8.0

    init(comic: Comic) {
        self.comic = comic
    }

    // MARK: - Navigation

    func nextPage() {
        guard currentPage < pageCount - 1 else { return }
        currentPage += 1
        resetZoom()
    }

    func previousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        resetZoom()
    }

    func goTo(page: Int) {
        guard page >= 0 && page < pageCount else { return }
        currentPage = page
        resetZoom()
    }

    // MARK: - Zoom

    func zoom(by delta: CGFloat, anchor: CGPoint = .zero) {
        let newScale = (scale * delta).clamped(to: minScale...maxScale)
        scale = newScale
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
        guard let img = currentImage else { return }
        let imgWidth = img.size.width
        guard imgWidth > 0 else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            scale = (containerWidth / imgWidth).clamped(to: minScale...maxScale)
            offset = .zero
        }
    }

    func zoomToActualSize() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1.0
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
    case singlePage = "Single Page"
    case doublePage = "Double Page"
    case verticalScroll = "Vertical Scroll"
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
