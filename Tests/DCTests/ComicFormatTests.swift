import XCTest
@testable import DC

final class ComicFormatTests: XCTestCase {

    func testKnownExtensions() {
        XCTAssertEqual(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a.cbz")), .cbz)
        XCTAssertEqual(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a.cbr")), .cbr)
        XCTAssertEqual(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a.cb7")), .cb7)
        XCTAssertEqual(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a.cbt")), .cbt)
        XCTAssertEqual(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a.pdf")), .pdf)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/A.CBZ")), .cbz)
        XCTAssertEqual(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/A.PdF")), .pdf)
    }

    func testUnknownExtension() {
        XCTAssertNil(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a.jpg")))
        XCTAssertNil(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a")))
        XCTAssertNil(ComicFormat.from(url: URL(fileURLWithPath: "/tmp/a.zip")))
    }

    func testPathWithSpacesAndDots() {
        XCTAssertEqual(
            ComicFormat.from(url: URL(fileURLWithPath: "/tmp/My Comic Vol. 1.cbz")),
            .cbz
        )
    }

    func testDisplayName() {
        XCTAssertEqual(ComicFormat.cbz.displayName, "CBZ")
        XCTAssertEqual(ComicFormat.pdf.displayName, "PDF")
    }
}
