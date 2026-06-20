import XCTest
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
@testable import DC

/// Tests for the hardened archive-intake path (WS-B Task 4):
/// pre-extraction validation (zip-slip + decompression-bomb caps), cacheDir
/// cleanup on failure, and the streaming per-entry decode counter.
///
/// Tool-dependent cases (CBT via `/usr/bin/tar`, CBR via bundled/Homebrew
/// `unar`/`lsar`) are guarded with `XCTSkipUnless` — `ComicLoader.bundledToolPath`
/// is `private static` (not test-callable), so we probe the known paths directly
/// with `FileManager.fileExists`.
final class ComicLoaderTests: XCTestCase {

    // MARK: - Fixtures

    /// A non-trivial JPEG (gradient fill) so the encoder produces a real
    /// bitstream and the OS image decoder accepts it.
    private func makeJPEGData(width: Int, height: Int, quality: CGFloat = 0.9) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        for x in 0..<width {
            let f = CGFloat(x) / CGFloat(width)
            ctx.setFillColor(CGColor(red: f, green: 1 - f, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Writes a CBZ to `url` with the given (name → realData) entries, each
    /// declared with its real uncompressed size.
    private func makeCBZ(at url: URL, entries: [(String, Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
    }

    /// The bundled/Homebrew unar/lsar paths, mirroring `bundledToolPath`'s
    /// fallback order (we can't call the private resolver from tests).
    private var unarAvailable: Bool {
        ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }
    private var tarAvailable: Bool { FileManager.default.fileExists(atPath: "/usr/bin/tar") }

    private func tmpURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    // MARK: - (a) Valid CBZ loads the expected pages

    func test_loadCBZ_validArchive_loadsExpectedPages() async throws {
        let url = tmpURL("cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeCBZ(at: url, entries: [
            ("001.jpg", makeJPEGData(width: 64, height: 96)),
            ("002.jpg", makeJPEGData(width: 64, height: 96)),
            ("003.jpg", makeJPEGData(width: 64, height: 96)),
        ])

        let comic = try await ComicLoader.load(url: url)
        XCTAssertEqual(comic.format, .cbz)
        XCTAssertEqual(comic.pages.count, 3, "All three image entries must become pages")
    }

    // MARK: - (b) Entry count over the cap → throws

    func test_loadCBZ_entryCountOverCap_throws() async throws {
        let url = tmpURL("cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        // Build maxArchiveEntries + 1 tiny declared entries (empty providers →
        // a small file on disk; we only need the central-directory count).
        let archive = try Archive(url: url, accessMode: .create)
        let over = ReaderConstants.maxArchiveEntries + 1
        for i in 0..<over {
            try archive.addEntry(with: "p\(i).jpg", type: .file, uncompressedSize: Int64(1),
                                 compressionMethod: .deflate) { _, _ in Data([0x00]) }
        }

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url)) { error in
            guard case ComicLoader.LoadError.tooManyEntries = error else {
                return XCTFail("Expected .tooManyEntries, got \(error)")
            }
        }
    }

    // MARK: - (c) Many entries summing over maxUncompressedBytes → rejected
    //
    // A *lying* central directory (declares a small size, decompresses huge) is
    // NOT buildable via ZIPFoundation's writer, which records whatever
    // `uncompressedSize` we declare. So we use the summing variant the brief
    // prescribes: a handful of entries each declaring a large uncompressed size
    // (via an empty provider — a ~116-byte file per entry on disk) whose sum
    // exceeds maxUncompressedBytes. This exercises the pre-flight central-dir
    // sum in `validateCBZ`.

    func test_loadCBZ_declaredSizesSumOverCap_rejected() async throws {
        let url = tmpURL("cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        // 9 entries × 1 GiB = 9 GiB declared > 8 GiB cap. Empty providers keep
        // the on-disk file tiny while the central dir reports the full size.
        let oneGiB: Int64 = 1 * 1024 * 1024 * 1024
        for i in 0..<9 {
            try archive.addEntry(with: "big\(i).jpg", type: .file, uncompressedSize: oneGiB,
                                 compressionMethod: .deflate) { _, _ in Data() }
        }

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url)) { error in
            guard case ComicLoader.LoadError.archiveTooLarge = error else {
                return XCTFail("Expected .archiveTooLarge, got \(error)")
            }
        }
    }

    // MARK: - (d) Zip-slip names rejected PRE-extraction, nothing written out

    func test_loadCBZ_dotDotEscapeEntry_rejectedPreExtraction() async throws {
        let url = tmpURL("cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeCBZ(at: url, entries: [
            ("../escape.jpg", makeJPEGData(width: 32, height: 32)),
        ])

        // A canary at the location the traversal would target.
        let escapeTarget = url.deletingLastPathComponent().appendingPathComponent("escape.jpg")
        try? FileManager.default.removeItem(at: escapeTarget)
        defer { try? FileManager.default.removeItem(at: escapeTarget) }

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url)) { error in
            guard case ComicLoader.LoadError.unsafeEntryPath = error else {
                return XCTFail("Expected .unsafeEntryPath, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget.path),
                       "No file may be written outside the archive's own directory")
    }

    func test_loadCBZ_absolutePathEntry_rejectedPreExtraction() async throws {
        let url = tmpURL("cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        // ZIPFoundation stores the path verbatim; an absolute member name must
        // be rejected by name alone.
        try makeCBZ(at: url, entries: [
            ("/tmp/dc_zipslip_absolute.jpg", makeJPEGData(width: 32, height: 32)),
        ])
        let absTarget = "/tmp/dc_zipslip_absolute.jpg"
        try? FileManager.default.removeItem(atPath: absTarget)

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url)) { error in
            guard case ComicLoader.LoadError.unsafeEntryPath = error else {
                return XCTFail("Expected .unsafeEntryPath, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absTarget),
                       "No file may be written to an absolute path outside the cacheDir")
    }

    func test_loadCBZ_escapingSymlink_rejectedPreExtraction() async throws {
        let url = tmpURL("cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        // A symlink entry whose target climbs out of the extraction root.
        let archive = try Archive(url: url, accessMode: .create)
        let target = "../../../../etc/evil"
        let targetData = Data(target.utf8)
        try archive.addEntry(with: "link.jpg", type: .symlink, uncompressedSize: Int64(targetData.count),
                             compressionMethod: .none) { pos, size in
            targetData.subdata(in: Int(pos)..<Int(pos) + size)
        }
        // Plus a normal image so the archive isn't empty for any other path.
        try archive.addEntry(with: "001.jpg", type: .file, uncompressedSize: Int64(1),
                             compressionMethod: .deflate) { _, _ in Data([0x00]) }

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url)) { error in
            guard case ComicLoader.LoadError.unsafeEntryPath = error else {
                return XCTFail("Expected .unsafeEntryPath for an escaping symlink, got \(error)")
            }
        }
    }

    // MARK: - (e) RCE regression: leading-dash entry name loads via the guarded fallback
    //
    // The historical risk: a member name beginning with "-" (or one that looks
    // like a tool option such as `--use-compress-program=…`) being parsed as an
    // OPTION by the extractor and executing an arbitrary program. The structural
    // guard lives at the cover paths: tar uses the `--` end-of-options separator
    // (so any leading-dash member is treated as an operand, never a flag), and
    // unar — which has no `--` — falls back to a full extraction that passes NO
    // member operand at all. Either way the dash name cannot be misread as a
    // flag. Note also that ALL arguments are passed via `Process.arguments`
    // (argv), never through `sh -c`, so shell metacharacters (`;`, `$()`, spaces)
    // are inert — there is no shell to interpret them. This test asserts a CBT
    // whose only image has a leading-dash name loads its cover without crashing.

    func test_loadCoverCBT_leadingDashEntryName_loadsViaGuardedFallback_noCrash() async throws {
        try XCTSkipUnless(tarAvailable, "system tar required")
        let url = tmpURL("cbt")
        defer { try? FileManager.default.removeItem(at: url) }

        // Stage a directory whose single image has a leading-dash name, then tar
        // it. We build the tar via the system tar so the member name is stored
        // exactly as given.
        let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let dashName = "-rf.jpg"
        try makeJPEGData(width: 48, height: 64).write(to: stage.appendingPathComponent(dashName))

        let tarResult = runTar(["-cf", url.path, "-C", stage.path, "--", dashName])
        try XCTSkipUnless(tarResult == 0, "could not build leading-dash tar fixture")

        // loadCover must not crash; the leading-dash member is handled by the
        // `--` separator (tar) / full-extraction fallback (unar). A non-nil
        // cover proves the guarded fallback actually produced the image.
        let cover = await ComicLoader.loadCover(url: url)
        XCTAssertNotNil(cover, "Leading-dash cover must load via the guarded fallback, not crash or fail")
    }

    // MARK: - (f) Extraction failure leaves NO cacheDir

    func test_loadCBT_garbageArchive_leavesNoCacheDir() async throws {
        try XCTSkipUnless(tarAvailable, "system tar required")
        let url = tmpURL("cbt")
        defer { try? FileManager.default.removeItem(at: url) }
        // Garbage bytes — tar listing/extraction will fail.
        try Data("this is not a tar archive at all".utf8).write(to: url)

        let cacheDir = ComicLoader.persistentPageCacheDir(for: url)
        try? FileManager.default.removeItem(at: cacheDir)

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url))

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path),
                       "A failed extraction must not leave a cacheDir behind")
    }

    func test_loadCBR_nonexistentArchive_leavesNoCacheDir() async throws {
        try XCTSkipUnless(unarAvailable, "unar/lsar required for CBR")
        let url = tmpURL("cbr")
        defer { try? FileManager.default.removeItem(at: url) }
        // Garbage CBR bytes — lsar listing fails / unar extraction fails.
        try Data("not a rar".utf8).write(to: url)

        let cacheDir = ComicLoader.persistentPageCacheDir(for: url)
        try? FileManager.default.removeItem(at: cacheDir)

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url))

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path),
                       "A failed CBR extraction must not leave a cacheDir behind")
    }

    // MARK: - CBT zip-slip rejected pre-extraction (tar-slip)

    func test_loadCBT_dotDotEscapeEntry_rejectedPreExtraction() async throws {
        try XCTSkipUnless(tarAvailable, "system tar required")
        let url = tmpURL("cbt")
        defer { try? FileManager.default.removeItem(at: url) }
        // Build a tar whose member name traverses upward. GNU/bsd tar strips
        // leading "../" on extraction, but our pre-flight rejects it by NAME so
        // we never reach extraction.
        let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try makeJPEGData(width: 32, height: 32).write(to: stage.appendingPathComponent("page.jpg"))
        // Use transform/append-style: create with a member name containing ../
        // by staging a nested path then referencing it as ../.
        let result = runTar(["-cf", url.path, "-C", stage.path, "page.jpg"])
        try XCTSkipUnless(result == 0, "could not build tar fixture")

        // Rewrite the archive to contain a "../escape.jpg" member by repacking
        // through a path that tar stores with the traversal. Simplest portable
        // approach: stage the file at a parent-relative path.
        let parent = stage.deletingLastPathComponent()
        let escapeName = stage.lastPathComponent + "/../slip.jpg"
        try makeJPEGData(width: 32, height: 32).write(to: parent.appendingPathComponent("slip.jpg"))
        defer { try? FileManager.default.removeItem(at: parent.appendingPathComponent("slip.jpg")) }
        let result2 = runTar(["-cf", url.path, "-C", parent.path, "--", escapeName])
        try XCTSkipUnless(result2 == 0, "could not build traversal tar fixture")

        let cacheDir = ComicLoader.persistentPageCacheDir(for: url)
        try? FileManager.default.removeItem(at: cacheDir)

        await XCTAssertThrowsErrorAsync(try await ComicLoader.load(url: url)) { error in
            guard case ComicLoader.LoadError.unsafeEntryPath = error else {
                return XCTFail("Expected .unsafeEntryPath for tar traversal, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path),
                       "A rejected tar must not leave a cacheDir behind")
    }

    // MARK: - (g) Capped-extract helper: tiny cap triggers entryTooLarge; generous cap returns full data

    /// Tests `Archive.extractEntryData(_:cap:)` — the shared production guard
    /// against decompression bombs via a lying central directory.
    ///
    /// A real 8 GiB zip-bomb fixture is impractical in CI, so we use a tiny cap
    /// (1 byte) against normal image data. Any non-empty decompressed byte stream
    /// will exceed a cap of 1, so this reliably exercises the same `guard total <=
    /// cap else { throw }` branch that fires in production against a massive entry.
    func test_extractEntryData_tinyCapThrows_generousCapReturnsData() throws {
        let jpeg = makeJPEGData(width: 32, height: 32)
        let url = tmpURL("cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeCBZ(at: url, entries: [("001.jpg", jpeg)])

        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["001.jpg"] else {
            XCTFail("Fixture entry '001.jpg' must exist")
            return
        }

        // Cap of 1 byte must always throw — any real JPEG decompresses to more.
        XCTAssertThrowsError(
            try archive.extractEntryData(entry, cap: 1),
            "A cap of 1 byte must throw .entryTooLarge for any real image"
        ) { error in
            guard case Archive.CappedExtractError.entryTooLarge = error else {
                XCTFail("Expected Archive.CappedExtractError.entryTooLarge, got \(error)")
                return
            }
        }

        // Generous cap must return the full decompressed data intact.
        let extracted = try archive.extractEntryData(
            entry, cap: ReaderConstants.maxUncompressedBytes)
        XCTAssertEqual(extracted, jpeg,
                       "Generous cap must return the full unmodified entry data")
    }

    // MARK: - Helpers

    /// Runs `/usr/bin/tar` synchronously and returns its exit status.
    private func runTar(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}

// MARK: - async throws assertion helper

/// XCTAssertThrowsError has no async overload; this wrapper awaits the
/// autoclosure and asserts it threw, optionally inspecting the error.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
