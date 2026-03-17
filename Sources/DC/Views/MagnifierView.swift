import SwiftUI
import AppKit

/// Circular magnifier loupe — renders a 1.3× crop of `image` centred on `cursorInImageView`.
///
/// Coordinate contract:
/// - `cursorInImageView`: point in the fitted-image's own coordinate space
///   (origin = top-left of the image as rendered on screen, in screen points).
/// - `imageViewSize`: the rendered size of the image on screen in screen points.
struct MagnifierView: View {
    let image: NSImage
    /// Cursor position in image-view space (screen points, top-left origin).
    let cursorInImageView: CGPoint
    /// Rendered size of the image on screen (screen points).
    let imageViewSize: CGSize

    private let loupeRadius: CGFloat = 90
    private let magnification: CGFloat = 1.3
    private let borderWidth: CGFloat = 2.5

    var body: some View {
        loupeContent
            .frame(width: loupeRadius * 2, height: loupeRadius * 2)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: borderWidth))
            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 3)
    }

    // Use NSImage drawing — avoids CGImage Retina scaling issues entirely.
    private var loupeContent: some View {
        Canvas { ctx, size in
            guard imageViewSize.width > 0, imageViewSize.height > 0 else { return }

            // How many screen-point pixels of the image fit in the loupe at this magnification.
            // loupeRadius*2 screen points show (loupeRadius*2 / magnification) image-view points.
            let srcW = (size.width  / magnification)
            let srcH = (size.height / magnification)

            // Source rect in image-view space (screen points, top-left origin).
            let srcRect = CGRect(
                x: cursorInImageView.x - srcW / 2,
                y: cursorInImageView.y - srcH / 2,
                width: srcW,
                height: srcH
            )

            // Clamp to image-view bounds so we don't sample outside the image.
            let ivBounds = CGRect(origin: .zero, size: imageViewSize)
            let clamped = srcRect.intersection(ivBounds)
            guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return }

            // Convert image-view-space rect → normalised (0…1) → NSImage source rect.
            // NSImage draws with bottom-left origin, so flip Y.
            let imgSize = image.size
            let normX = clamped.minX / imageViewSize.width
            let normY = clamped.minY / imageViewSize.height
            let normW = clamped.width  / imageViewSize.width
            let normH = clamped.height / imageViewSize.height

            // NSImage source rect (bottom-left origin)
            let imgSrcRect = CGRect(
                x: normX * imgSize.width,
                y: (1 - normY - normH) * imgSize.height,   // flip Y
                width:  normW * imgSize.width,
                height: normH * imgSize.height
            )

            // Destination fills the whole loupe canvas.
            let destRect = CGRect(origin: .zero, size: size)

            ctx.withCGContext { cgCtx in
                cgCtx.interpolationQuality = .high
                // Clip to circle again inside CGContext for crisp edges.
                cgCtx.addEllipse(in: destRect)
                cgCtx.clip()

                // Draw NSImage into CGContext using drawInRect — handles Retina correctly.
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
            }
        }
    }
}
