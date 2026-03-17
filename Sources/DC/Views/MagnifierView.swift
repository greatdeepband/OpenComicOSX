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

    private let loupeRadius: CGFloat = 180   // 2× the original 90
    private let magnification: CGFloat = 1.3
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

            // Source rect in image-view space (top-left origin, screen points).
            let srcRect = CGRect(
                x: cursorInImageView.x - srcW / 2,
                y: cursorInImageView.y - srcH / 2,
                width: srcW,
                height: srcH
            )

            // Clamp to image-view bounds.
            let ivBounds = CGRect(origin: .zero, size: imageViewSize)
            let clamped = srcRect.intersection(ivBounds)
            guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return }

            // Convert image-view-space rect → NSImage source rect.
            // NSImage.size is in points with bottom-left origin.
            // image-view top-left origin → NSImage bottom-left origin: flip Y.
            let imgSize = image.size
            let normX = clamped.minX / imageViewSize.width
            let normY = clamped.minY / imageViewSize.height   // top-left Y
            let normW = clamped.width  / imageViewSize.width
            let normH = clamped.height / imageViewSize.height

            // NSImage Y: 0 = bottom. Top-left normY → bottom-left = (1 - normY - normH).
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

                // NSImage.draw uses the CGContext's coordinate system.
                // CGContext inside Canvas has top-left origin (SwiftUI flips it).
                // We need to flip the CGContext to bottom-left so NSImage draws right-side up.
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
