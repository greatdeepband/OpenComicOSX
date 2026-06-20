import XCTest
import CoreGraphics
import CoreVideo
import PDFKit
@testable import DC

/// Concurrency stress tests for `PDFKitGate` — the process-wide actor that
/// serializes every PDFKit call. PDFKit is NOT thread-safe; before the gate,
/// the reader's full-res decode, the parallel thumbnail pre-scan, and cover
/// loads could all touch a `PDFDocument` (or distinct documents that share
/// PDFKit's internal global state) concurrently. These tests drive many
/// concurrent `renderPage` + `thumbnail` calls through the gate and assert
/// non-nil results with no crash.
///
/// NOTE: ThreadSanitizer could not be run in this environment (the TSan
/// runtime dylib is blocked on macOS 26 arm64e), so this is a behavioural /
/// crash stress test rather than a data-race detector. A TSan pass on a
/// compatible host is recommended as a later follow-up.
final class PDFKitGateTests: XCTestCase {

    // MARK: - PDF fixture helper

    /// Builds a multi-page PDF entirely in memory and returns a `PDFDocument`.
    /// Each page is `pageSize` points and filled with a per-page colour so the
    /// rasteriser actually has content to draw (a blank page can decode to a
    /// degenerate buffer on some configurations).
    private func makePDFDocument(pageCount: Int,
                                 pageSize: CGSize = CGSize(width: 200, height: 300)) -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            fatalError("could not create CGDataConsumer for PDF fixture")
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            fatalError("could not create PDF CGContext for fixture")
        }
        for i in 0..<pageCount {
            ctx.beginPage(mediaBox: &mediaBox)
            let f = CGFloat(i + 1) / CGFloat(pageCount + 1)
            ctx.setFillColor(CGColor(red: f, green: 1 - f, blue: 0.5, alpha: 1))
            ctx.fill(mediaBox)
            // A second contrasting rectangle so the page is non-uniform.
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: pageSize.width * 0.25, y: pageSize.height * 0.25,
                            width: pageSize.width * 0.5, height: pageSize.height * 0.5))
            ctx.endPage()
        }
        ctx.closePDF()

        guard let doc = PDFDocument(data: data as Data) else {
            fatalError("PDFDocument(data:) returned nil for fixture")
        }
        return doc
    }

    // MARK: - Fixture sanity

    func test_fixture_buildsMultiPagePDF() {
        let doc = makePDFDocument(pageCount: 5)
        XCTAssertEqual(doc.pageCount, 5, "fixture must build the requested number of pages")
    }

    // MARK: - Single-call correctness through the gate

    func test_gate_renderPage_returnsBuffer() async {
        let doc = makePDFDocument(pageCount: 3)
        let buffer = await PDFKitGate.shared.renderPage(doc, index: 0,
                                                        pixelSize: CGSize(width: 400, height: 600))
        XCTAssertNotNil(buffer, "renderPage must produce a CVPixelBuffer")
        if let buffer {
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        }
    }

    func test_gate_thumbnail_returnsImage() async {
        let doc = makePDFDocument(pageCount: 3)
        let image = await PDFKitGate.shared.thumbnail(doc, pageIndex: 1)
        XCTAssertNotNil(image, "thumbnail must produce a CGImage")
    }

    func test_gate_naturalSize_matchesPageBounds() async {
        let doc = makePDFDocument(pageCount: 2, pageSize: CGSize(width: 200, height: 300))
        let size = await PDFKitGate.shared.naturalSize(doc, index: 0)
        // Mirrors the previous PageSource.naturalSize.pdf branch: bounds × 2.
        XCTAssertEqual(size.width, 400, accuracy: 1)
        XCTAssertEqual(size.height, 600, accuracy: 1)
    }

    func test_gate_pageCount() async {
        let doc = makePDFDocument(pageCount: 7)
        let count = await PDFKitGate.shared.pageCount(doc)
        XCTAssertEqual(count, 7)
    }

    func test_gate_outOfRangeIndex_returnsNilNotCrash() async {
        let doc = makePDFDocument(pageCount: 2)
        let buffer = await PDFKitGate.shared.renderPage(doc, index: 99,
                                                        pixelSize: CGSize(width: 100, height: 100))
        let thumb = await PDFKitGate.shared.thumbnail(doc, pageIndex: 99)
        XCTAssertNil(buffer)
        XCTAssertNil(thumb)
    }

    // MARK: - Concurrency stress

    /// Fires a large `withTaskGroup` of concurrent `renderPage` + `thumbnail`
    /// calls against the SHARED reader document AND a second cover-style
    /// document, through the gate, over many iterations. Asserts every result
    /// is non-nil and the process does not crash — exactly the pattern that
    /// races PDFKit without serialization.
    func test_gate_concurrentRenderAndThumbnail_noCrash() async {
        let readerDoc = makePDFDocument(pageCount: 8)
        let coverDoc  = makePDFDocument(pageCount: 4)   // separate "cover" document
        let iterations = 12
        let pageRange = 0..<8

        for _ in 0..<iterations {
            await withTaskGroup(of: Bool.self) { group in
                // Concurrent full-res renders on the shared reader document.
                for i in pageRange {
                    group.addTask {
                        let buf = await PDFKitGate.shared.renderPage(
                            readerDoc, index: i, pixelSize: CGSize(width: 400, height: 600))
                        return buf != nil
                    }
                }
                // Concurrent thumbnails on the same shared document.
                for i in pageRange {
                    group.addTask {
                        let img = await PDFKitGate.shared.thumbnail(readerDoc, pageIndex: i)
                        return img != nil
                    }
                }
                // Concurrent cover-style renders on a DIFFERENT document, which
                // is exactly the cross-document race the gate must also cover.
                for i in 0..<4 {
                    group.addTask {
                        let buf = await PDFKitGate.shared.renderPage(
                            coverDoc, index: i, pixelSize: CGSize(width: 200, height: 300))
                        let img = await PDFKitGate.shared.thumbnail(coverDoc, pageIndex: i)
                        return buf != nil && img != nil
                    }
                }

                var allOK = true
                for await ok in group where !ok { allOK = false }
                XCTAssertTrue(allOK, "every concurrent render/thumbnail through the gate must be non-nil")
            }
        }
    }
}
