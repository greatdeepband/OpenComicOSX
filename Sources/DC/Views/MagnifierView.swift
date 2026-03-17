import SwiftUI
import AppKit

/// A circular magnifier loupe that renders a 1.3× crop of the source image
/// centred on the cursor position. Activated by right-click hold.
struct MagnifierView: View {
    let image: NSImage
    /// Cursor position in the coordinate space of the image view (0…viewSize).
    let cursorPosition: CGPoint
    /// The rendered size of the image on screen (after scale/fit).
    let imageViewSize: CGSize
    /// Current reader zoom scale — used to map screen coords back to image coords.
    let readerScale: CGFloat

    // Loupe appearance
    private let loupeRadius: CGFloat = 90
    private let magnification: CGFloat = 1.3
    private let borderWidth: CGFloat = 2.5
    private let shadowRadius: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            // 1. Clip to circle
            let circle = Path(ellipseIn: CGRect(origin: .zero, size: size))
            ctx.clip(to: circle)

            // 2. Compute the source rect in image pixels
            let imgSize = image.size
            guard imgSize.width > 0, imgSize.height > 0,
                  imageViewSize.width > 0, imageViewSize.height > 0 else { return }

            // Scale factors: screen pixels → image pixels
            let scaleX = imgSize.width  / imageViewSize.width
            let scaleY = imgSize.height / imageViewSize.height

            // Centre of the loupe in image-pixel space
            let imgCX = cursorPosition.x * scaleX
            let imgCY = cursorPosition.y * scaleY

            // How many image pixels fit inside the loupe at magnification
            let srcW = (loupeRadius * 2) / magnification * scaleX
            let srcH = (loupeRadius * 2) / magnification * scaleY

            let srcRect = CGRect(
                x: imgCX - srcW / 2,
                y: imgCY - srcH / 2,
                width: srcW,
                height: srcH
            )

            // 3. Draw the cropped region stretched to fill the loupe
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Flip coordinate system (NSImage is flipped vs CGImage)
                ctx.withCGContext { cgCtx in
                    cgCtx.saveGState()
                    cgCtx.translateBy(x: 0, y: size.height)
                    cgCtx.scaleBy(x: 1, y: -1)

                    let destRect = CGRect(origin: .zero, size: size)

                    // Clamp srcRect to image bounds
                    let imgBounds = CGRect(origin: .zero, size: imgSize)
                    let clampedSrc = srcRect.intersection(imgBounds)
                    guard !clampedSrc.isNull else {
                        cgCtx.restoreGState()
                        return
                    }

                    if let cropped = cgImage.cropping(to: clampedSrc) {
                        cgCtx.interpolationQuality = .high
                        cgCtx.draw(cropped, in: destRect)
                    }
                    cgCtx.restoreGState()
                }
            }
        }
        .frame(width: loupeRadius * 2, height: loupeRadius * 2)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.85), lineWidth: borderWidth)
        )
        .shadow(color: .black.opacity(0.45), radius: shadowRadius, x: 0, y: 3)
    }
}
