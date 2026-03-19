import SwiftUI
import AppKit

/// Wraps VerticalComicScrollView with a single MouseCatcher overlay that handles
/// the right-click loupe for all vertical reading modes.
///
/// This replaces the old per-page AppKit notification system (loupeBegan/loupeMoved/loupeEnded)
/// with the same MouseCatcher + MagnifierView pattern used by SpreadView.
/// All coordinates stay in SwiftUI space — no manual Y-flip, no cached overlay frames.
struct VerticalScrollWithLoupe: View {
    let pages: [ComicPage]
    let pagesPerRow: Int
    let scale: CGFloat
    let containerSize: CGSize
    let savedScrollOffset: Double?
    var onPageChanged: (Int) -> Void
    var onOffsetChanged: (Double) -> Void
    /// Called with a multiplicative factor (e.g. 1.05 or 0.95) when the scroll wheel fires.
    var onScaleChange: (CGFloat) -> Void

    @State private var showLoupe = false
    @State private var loupePosition: CGPoint = .zero
    @State private var loupeImage: NSImage? = nil
    @State private var loupeImageViewSize: CGSize = .zero
    @State private var loupeCursorInImage: CGPoint = .zero

    // Hold a reference to the coordinator so the MouseCatcher can call hitTestPage.
    @State private var scrollCoordinator: VerticalComicScrollView.Coordinator? = nil

    var body: some View {
        ZStack {
            VerticalComicScrollView(
                pages: pages,
                pagesPerRow: pagesPerRow,
                scale: scale,
                containerWidth: containerSize.width,
                restoreOffset: savedScrollOffset,
                onPageChanged: onPageChanged,
                onOffsetChanged: onOffsetChanged,
                onCoordinatorReady: { coordinator in
                    // Capture the coordinator so the MouseCatcher can call hitTestPage.
                    scrollCoordinator = coordinator
                }
            )
            .onScrollWheel { event in
                let factor: CGFloat = event.deltaY > 0 ? 0.95 : 1.05
                onScaleChange(factor)
            }

            // Loupe display — rendered above the scroll view, no hit testing.
            if showLoupe, let img = loupeImage {
                MagnifierView(
                    image: img,
                    cursorInImageView: loupeCursorInImage,
                    imageViewSize: loupeImageViewSize
                )
                .position(x: loupePosition.x, y: loupePosition.y)
                .allowsHitTesting(false)
            }

            // Single MouseCatcher covers the entire scroll view.
            // Right-click events arrive in SwiftUI coordinates (top-left origin, Y already flipped
            // by _MouseCatcherView.swiftPt). No AppKit coordinate conversion needed.
            MouseCatcher(
                onLeftDragBegan: { _ in },
                onLeftDragMoved: { _ in },   // scrolling handled natively by NSScrollView
                onLeftDragEnded: { _ in },
                onRightBegan: { pos in
                    loupePosition = pos
                    updateLoupe(at: pos)
                    showLoupe = true
                },
                onRightMoved: { pos in
                    loupePosition = pos
                    updateLoupe(at: pos)
                },
                onRightEnded: { showLoupe = false }
            )
            .allowsHitTesting(true)
        }
    }

    // MARK: - Loupe hit test

    /// Maps a SwiftUI-space cursor position to the page under the cursor and
    /// computes the loupe parameters for MagnifierView.
    ///
    /// The MouseCatcher delivers positions in SwiftUI coordinates: origin at the
    /// top-left of the scroll view's visible area, Y increasing downward.
    /// VerticalComicScrollView.hitTestPage() expects the same coordinate space,
    /// so no conversion is needed here.
    private func updateLoupe(at pos: CGPoint) {
        guard let coordinator = scrollCoordinator else { return }

        // Build a temporary VerticalComicScrollView value to call hitTestPage.
        // This is a pure value-type call — no view creation.
        let scrollView = VerticalComicScrollView(
            pages: pages,
            pagesPerRow: pagesPerRow,
            scale: scale,
            containerWidth: containerSize.width,
            restoreOffset: nil,
            onPageChanged: { _ in },
            onOffsetChanged: { _ in },
            onCoordinatorReady: { _ in }
        )

        guard let result = scrollView.hitTestPage(at: pos, coordinator: coordinator) else { return }

        loupeImage         = result.image
        loupeImageViewSize = result.imageViewSize
        loupeCursorInImage = result.cursorInImageView
    }
}
