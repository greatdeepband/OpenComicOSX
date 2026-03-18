import SwiftUI
import AppKit

/// A plain image view with the right-click magnifier loupe attached.
/// Drop-in replacement for `Image(nsImage:)` wherever the loupe is needed.
struct LoupableImage: View {
    let image: NSImage

    @State private var showLoupe: Bool = false
    @State private var loupePosition: CGPoint = .zero   // container coords

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                if showLoupe {
                    MagnifierView(
                        image: image,
                        cursorInImageView: containerToImageCoords(loupePosition, containerSize: geo.size),
                        imageViewSize: computeImageViewSize(containerSize: geo.size)
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
    }

    private func computeImageViewSize(containerSize: CGSize) -> CGSize {
        let img = image.size
        guard img.width > 0, img.height > 0 else { return containerSize }
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
