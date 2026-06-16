import SwiftUI
import AppKit

/// Circular magnifier loupe — renders a 1.45× crop of `image` centred on `cursorInImageView`.
/// When the cursor is near or past the image edge the loupe shows black for the out-of-bounds area.
struct MagnifierView: View {
    let image: NSImage
    let cursorInImageView: CGPoint
    let imageViewSize: CGSize

    private let magnification: CGFloat = 1.45
    private let borderWidth: CGFloat = 3.0

    var body: some View {
        loupeContent
            .frame(width: ReaderConstants.loupeRadius * 2, height: ReaderConstants.loupeRadius * 2)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: borderWidth))
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
    }

    private var loupeContent: some View {
        Canvas { ctx, size in
            // Always paint the background black before attempting any
            // image draw — when the cursor strays far enough off the
            // page that the source rect doesn't intersect the image
            // bounds, the early-return below would otherwise leave the
            // Canvas transparent and the loupe ring would render as a
            // hollow shadow over whatever's beneath it.
            ctx.withCGContext { cgCtx in
                cgCtx.setFillColor(CGColor(gray: 0, alpha: 1))
                cgCtx.fill(CGRect(origin: .zero, size: size))
            }

            guard imageViewSize.width > 0, imageViewSize.height > 0 else { return }

            let srcW = size.width  / magnification
            let srcH = size.height / magnification
            let halfW = srcW / 2
            let halfH = srcH / 2

            // No clamping — use the raw cursor position.
            // The source rect may extend outside the image bounds; the out-of-bounds
            // portion simply won't be drawn, leaving the canvas background (black).
            let srcRect = CGRect(
                x: cursorInImageView.x - halfW,
                y: cursorInImageView.y - halfH,
                width: srcW,
                height: srcH
            )

            // Intersect with image bounds to get the drawable portion.
            let ivBounds = CGRect(origin: .zero, size: imageViewSize)
            let visible = srcRect.intersection(ivBounds)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

            // Map the visible portion of the source rect to normalised image coords.
            let imgSize = image.size
            let normX = visible.minX / imageViewSize.width
            let normY = visible.minY / imageViewSize.height
            let normW = visible.width  / imageViewSize.width
            let normH = visible.height / imageViewSize.height

            // NSImage uses bottom-left origin — flip Y.
            let imgSrcRect = CGRect(
                x: normX * imgSize.width,
                y: (1.0 - normY - normH) * imgSize.height,
                width:  normW * imgSize.width,
                height: normH * imgSize.height
            )

            // Map the visible source portion to the corresponding destination rect
            // inside the loupe canvas, preserving spatial alignment.
            let scaleX = size.width  / srcW
            let scaleY = size.height / srcH
            let destRect = CGRect(
                x: (visible.minX - srcRect.minX) * scaleX,
                y: (visible.minY - srcRect.minY) * scaleY,
                width:  visible.width  * scaleX,
                height: visible.height * scaleY
            )

            ctx.withCGContext { cgCtx in
                cgCtx.interpolationQuality = .high
                cgCtx.addEllipse(in: CGRect(origin: .zero, size: size))
                cgCtx.clip()

                // Canvas CGContext has top-left origin; NSImage.draw needs bottom-left.
                cgCtx.saveGState()
                cgCtx.translateBy(x: 0, y: size.height)
                cgCtx.scaleBy(x: 1, y: -1)

                // Flip destRect Y to match the flipped context.
                let flippedDest = CGRect(
                    x: destRect.minX,
                    y: size.height - destRect.maxY,
                    width: destRect.width,
                    height: destRect.height
                )

                NSGraphicsContext.saveGraphicsState()
                let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
                NSGraphicsContext.current = nsCtx
                image.draw(
                    in: flippedDest,
                    from: imgSrcRect,
                    operation: .copy,
                    fraction: 1.0,
                    respectFlipped: false,
                    hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
                )
                NSGraphicsContext.restoreGraphicsState()
                cgCtx.restoreGState()
            }
        }
    }
}
