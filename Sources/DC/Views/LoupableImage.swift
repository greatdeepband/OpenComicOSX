import SwiftUI
import AppKit

/// A plain image view with the right-click magnifier loupe attached.
/// Works correctly inside LazyVStack (no GeometryReader at the top level).
struct LoupableImage: View {
    let image: NSImage

    @State private var showLoupe: Bool = false
    @State private var loupePosition: CGPoint = .zero   // container coords
    @State private var renderedSize: CGSize = .zero     // actual rendered size

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            // Capture the rendered frame size via a background GeometryReader
            // (background doesn't affect layout, so LazyVStack gets the natural size).
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { renderedSize = geo.size }
                        .onChange(of: geo.size) { _, s in renderedSize = s }
                }
            )
            .overlay(loupeLayer)
    }

    @ViewBuilder
    private var loupeLayer: some View {
        ZStack {
            if showLoupe {
                MagnifierView(
                    image: image,
                    cursorInImageView: containerToImageCoords(loupePosition, containerSize: renderedSize),
                    imageViewSize: computeImageViewSize(containerSize: renderedSize)
                )
                .position(x: loupePosition.x, y: loupePosition.y)
                .allowsHitTesting(false)
            }

            RightClickCatcher(
                onBegan: { pos in loupePosition = pos; showLoupe = true },
                onMoved: { pos in loupePosition = pos },
                onEnded: { showLoupe = false }
            )
            .allowsHitTesting(true)
        }
    }

    private func computeImageViewSize(containerSize: CGSize) -> CGSize {
        let img = image.size
        guard img.width > 0, img.height > 0, containerSize.width > 0, containerSize.height > 0
        else { return containerSize }
        let imgAR = img.width / img.height
        let conAR = containerSize.width / containerSize.height
        return imgAR > conAR
            ? CGSize(width: containerSize.width, height: containerSize.width / imgAR)
            : CGSize(width: containerSize.height * imgAR, height: containerSize.height)
    }

    private func containerToImageCoords(_ point: CGPoint, containerSize: CGSize) -> CGPoint {
        let ivSize = computeImageViewSize(containerSize: containerSize)
        let ox = (containerSize.width  - ivSize.width)  / 2
        let oy = (containerSize.height - ivSize.height) / 2
        return CGPoint(x: point.x - ox, y: point.y - oy)
    }
}
