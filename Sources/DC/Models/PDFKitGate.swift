import Foundation
import CoreGraphics
import CoreVideo
import PDFKit

/// Process-wide serialization gate for **all** PDFKit access.
///
/// PDFKit (`PDFDocument` / `PDFPage`) is not thread-safe — neither across a
/// single document nor reliably across distinct documents that share PDFKit's
/// internal global state. The reader previously touched it from three
/// concurrent contexts: the full-res page decode (`MetalPageManager.decodePDFPage`),
/// the parallel thumbnail pre-scan (`MetalPageManager.preScanThumbnails`'
/// `withTaskGroup`), and cover loads (`ComicLoader.loadCoverPDF`). Those calls
/// could overlap and corrupt PDFKit state or crash.
///
/// `PDFKitGate` is an `actor`, so every method body runs on the actor's
/// serial executor: only one PDFKit operation is ever in flight at a time,
/// process-wide. The PDF thumbnail pre-scan therefore becomes effectively
/// serial — that is the intended, accepted trade-off for correctness.
///
/// **LEAF-ONLY invariant:** this actor must NEVER call back into
/// `MetalPageManager` (or any other actor that might `await` the gate),
/// otherwise a re-entrant deadlock becomes possible. It owns only pure
/// PDFKit + CoreGraphics work over its inputs.
actor PDFKitGate {
    static let shared = PDFKitGate()

    private init() {}

    /// Renders a single PDF page into a fresh BGRA `CVPixelBuffer`.
    ///
    /// Body moved verbatim from `MetalPageManager.decodePDFPage` so the
    /// `page.draw(with:.mediaBox, to:)` call happens inside the actor. The
    /// pixel format (`kCVPixelFormatType_32BGRA`), the premultipliedFirst /
    /// byteOrder32Little `CGContext`, the white opaque background, and the
    /// 2× Retina scale capped to `ReaderConstants.maxTextureDimension` all
    /// match the original.
    ///
    /// `pixelSize` is the caller's requested buffer size (the full-res decode
    /// passes the same 2×, capped size it used to compute inline). It is
    /// re-clamped here defensively so an oversized request can never produce a
    /// buffer/texture above the Metal limit.
    func renderPage(_ doc: PDFDocument, index: Int, pixelSize: CGSize) -> CVPixelBuffer? {
        guard let page = doc.page(at: index) else { return nil }
        let mediaBox = page.bounds(for: .mediaBox)

        // Clamp the requested size to the Metal texture limit so an unusually
        // large request can't produce an oversized buffer/texture (which
        // SIGABRTs in makeTexture).
        let capped = Self.cappedSize(width: Int(pixelSize.width.rounded()),
                                     height: Int(pixelSize.height.rounded()),
                                     maxDimension: Int(ReaderConstants.maxTextureDimension))
        let width = max(1, capped.width)
        let height = max(1, capped.height)
        // Effective scale after clamping — keeps the page drawn to fill the
        // (possibly reduced) buffer instead of being cropped.
        let scale = CGFloat(width) / max(mediaBox.width, 1)

        guard let buffer = Self.makePixelBuffer(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // White background (PDFs are opaque pages; the transparent pixel
        // buffer would otherwise show the reader's black behind clear areas).
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return buffer
    }

    /// Renders a low-resolution thumbnail for a PDF page.
    ///
    /// Mirrors `MetalPageManager.decodeThumbFromPDF`: bound the longer edge to
    /// `ReaderConstants.thumbMaxPixel`, draw via `PDFPage.thumbnail(of:for:)`,
    /// and convert to a `CGImage`.
    func thumbnail(_ doc: PDFDocument, pageIndex: Int) -> CGImage? {
        guard let page = doc.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        // Preserve aspect: bound the longer edge to thumbMaxPixel.
        let maxEdge = CGFloat(ReaderConstants.thumbMaxPixel)
        let longer = max(bounds.width, bounds.height)
        let scale = longer > 0 ? maxEdge / longer : 1
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let nsImage = page.thumbnail(of: size, for: .mediaBox)
        var proposedRect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    /// Approximate natural size of a PDF page (mediaBox × 2), used for layout
    /// before the page is decoded. Mirrors the former
    /// `PageSource.naturalSize`'s `.pdf` branch.
    func naturalSize(_ doc: PDFDocument, index: Int) -> CGSize {
        guard let page = doc.page(at: index) else { return CGSize(width: 1, height: 1) }
        let b = page.bounds(for: .mediaBox)
        return CGSize(width: b.width * 2, height: b.height * 2)
    }

    /// Number of pages in the document.
    func pageCount(_ doc: PDFDocument) -> Int {
        doc.pageCount
    }

    // MARK: - Pure helpers (no PDFKit state)

    /// Scales a source pixel size down proportionally so neither axis exceeds
    /// `maxDimension`; returns it unchanged when it already fits.
    private static func cappedSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        guard width > maxDimension || height > maxDimension, width > 0, height > 0 else {
            return (max(width, 0), max(height, 0))
        }
        let scale = Double(maxDimension) / Double(max(width, height))
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }
}
