import SwiftUI
import AppKit

/// Circular magnifier loupe — renders a 1.3× crop of `image` centred on `cursorInImageView`.
///
/// Coordinate contract:
/// - `cursorInImageView`: point in image-view space (screen points, top-left origin).
/// - `imageViewSize`: rendered size of the image on screen (screen points).
struct MagnifierView: View {
    let image: NSImage
    let cursorInImageView: CGPoint
    let imageViewSize: CGSize

    private let loupeRadius: CGFloat = 270
    private let magnification: CGFloat = 1.45
    private let borderWidth: CGFloat = 3.0

    var body: some View {
        loupeContent
            .frame(width: loupeRadius * 2, height: loupeRadius * 2)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: borderWidth))
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
    }

    private var loupeContent: some View {
        Canvas { ctx, size in
            guard imageViewSize.width > 0, imageViewSize.height > 0 else { return }

            // How many image-view points fit inside the loupe at this magnification.
            let srcW = size.width  / magnification
            let srcH = size.height / magnification
            let halfW = srcW / 2
            let halfH = srcH / 2

            // Clamp the CENTRE so the full srcW×srcH window always stays inside the image.
            // This prevents the source rect from going out of bounds, which would cause
            // the clamped (smaller) region to be stretched across the full loupe circle.
            let clampedCX = cursorInImageView.x.clamped(to: halfW...(imageViewSize.width  - halfW))
            let clampedCY = cursorInImageView.y.clamped(to: halfH...(imageViewSize.height - halfH))

            let srcRect = CGRect(
                x: clampedCX - halfW,
                y: clampedCY - halfH,
                width: srcW,
                height: srcH
            )

            // Convert image-view-space rect → NSImage source rect.
            // NSImage uses bottom-left origin, so flip Y.
            let imgSize = image.size
            let normX = srcRect.minX / imageViewSize.width
            let normY = srcRect.minY / imageViewSize.height
            let normW = srcRect.width  / imageViewSize.width
            let normH = srcRect.height / imageViewSize.height

            let imgSrcRect = CGRect(
                x: normX * imgSize.width,
                y: (1.0 - normY - normH) * imgSize.height,
                width:  normW * imgSize.width,
                height: normH * imgSize.height
            )

            let destRect = CGRect(origin: .zero, size: size)

            ctx.withCGContext { cgCtx in
                cgCtx.interpolationQuality = .high
                cgCtx.addEllipse(in: destRect)
                cgCtx.clip()

                // Canvas CGContext has top-left origin; NSImage.draw needs bottom-left.
                cgCtx.saveGState()
                cgCtx.translateBy(x: 0, y: size.height)
                cgCtx.scaleBy(x: 1, y: -1)

                NSGraphicsContext.saveGraphicsState()
                let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
                NSGraphicsContext.current = nsCtx
                image.draw(
                    in: destRect,
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
