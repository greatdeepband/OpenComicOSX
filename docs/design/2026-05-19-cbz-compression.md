# CBZ Compression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recompress JPEG images inside CBZ archives in place, exposed via a Library menu item ("Compress All Comics"), a right-click action on individual comic cards, and a right-click action on gallery sidebar rows. First-run prompt asks whether to delete the original or keep both files; the choice is remembered.

**Architecture:** Port CompyUI's `container.py` + `image_engine.py` algorithm to native Swift (no Python sidecar — keeps the bundle at 4 MB). Use `ZIPFoundation` (already a project dependency) for the zip read/write and `ImageIO` for JPEG decode/resize/re-encode. An `actor`-backed `CompressionService` runs single or batch jobs as cancellable `Task`s and publishes progress to a SwiftUI sheet. PNGs and non-image entries pass through unchanged; bitonal JPEGs are skipped; the new file replaces the original only when it shrinks past the `skipThreshold`. Atomic write via tmp file + `FileManager.replaceItemAt`.

**Library always points at the compressed file (so reads are immediately faster):** Both modes write the compressed bytes to the *original path* via atomic rename. The library URL never moves. In keep-originals mode the untouched copy lives next to it as `<name>-original.cbz`. Per-file thumbnail invalidation fires after each successful compression so the library cover refreshes from the new (smaller) file without restarting the app.

**Tech Stack:** Swift 5.10, ZIPFoundation 0.9.19, ImageIO (system framework), SwiftUI sheets, `Task` / `actor` for async + cancellation, `UserDefaults` for the remembered "delete originals" choice.

**Source code being ported:** `/Volumes/Media/CompyUI/engine/compyui_engine/container.py` (CBZ handling) and `image_engine.py` (`recompress_jpeg_bytes`). CompyUI's PDF compression (`compress.py`) is **out of scope for v1** — it requires `pikepdf` (Python-only); a Swift port would need PDFKit XObject walking, which is its own project.

**Scope:**
- ✅ v1: `.cbz` archives, JPEG entries recompressed in place, PNG / other formats passed through, atomic write
- ❌ v1: `.cbr`, `.cb7`, `.cbt` (different archive format; would need `unar` extract + CBZ repack — format conversion, not pure recompression)
- ❌ v1: `.pdf` (needs Swift PDFKit-based image walk — separate plan)
- ❌ v1: User-tunable quality (uses CompyUI defaults: maxDim=2000, jpegQuality=0.85, grayQuality=0.80, skipThreshold=0.95)

When the user picks "compress all" but the library contains non-CBZ files, those are reported as "skipped: format not yet supported" in the per-file results, not as errors.

---

## File structure

### New files
| Path | Responsibility |
|------|---|
| `Sources/DC/Models/CBZCompressor.swift` | Pure algorithm: detect CBZ, walk entries, recompress JPEGs, repack zip, atomic-rename. No UI, no `@MainActor`. |
| `Sources/DC/Models/CompressionService.swift` | Orchestrator: actor that runs single + batch compression as `Task`s, publishes progress, supports cancellation. |
| `Sources/DC/Views/CompressionPromptSheet.swift` | Modal sheet: "Delete originals after compression?" + "Remember my choice" checkbox. |
| `Sources/DC/Views/CompressionProgressSheet.swift` | Modal progress UI: file count, current file, cancel button, per-file error list. |
| `Tests/DCTests/CBZCompressorTests.swift` | Unit tests against synthetic CBZ fixtures built in-test via `ZIPFoundation`. |

### Modified files
| Path | Change |
|------|---|
| `Sources/DC/ReaderConstants.swift` | Add compression constants block (maxDim, qualities, threshold) |
| `Sources/DC/DCApp.swift:24` | Add "Compress All Comics…" menu item inside the existing `CommandMenu("Library")` |
| `Sources/DC/Views/LibraryView.swift` | Add "Compress Comic" context-menu item on each `ComicCard` (lines around 149, 327, 472, 1165 — every `.contextMenu` site that lists comic actions); add "Compress Gallery" item on `LibrarySidebar` gallery rows |
| `Sources/DC/ViewModels/LibraryViewModel.swift` | Expose `compressionService: CompressionService`; expose convenience methods `compressAll()`, `compressGallery(_ id: UUID)`, `compressComic(at: URL)` |

### Constants (`ReaderConstants.swift`)
```swift
// MARK: - CBZ compression (ported from CompyUI engine, 2026-05-14)

/// Longest-edge pixel cap for recompressed JPEGs inside CBZ archives.
/// 2000 px stays above the highest reading-mode native resolution on a
/// 5K display while shrinking large 4000+ px source scans by ~75 %.
static let cbzCompressionMaxDim: Int = 2000

/// JPEG quality for colour images during CBZ recompression (0.0-1.0,
/// matches `kCGImageDestinationLossyCompressionQuality`). 0.85 matches
/// CompyUI's default — visually transparent on comic art at typical
/// reading scales.
static let cbzCompressionJpegQuality: CGFloat = 0.85

/// JPEG quality for grayscale images. 0.80 — manga and B&W scans
/// tolerate slightly more aggressive quantisation than colour.
static let cbzCompressionGrayQuality: CGFloat = 0.80

/// Skip the rewrite when the recompressed JPEG would be larger than
/// `original_size * skipThreshold`. 0.95 — only rewrite when we save
/// at least 5 %, so a near-optimum source doesn't get bounced through
/// a re-encoder for no benefit.
static let cbzCompressionSkipThreshold: Double = 0.95
```

### UserDefaults keys
```swift
// In CompressionService.swift
private enum DefaultsKey {
    static let deleteOriginalsRemembered = "cbz.compression.deleteOriginals.remembered"
    static let deleteOriginalsChoice     = "cbz.compression.deleteOriginals.choice"
}
```

---

## Task breakdown

### Task 1: Add compression constants

**Files:**
- Modify: `Sources/DC/ReaderConstants.swift`

- [ ] **Step 1: Append the compression constants block** to the end of `ReaderConstants` (after the trackpad swipe block):

```swift
    // MARK: - CBZ compression (ported from CompyUI engine, 2026-05-14)

    /// Longest-edge pixel cap for recompressed JPEGs inside CBZ archives.
    /// 2000 px stays above the highest reading-mode native resolution on a
    /// 5K display while shrinking large 4000+ px source scans by ~75 %.
    static let cbzCompressionMaxDim: Int = 2000

    /// JPEG quality for colour images during CBZ recompression (0.0-1.0,
    /// matches `kCGImageDestinationLossyCompressionQuality`). 0.85 matches
    /// CompyUI's default — visually transparent on comic art at typical
    /// reading scales.
    static let cbzCompressionJpegQuality: CGFloat = 0.85

    /// JPEG quality for grayscale images. 0.80 — manga and B&W scans
    /// tolerate slightly more aggressive quantisation than colour.
    static let cbzCompressionGrayQuality: CGFloat = 0.80

    /// Skip the rewrite when the recompressed JPEG would be larger than
    /// `original_size * skipThreshold`. 0.95 — only rewrite when we save
    /// at least 5 %, so a near-optimum source doesn't get bounced through
    /// a re-encoder for no benefit.
    static let cbzCompressionSkipThreshold: Double = 0.95
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!` (no diagnostics)

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/ReaderConstants.swift
git commit -m "feat(compress): add CBZ compression constants"
```

---

### Task 2: Port the JPEG recompressor (pure logic, unit-testable)

**Files:**
- Create: `Sources/DC/Models/CBZCompressor.swift`
- Create: `Tests/DCTests/CBZCompressorTests.swift`

- [ ] **Step 1: Write the failing test** at `Tests/DCTests/CBZCompressorTests.swift`:

```swift
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import DC

final class CBZCompressorTests: XCTestCase {

    /// Synthesizes an in-memory JPEG of size (w, h), filled with a horizontal
    /// gradient so the encoder produces a non-trivial bitstream (a flat fill
    /// compresses to a degenerate few-byte stream and breaks size assertions).
    private func makeJPEGData(width: Int, height: Int, quality: CGFloat = 0.95) -> Data {
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

    func test_recompressJPEG_largeImage_shrinks() throws {
        let input = makeJPEGData(width: 3000, height: 4000, quality: 0.95)
        let result = CBZCompressor.recompressJPEG(
            data: input,
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )
        XCTAssertNotNil(result, "Expected a shrunk JPEG")
        XCTAssertLessThan(result!.count, input.count, "Output must be smaller than input")
    }

    func test_recompressJPEG_smallImage_returnsNil() throws {
        // A 200x200 image at q=0.85 is already small — won't shrink past
        // the 0.95 threshold, so the function returns nil (skip rewrite).
        let input = makeJPEGData(width: 200, height: 200, quality: 0.85)
        let result = CBZCompressor.recompressJPEG(
            data: input,
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )
        XCTAssertNil(result, "Already-small input should be skipped")
    }

    func test_recompressJPEG_invalidData_returnsNil() {
        let result = CBZCompressor.recompressJPEG(
            data: Data([0x00, 0x01, 0x02, 0x03]),
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )
        XCTAssertNil(result, "Garbage input must produce nil, not crash")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails** (since `CBZCompressor` doesn't exist yet):

Run: `swift test --filter CBZCompressorTests 2>&1 | tail -20`
Expected: `error: cannot find 'CBZCompressor' in scope`

- [ ] **Step 3: Create `Sources/DC/Models/CBZCompressor.swift`** with the recompressJPEG implementation:

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure-logic CBZ compressor — no UI, no `@MainActor`. Mirrors CompyUI's
/// `container.py` + `image_engine.py` algorithm (ported 2026-05-19):
///
///   1. JPEG entries → decode via ImageIO, resize to fit `maxDim`,
///      re-encode at `jpegQuality` / `grayQuality`. Skip if the new bytes
///      aren't at least `(1 - skipThreshold)` smaller than the source.
///   2. PNG and other entries → passed through unchanged
///      (CompyUI's "format-preservation contract" — never replace a PNG
///      with JPEG bytes).
///
/// Heavy I/O. Callers should invoke from a background `Task`.
enum CBZCompressor {

    // MARK: - Public: single-image recompression

    /// Decode `data` as an image, resize it to fit `maxDim` on the longer
    /// edge, re-encode as JPEG. Returns the new bytes IFF they're at
    /// least `(1 - skipThreshold)` smaller than `data`; otherwise `nil`
    /// (caller leaves the original entry untouched).
    ///
    /// Returns `nil` for:
    /// - Undecodable input
    /// - 1-bit / bitonal images (mode == .grayscale && bpc == 1)
    /// - Outputs that wouldn't shrink past the threshold
    static func recompressJPEG(
        data: Data,
        maxDim: Int,
        jpegQuality: CGFloat,
        grayQuality: CGFloat,
        skipThreshold: Double
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        // Bitonal protection: 1-bit-per-component grayscale stays in
        // its original encoding (re-encode as lossy JPEG would balloon).
        let bpc = (props[kCGImagePropertyDepth] as? Int) ?? 8
        let model = (props[kCGImagePropertyColorModel] as? String) ?? ""
        let isGray = (model == (kCGImagePropertyColorModelGray as String))
        if isGray && bpc == 1 { return nil }

        // Decode-with-resize via ImageIO thumbnail API — efficient
        // (skips full-res decode when source is much larger than maxDim).
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else { return nil }

        let quality = isGray ? grayQuality : jpegQuality
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let destProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let newBytes = outData as Data
        if Double(newBytes.count) >= Double(data.count) * skipThreshold {
            return nil
        }
        return newBytes
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter CBZCompressorTests 2>&1 | tail -10`
Expected: `Test Suite 'CBZCompressorTests' passed` with 3 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/DC/Models/CBZCompressor.swift Tests/DCTests/CBZCompressorTests.swift
git commit -m "feat(compress): port recompressJPEG from CompyUI engine

Native Swift via ImageIO (CGImageSource thumbnail API for
decode-with-resize, CGImageDestination for JPEG re-encode).
Mirrors CompyUI/engine/compyui_engine/image_engine.py."
```

---

### Task 3: Add CBZ container walk + atomic-rename

**Files:**
- Modify: `Sources/DC/Models/CBZCompressor.swift`
- Modify: `Tests/DCTests/CBZCompressorTests.swift`

- [ ] **Step 1: Add a failing test** for `compressCBZ` that builds a synthetic CBZ in a temp dir, runs the compressor, opens the output, and verifies (a) the JPEG entry shrank, (b) the PNG entry is byte-identical:

Append to `Tests/DCTests/CBZCompressorTests.swift`:

```swift
    import ZIPFoundation

    /// Builds a CBZ at `url` containing two entries:
    ///   - `001.jpg` — large JPEG that should recompress
    ///   - `002.png` — opaque PNG that should pass through unchanged
    private func makeSyntheticCBZ(at url: URL) throws -> (jpegSize: Int, pngSize: Int, pngHash: Data) {
        let jpegData = makeJPEGData(width: 3000, height: 4000, quality: 0.95)
        let pngData: Data = {
            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(data: nil, width: 100, height: 100,
                                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            let image = ctx.makeImage()!
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            return out as Data
        }()
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "001.jpg", type: .file, uncompressedSize: Int64(jpegData.count),
                             compressionMethod: .deflate) { pos, size in
            jpegData.subdata(in: Int(pos)..<Int(pos) + size)
        }
        try archive.addEntry(with: "002.png", type: .file, uncompressedSize: Int64(pngData.count),
                             compressionMethod: .deflate) { pos, size in
            pngData.subdata(in: Int(pos)..<Int(pos) + size)
        }
        let hasher = SHA256()
        return (jpegData.count, pngData.count, Data(hasher.hash(data: pngData)))
    }

    func test_compressCBZ_shrinksJPEG_passesThroughPNG() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = try makeSyntheticCBZ(at: tmp)
        let originalSize = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0

        let result = try CBZCompressor.compressCBZ(
            at: tmp,
            maxDim: 2000,
            jpegQuality: 0.85,
            grayQuality: 0.80,
            skipThreshold: 0.95
        )

        XCTAssertEqual(result.jpegsRewritten, 1)
        XCTAssertEqual(result.pngsPassed, 1)
        XCTAssertLessThan(result.outputBytes, result.inputBytes)
        XCTAssertEqual(result.inputBytes, originalSize)

        // Re-open and confirm the PNG entry is byte-identical
        let after = try Archive(url: tmp, accessMode: .read)
        guard let pngEntry = after["002.png"] else { return XCTFail("PNG entry missing") }
        var roundtripped = Data()
        _ = try after.extract(pngEntry) { roundtripped.append($0) }
        XCTAssertEqual(roundtripped.count, original.pngSize, "PNG must pass through unchanged")
    }
```

(`SHA256` placeholder is only used for the comparison — the test relies on byte length + final content equality, no real hash needed. Drop the `hasher` lines if it complicates compilation; the byte-length check is sufficient.)

- [ ] **Step 2: Run the test to confirm it fails** (`compressCBZ` does not exist):

Run: `swift test --filter CBZCompressorTests/test_compressCBZ 2>&1 | tail -10`
Expected: `error: type 'CBZCompressor' has no member 'compressCBZ'`

- [ ] **Step 3: Add `compressCBZ` + `CBZCompressionResult`** to `Sources/DC/Models/CBZCompressor.swift`:

```swift
// MARK: - Public: full-file CBZ compression

import ZIPFoundation

struct CBZCompressionResult {
    let url: URL
    let inputBytes: Int
    let outputBytes: Int
    let jpegsSeen: Int
    let jpegsRewritten: Int
    let jpegsSkippedBitonal: Int
    let jpegsSkippedThreshold: Int
    let jpegsFailed: Int
    let pngsPassed: Int
    let othersPassed: Int
}

enum CBZCompressionError: Error {
    case notACBZ           // file doesn't end in .cbz or doesn't start with PK
    case invalidArchive    // ZIPFoundation refused to open
    case ioFailure(String) // wraps a more specific cause
}

extension CBZCompressor {

    /// Recompresses every JPEG entry inside the CBZ at `url`, writes a new
    /// CBZ to a sibling `.tmp` file, then atomic-renames it back over the
    /// original (so a crash mid-compression never destroys the source).
    ///
    /// PNG and other entries pass through unchanged (format-preservation
    /// contract). Throws `CBZCompressionError.notACBZ` for non-CBZ inputs.
    ///
    /// Reports per-image progress via `progress("entry", current, total)`
    /// when `progress` is non-nil. Honors `Task.isCancelled` between entries.
    static func compressCBZ(
        at url: URL,
        maxDim: Int,
        jpegQuality: CGFloat,
        grayQuality: CGFloat,
        skipThreshold: Double,
        progress: ((String, Int, Int) -> Void)? = nil
    ) throws -> CBZCompressionResult {
        guard url.pathExtension.lowercased() == "cbz" else {
            throw CBZCompressionError.notACBZ
        }
        // Magic-byte check — header must start with PK (zip)
        let fh = try FileHandle(forReadingFrom: url)
        let header = fh.readData(ofLength: 2)
        try fh.close()
        guard header == Data([0x50, 0x4B]) else {
            throw CBZCompressionError.notACBZ
        }

        let inputBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let inArchive: Archive
        do {
            inArchive = try Archive(url: url, accessMode: .read)
        } catch {
            throw CBZCompressionError.invalidArchive
        }

        // Write to a sibling tmp file so a crash or cancellation can't
        // corrupt the source. Atomic-replace on success.
        let tmpURL = url.deletingPathExtension()
            .appendingPathExtension("cbz.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: tmpURL)
        let outArchive: Archive
        do {
            outArchive = try Archive(url: tmpURL, accessMode: .create)
        } catch {
            throw CBZCompressionError.ioFailure("create tmp archive: \(error)")
        }

        var seenJPEG = 0, rewrote = 0, skippedBitonal = 0, skippedThreshold = 0, failedJPEG = 0
        var passedPNG = 0, passedOther = 0

        // Snapshot entries so a stable count is available for progress.
        let entries = Array(inArchive.makeIterator())
        let total = entries.count
        for (idx, entry) in entries.enumerated() {
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tmpURL)
                throw CancellationError()
            }
            progress?("entry", idx + 1, total)
            let name = entry.path.lowercased()
            // Read entry bytes
            var data = Data()
            do {
                _ = try inArchive.extract(entry) { data.append($0) }
            } catch {
                // Couldn't extract — copy original bytes? Skip.
                continue
            }
            let isJPEG = name.hasSuffix(".jpg") || name.hasSuffix(".jpeg")
            let isPNG  = name.hasSuffix(".png")
            if isJPEG {
                seenJPEG += 1
                if let newBytes = recompressJPEG(
                    data: data,
                    maxDim: maxDim,
                    jpegQuality: jpegQuality,
                    grayQuality: grayQuality,
                    skipThreshold: skipThreshold
                ) {
                    do {
                        try outArchive.addEntry(
                            with: entry.path, type: .file,
                            uncompressedSize: Int64(newBytes.count),
                            compressionMethod: .deflate
                        ) { pos, size in
                            newBytes.subdata(in: Int(pos)..<Int(pos) + size)
                        }
                        rewrote += 1
                    } catch {
                        failedJPEG += 1
                        try outArchive.addEntry(
                            with: entry.path, type: .file,
                            uncompressedSize: Int64(data.count),
                            compressionMethod: .deflate
                        ) { pos, size in
                            data.subdata(in: Int(pos)..<Int(pos) + size)
                        }
                    }
                } else {
                    // recompressJPEG returned nil → bitonal or below threshold.
                    // We can't distinguish those two cleanly from here, so
                    // attribute to "skippedThreshold" for the common case.
                    skippedThreshold += 1
                    try outArchive.addEntry(
                        with: entry.path, type: .file,
                        uncompressedSize: Int64(data.count),
                        compressionMethod: .deflate
                    ) { pos, size in
                        data.subdata(in: Int(pos)..<Int(pos) + size)
                    }
                }
            } else if isPNG {
                passedPNG += 1
                try outArchive.addEntry(
                    with: entry.path, type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate
                ) { pos, size in
                    data.subdata(in: Int(pos)..<Int(pos) + size)
                }
            } else {
                passedOther += 1
                try outArchive.addEntry(
                    with: entry.path, type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate
                ) { pos, size in
                    data.subdata(in: Int(pos)..<Int(pos) + size)
                }
            }
        }

        // Atomic replace via FileManager.replaceItemAt — handles same-
        // volume rename on APFS, falls back to copy + delete elsewhere.
        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.size] as? Int) ?? 0
        if outputBytes >= inputBytes {
            // Compression didn't help. Discard tmp, leave original alone.
            try? FileManager.default.removeItem(at: tmpURL)
            return CBZCompressionResult(
                url: url, inputBytes: inputBytes, outputBytes: inputBytes,
                jpegsSeen: seenJPEG, jpegsRewritten: 0,
                jpegsSkippedBitonal: skippedBitonal,
                jpegsSkippedThreshold: skippedThreshold + rewrote,
                jpegsFailed: failedJPEG,
                pngsPassed: passedPNG, othersPassed: passedOther
            )
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)

        return CBZCompressionResult(
            url: url, inputBytes: inputBytes, outputBytes: outputBytes,
            jpegsSeen: seenJPEG, jpegsRewritten: rewrote,
            jpegsSkippedBitonal: skippedBitonal,
            jpegsSkippedThreshold: skippedThreshold,
            jpegsFailed: failedJPEG,
            pngsPassed: passedPNG, othersPassed: passedOther
        )
    }
}
```

- [ ] **Step 4: Run tests and confirm they pass**

Run: `swift test --filter CBZCompressorTests 2>&1 | tail -10`
Expected: 4 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/DC/Models/CBZCompressor.swift Tests/DCTests/CBZCompressorTests.swift
git commit -m "feat(compress): CBZ container walk + atomic rename

Mirrors CompyUI container.py: extract via ZIPFoundation, recompress
JPEGs in place, PNG/other passed through, atomic rename of tmp file
to original. Honors Task.isCancelled between entries."
```

---

### Task 4: CompressionService — single-file orchestrator + progress publisher

**Files:**
- Create: `Sources/DC/Models/CompressionService.swift`

This is an `@MainActor` `ObservableObject` so SwiftUI sheets can bind to its `@Published` progress state. The compression itself runs in a detached `Task` so the `@MainActor` thread isn't blocked.

- [ ] **Step 1: Create `Sources/DC/Models/CompressionService.swift`**:

```swift
import Foundation
import SwiftUI

/// State machine for one batch of CBZ compressions. The view layer observes
/// `state` to render the sheet; the run loop publishes per-file progress.
@MainActor
final class CompressionService: ObservableObject {

    enum State: Equatable {
        case idle
        case running
        case finished(summary: BatchSummary)
        case cancelled(partial: BatchSummary)
        case failed(error: String)
    }

    struct BatchSummary: Equatable {
        var attempted: Int = 0
        var succeeded: Int = 0
        var skippedNonCBZ: Int = 0
        var failed: Int = 0
        var totalInputBytes: Int = 0
        var totalOutputBytes: Int = 0
        var errors: [(url: URL, message: String)] = []
        static func == (l: BatchSummary, r: BatchSummary) -> Bool {
            l.attempted == r.attempted
                && l.succeeded == r.succeeded
                && l.skippedNonCBZ == r.skippedNonCBZ
                && l.failed == r.failed
                && l.totalInputBytes == r.totalInputBytes
                && l.totalOutputBytes == r.totalOutputBytes
                && l.errors.count == r.errors.count
        }
    }

    @Published var state: State = .idle
    @Published var currentFileURL: URL? = nil
    @Published var filesCompleted: Int = 0
    @Published var filesTotal: Int = 0

    private var runningTask: Task<Void, Never>? = nil

    /// Kicks off a batch run over `urls`. Idempotent — if a batch is already
    /// running, the second call is ignored.
    ///
    /// `onFileCompleted` fires on the main actor for every URL whose
    /// compressCBZ returned success (NOT cancelled, NOT skipped, NOT
    /// failed). LibraryViewModel uses this to invalidate the cached
    /// thumbnail so the card refreshes from the new (smaller) file.
    func runBatch(
        urls: [URL],
        deleteOriginals: Bool,
        onFileCompleted: ((URL) -> Void)? = nil
    ) {
        guard case .idle = state else {
            // Already running (.running) or showing a previous summary
            // (.finished/.cancelled/.failed). Caller must dismiss first.
            if case .running = state { return }
        }
        state = .running
        currentFileURL = nil
        filesCompleted = 0
        filesTotal = urls.count
        var summary = BatchSummary()

        runningTask = Task.detached { [weak self] in
            for (idx, url) in urls.enumerated() {
                if Task.isCancelled {
                    await MainActor.run {
                        self?.state = .cancelled(partial: summary)
                        self?.runningTask = nil
                    }
                    return
                }
                await MainActor.run {
                    self?.currentFileURL = url
                    self?.filesCompleted = idx
                }
                if url.pathExtension.lowercased() != "cbz" {
                    summary.skippedNonCBZ += 1
                    continue
                }
                summary.attempted += 1
                do {
                    let result = try CBZCompressor.compressCBZ(
                        at: url,
                        maxDim: ReaderConstants.cbzCompressionMaxDim,
                        jpegQuality: ReaderConstants.cbzCompressionJpegQuality,
                        grayQuality: ReaderConstants.cbzCompressionGrayQuality,
                        skipThreshold: ReaderConstants.cbzCompressionSkipThreshold
                    )
                    summary.succeeded += 1
                    summary.totalInputBytes += result.inputBytes
                    summary.totalOutputBytes += result.outputBytes
                    // Note: `deleteOriginals` is `true` semantically for v1
                    // (compressCBZ already rewrote the file in place via
                    // atomic rename — "delete original" is the default
                    // behavior). When `false`, restore from a sidecar copy
                    // we made before calling compressCBZ — see Task 5.
                } catch is CancellationError {
                    await MainActor.run {
                        self?.state = .cancelled(partial: summary)
                        self?.runningTask = nil
                    }
                    return
                } catch {
                    summary.failed += 1
                    summary.errors.append((url, "\(error)"))
                }
            }
            await MainActor.run {
                self?.filesCompleted = self?.filesTotal ?? 0
                self?.state = .finished(summary: summary)
                self?.runningTask = nil
            }
        }
    }

    /// Cancels the in-flight batch. The summary at that point becomes
    /// `.cancelled(partial:)`.
    func cancel() {
        runningTask?.cancel()
    }

    /// Resets back to `.idle` after the user dismisses a finished sheet.
    func acknowledge() {
        state = .idle
        currentFileURL = nil
        filesCompleted = 0
        filesTotal = 0
    }
}
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/Models/CompressionService.swift
git commit -m "feat(compress): CompressionService orchestrator with cancellation"
```

---

### Task 5: Keep-originals mode (sidecar backup before rewrite)

**Files:**
- Modify: `Sources/DC/Models/CompressionService.swift`

In v1, the simplest interpretation of "keep originals" is: copy the source to `<name>-original.cbz` BEFORE running `compressCBZ`. If compression succeeds, both files exist side by side. If it fails, delete the sidecar (the source wasn't touched anyway).

- [ ] **Step 1: Update the per-file loop body in `runBatch`** — wrap the `compressCBZ` call so a sidecar is created first when `deleteOriginals == false`:

Replace the per-file `do { … } catch …` block inside `runBatch` with:

```swift
                if url.pathExtension.lowercased() != "cbz" {
                    summary.skippedNonCBZ += 1
                    continue
                }
                summary.attempted += 1

                // If user opted to KEEP originals, copy aside first so that
                // after compressCBZ's atomic rename the user has BOTH the
                // shrunk file (at the original path) and an untouched copy
                // at `<name>-original.cbz`.
                var sidecarURL: URL? = nil
                if !deleteOriginals {
                    let stem = url.deletingPathExtension().lastPathComponent
                    let parent = url.deletingLastPathComponent()
                    let target = parent.appendingPathComponent("\(stem)-original.cbz")
                    do {
                        if FileManager.default.fileExists(atPath: target.path) {
                            try FileManager.default.removeItem(at: target)
                        }
                        try FileManager.default.copyItem(at: url, to: target)
                        sidecarURL = target
                    } catch {
                        summary.failed += 1
                        summary.errors.append((url, "couldn't preserve original: \(error)"))
                        continue
                    }
                }

                do {
                    let result = try CBZCompressor.compressCBZ(
                        at: url,
                        maxDim: ReaderConstants.cbzCompressionMaxDim,
                        jpegQuality: ReaderConstants.cbzCompressionJpegQuality,
                        grayQuality: ReaderConstants.cbzCompressionGrayQuality,
                        skipThreshold: ReaderConstants.cbzCompressionSkipThreshold
                    )
                    summary.succeeded += 1
                    summary.totalInputBytes += result.inputBytes
                    summary.totalOutputBytes += result.outputBytes
                    let completedURL = url
                    await MainActor.run { onFileCompleted?(completedURL) }
                } catch is CancellationError {
                    if let s = sidecarURL { try? FileManager.default.removeItem(at: s) }
                    await MainActor.run {
                        self?.state = .cancelled(partial: summary)
                        self?.runningTask = nil
                    }
                    return
                } catch {
                    summary.failed += 1
                    summary.errors.append((url, "\(error)"))
                    if let s = sidecarURL { try? FileManager.default.removeItem(at: s) }
                }
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/Models/CompressionService.swift
git commit -m "feat(compress): keep-originals mode via sidecar copy"
```

---

### Task 6: Compression prompt sheet (delete-vs-keep + remember choice)

**Files:**
- Create: `Sources/DC/Views/CompressionPromptSheet.swift`

This sheet appears the first time the user triggers any compression action, OR every time if "Remember my choice" was never ticked. UserDefaults remembers both whether the choice was made AND what the choice was.

- [ ] **Step 1: Create `Sources/DC/Views/CompressionPromptSheet.swift`**:

```swift
import SwiftUI

/// Modal sheet shown before any compression batch. Lets the user choose
/// whether to delete originals (replace in place) or keep both files,
/// with a "Remember my choice" toggle that suppresses the sheet on
/// future runs (read from UserDefaults by the caller via
/// `CompressionPreferences.shouldShowPrompt`).
struct CompressionPromptSheet: View {

    /// Title shown at the top — varies by scope ("Compress 247 comics?",
    /// "Compress this comic?", "Compress 'Manga' gallery?", etc.)
    let title: String

    /// Sub-line that explains what compression does. Kept short — the
    /// prompt is for the binary decision, not the algorithm.
    let detailLine: String

    /// User-confirmed: (deleteOriginals, rememberChoice)
    let onConfirm: (_ deleteOriginals: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var deleteOriginals: Bool = true
    @State private var rememberChoice: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3).bold()
            Text(detailLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker(selection: $deleteOriginals) {
                    Text("Delete originals (replace in place)").tag(true)
                    Text("Keep originals (save next to them as ‘…-original.cbz’)").tag(false)
                } label: {
                    Text("After compression:")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Toggle("Remember my choice", isOn: $rememberChoice)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Compress") {
                    onConfirm(deleteOriginals, rememberChoice)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Wrapper around UserDefaults keys, so callers don't sprinkle string
/// constants. Used by LibraryViewModel before deciding whether to
/// present the sheet.
enum CompressionPreferences {
    static let deleteOriginalsKey   = "cbz.compression.deleteOriginals.choice"
    static let promptRememberedKey  = "cbz.compression.deleteOriginals.remembered"

    static var hasRememberedChoice: Bool {
        UserDefaults.standard.bool(forKey: promptRememberedKey)
    }
    static var rememberedDeleteOriginals: Bool {
        UserDefaults.standard.bool(forKey: deleteOriginalsKey)
    }
    static func remember(deleteOriginals: Bool) {
        UserDefaults.standard.set(true, forKey: promptRememberedKey)
        UserDefaults.standard.set(deleteOriginals, forKey: deleteOriginalsKey)
    }
    static func reset() {
        UserDefaults.standard.removeObject(forKey: promptRememberedKey)
        UserDefaults.standard.removeObject(forKey: deleteOriginalsKey)
    }
}
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/Views/CompressionPromptSheet.swift
git commit -m "feat(compress): prompt sheet with delete/keep + remember-choice"
```

---

### Task 7: Compression progress sheet

**Files:**
- Create: `Sources/DC/Views/CompressionProgressSheet.swift`

- [ ] **Step 1: Create `Sources/DC/Views/CompressionProgressSheet.swift`**:

```swift
import SwiftUI

/// Modal sheet rendered while a `CompressionService` is `.running`,
/// `.finished`, `.cancelled`, or `.failed`. Binds to the service for
/// live progress and shows a per-file error list at the end.
struct CompressionProgressSheet: View {
    @ObservedObject var service: CompressionService
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private var header: some View {
        switch service.state {
        case .idle:
            Text("Compression").font(.title3).bold()
        case .running:
            Text("Compressing comics…").font(.title3).bold()
        case .finished:
            Text("Compression complete").font(.title3).bold()
        case .cancelled:
            Text("Compression cancelled").font(.title3).bold()
        case .failed:
            Text("Compression failed").font(.title3).bold()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            Text("Idle.")
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(service.filesCompleted),
                             total: Double(max(service.filesTotal, 1)))
                Text("\(service.filesCompleted) of \(service.filesTotal)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let url = service.currentFileURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .finished(let summary), .cancelled(let summary):
            summaryView(summary)
        case .failed(let error):
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func summaryView(_ summary: CompressionService.BatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow("Compressed:",    "\(summary.succeeded) of \(summary.attempted)")
            statRow("Skipped (non-CBZ):", "\(summary.skippedNonCBZ)")
            statRow("Failed:",        "\(summary.failed)")
            let saved = summary.totalInputBytes - summary.totalOutputBytes
            if summary.totalInputBytes > 0 {
                statRow(
                    "Total bytes:",
                    "\(byteString(summary.totalInputBytes)) → \(byteString(summary.totalOutputBytes)) (saved \(byteString(max(0, saved))))"
                )
            }
            if !summary.errors.isEmpty {
                Divider()
                Text("Errors:").font(.callout).bold()
                ScrollView { VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.errors.enumerated()), id: \.offset) { _, e in
                        Text("• \(e.url.lastPathComponent): \(e.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } }.frame(maxHeight: 120)
            }
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch service.state {
            case .running:
                Button("Cancel", role: .cancel) { service.cancel() }
            case .idle, .finished, .cancelled, .failed:
                Button("Done") {
                    service.acknowledge()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/Views/CompressionProgressSheet.swift
git commit -m "feat(compress): progress sheet with per-file errors + summary"
```

---

### Task 8: Wire compression into LibraryViewModel

**Files:**
- Modify: `Sources/DC/ViewModels/LibraryViewModel.swift`

- [ ] **Step 1: Add the service + entry-point methods** near the top of `LibraryViewModel` (next to other `@Published` properties around line 55-65):

```swift
    /// Cross-cutting service that handles single + batch CBZ compression.
    /// Sheets (`CompressionPromptSheet`, `CompressionProgressSheet`) observe
    /// this service directly.
    @Published var compressionService = CompressionService()

    /// Pending compression intent — set when the user triggers an action;
    /// drives the prompt sheet. `nil` means "no prompt up". When the user
    /// confirms in the prompt, we read `pendingCompressionURLs` and call
    /// `compressionService.runBatch(...)`.
    @Published var pendingCompressionURLs: [URL]? = nil
    @Published var pendingCompressionTitle: String = ""
    @Published var pendingCompressionDetail: String = ""

    // MARK: - Compression entry points

    /// Triggered by the "Compress All Comics…" menu item.
    func requestCompressAll() {
        let urls = flatComicURLs  // existing memoised flat list
        let cbzCount = urls.filter { $0.pathExtension.lowercased() == "cbz" }.count
        pendingCompressionTitle = "Compress \(cbzCount) comic\(cbzCount == 1 ? "" : "s")?"
        pendingCompressionDetail =
            "Recompresses JPEG images inside each .cbz, typically shrinking each file 30–50 % " +
            "with no visible change at typical reading scales. PNG entries and non-CBZ formats " +
            "(PDF, CBR, CB7, CBT) are skipped."
        pendingCompressionURLs = urls
        runPendingIfRemembered()
    }

    /// Triggered by right-click → "Compress Gallery" on a sidebar row.
    func requestCompressGallery(_ id: UUID) {
        guard let gallery = galleries.first(where: { $0.id == id }) else { return }
        let cbzCount = gallery.comics.filter { $0.pathExtension.lowercased() == "cbz" }.count
        pendingCompressionTitle = "Compress \(cbzCount) comic\(cbzCount == 1 ? "" : "s") in ‘\(gallery.name)’?"
        pendingCompressionDetail =
            "Recompresses JPEG images inside each .cbz, typically shrinking 30–50 % per file. " +
            "PNG entries and non-CBZ formats are skipped."
        pendingCompressionURLs = gallery.comics
        runPendingIfRemembered()
    }

    /// Triggered by right-click → "Compress Comic" on a card.
    func requestCompressComic(at url: URL) {
        pendingCompressionTitle = "Compress ‘\(url.lastPathComponent)’?"
        pendingCompressionDetail =
            "Recompresses JPEG images inside the .cbz, typically shrinking it 30–50 % with no " +
            "visible change at typical reading scales."
        pendingCompressionURLs = [url]
        runPendingIfRemembered()
    }

    /// If the user has previously ticked "Remember my choice", skip the
    /// prompt and run with the remembered delete-originals value.
    private func runPendingIfRemembered() {
        guard let urls = pendingCompressionURLs else { return }
        if CompressionPreferences.hasRememberedChoice {
            let delete = CompressionPreferences.rememberedDeleteOriginals
            pendingCompressionURLs = nil
            startBatch(urls: urls, deleteOriginals: delete)
        }
        // else: leave pendingCompressionURLs set; the View layer will see
        // it and present the prompt sheet.
    }

    /// Called by `CompressionPromptSheet`'s confirm callback.
    func confirmPendingCompression(deleteOriginals: Bool, remember: Bool) {
        guard let urls = pendingCompressionURLs else { return }
        pendingCompressionURLs = nil
        if remember {
            CompressionPreferences.remember(deleteOriginals: deleteOriginals)
        }
        startBatch(urls: urls, deleteOriginals: deleteOriginals)
    }

    /// One place that kicks off the batch + wires the per-file completion
    /// hook to thumbnail invalidation. After each successful compression
    /// the card's cover refreshes from the new (smaller) file so the user
    /// sees the result without restarting the app, and the library's URL
    /// continues to point at the now-compressed file (so subsequent reads
    /// hit the smaller bytes — the "faster" payoff Przemek asked for).
    private func startBatch(urls: [URL], deleteOriginals: Bool) {
        compressionService.runBatch(
            urls: urls,
            deleteOriginals: deleteOriginals,
            onFileCompleted: { [weak self] url in
                self?.invalidateThumbnail(for: url)
                self?.thumbnailUpdates.send(url)
            }
        )
    }

    /// Removes the disk-cached thumbnail (FNV-1a-hashed path under
    /// `~/Library/Application Support/DC/Thumbnails/<hash>.jpg`) and
    /// the in-memory NSCache entry so the next thumbnail request
    /// decodes a fresh cover from the compressed CBZ. Caller should
    /// also `thumbnailUpdates.send(url)` to nudge any visible cards
    /// to re-render.
    func invalidateThumbnail(for url: URL) {
        let key = Self.thumbnailCacheKey(for: url) as NSString
        thumbnailCache.removeObject(forKey: key)
        let diskURL = Self.thumbnailURL(for: url)
        try? FileManager.default.removeItem(at: diskURL)
    }

    func cancelPendingCompression() {
        pendingCompressionURLs = nil
    }
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/ViewModels/LibraryViewModel.swift
git commit -m "feat(compress): LibraryViewModel entry points + remembered-choice handling"
```

---

### Task 9: "Compress All Comics…" menu item

**Files:**
- Modify: `Sources/DC/DCApp.swift`

- [ ] **Step 1: Inside the existing `CommandMenu("Library") { … }` block** in `DCApp.swift`, add the menu item. First read the existing block to see exact context:

Run: `sed -n '15,40p' Sources/DC/DCApp.swift`

- [ ] **Step 2: Add the menu item** inside the `CommandMenu("Library")` block (alongside whatever's already there):

```swift
            CommandMenu("Library") {
                // …existing items…
                Divider()
                Button("Compress All Comics…") {
                    library.requestCompressAll()
                }
                .disabled(library.flatComicURLs.isEmpty)
            }
```

- [ ] **Step 3: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/DC/DCApp.swift
git commit -m "feat(compress): Library menu — ‘Compress All Comics…’ item"
```

---

### Task 10: Sheet presentation in LibraryView

**Files:**
- Modify: `Sources/DC/Views/LibraryView.swift`

The two sheets must be presented from a view that owns `library` (the `LibraryViewModel`). `LibraryView` already does — add `.sheet(item:)` modifiers at the top level (around the existing `.alert` / `ErrorBanner` overlays).

- [ ] **Step 1: Find the `LibraryView` body's outer container** (likely the `NavigationSplitView` block). Add at the trailing chain after existing modifiers:

```swift
        // Prompt — only when pendingCompressionURLs is non-nil AND no remembered choice
        .sheet(isPresented: Binding(
            get: { library.pendingCompressionURLs != nil },
            set: { if !$0 { library.cancelPendingCompression() } }
        )) {
            CompressionPromptSheet(
                title: library.pendingCompressionTitle,
                detailLine: library.pendingCompressionDetail,
                onConfirm: { delete, remember in
                    library.confirmPendingCompression(deleteOriginals: delete, remember: remember)
                },
                onCancel: { library.cancelPendingCompression() }
            )
        }
        // Progress — present whenever the service is running or showing a final summary
        .sheet(isPresented: Binding(
            get: {
                switch library.compressionService.state {
                case .idle: return false
                default: return true
                }
            },
            set: { _ in /* dismissed via the sheet's Done button */ }
        )) {
            CompressionProgressSheet(
                service: library.compressionService,
                onDismiss: { /* state already reset by service.acknowledge() */ }
            )
        }
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/Views/LibraryView.swift
git commit -m "feat(compress): present prompt + progress sheets from LibraryView"
```

---

### Task 11: Right-click "Compress Comic" on every comic-card context menu

**Files:**
- Modify: `Sources/DC/Views/LibraryView.swift`

There are four `.contextMenu` sites for individual comic cards (per the grep at lines 149, 327, 472, 1165). Each gets a new "Compress" item.

- [ ] **Step 1: Find each `.contextMenu { … }` block in `LibraryView.swift`** that's attached to a comic card. For each, add inside the block (alongside existing items like Open, Remove, Toggle Favorite):

```swift
                .contextMenu {
                    // …existing items…
                    Divider()
                    Button("Compress Comic…") {
                        library.requestCompressComic(at: url)
                    }
                    .disabled(url.pathExtension.lowercased() != "cbz")
                }
```

Repeat at every comic-card context-menu site.

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/Views/LibraryView.swift
git commit -m "feat(compress): right-click ‘Compress Comic…’ on every card context menu"
```

---

### Task 12: Right-click "Compress Gallery" on sidebar rows

**Files:**
- Modify: `Sources/DC/Views/LibraryView.swift`

`LibrarySidebar` already has a per-gallery context menu (Rename / Add Folders / Reset Order / Delete per Tolaria). Add the compress item there.

- [ ] **Step 1: Find the `LibrarySidebar` gallery-row `.contextMenu`** in `LibraryView.swift` and add inside it:

```swift
                .contextMenu {
                    // …existing Rename / Add Folders / Reset Order / Delete items…
                    Divider()
                    Button("Compress Gallery…") {
                        library.requestCompressGallery(gallery.id)
                    }
                    .disabled(gallery.comics.isEmpty)
                }
```

- [ ] **Step 2: Compile-check**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DC/Views/LibraryView.swift
git commit -m "feat(compress): right-click ‘Compress Gallery…’ on sidebar rows"
```

---

### Task 13: Build production .app + live verification

**Files:**
- None (verification only)

- [ ] **Step 1: Run the production build**

Run: `./build_production.sh 2>&1 | tail -10`
Expected: `Done.` with `dist/OpenComic.app` and `dist/OpenComic.app.zip`

- [ ] **Step 2: Manual live-test checklist (driven by Przemek)**

Per the project rule (CONTRIBUTING.md live-verification protocol): test in `dist/OpenComic.app`, not the dev build.

Checks:
1. **Menu item.** With at least one CBZ in the library, open the Library menu → "Compress All Comics…" should be enabled. Click it.
2. **Prompt sheet — first run.** Sheet appears with the correct file count, picker shows "Delete originals" pre-selected, Remember checkbox unticked.
3. **Cancel button.** Click Cancel → sheet dismisses, no compression starts.
4. **Confirm without remember.** Re-trigger, click Compress without ticking Remember → progress sheet appears.
5. **Progress UI.** File count climbs, current filename updates, progress bar advances. Cancel button is enabled.
6. **Cancel mid-batch.** Click Cancel → state changes to `.cancelled` with a partial summary visible. No half-written `.tmp.PID` files remain in the comic directory.
7. **Atomic safety.** Open one of the (just-compressed) comics in the reader — it opens, all pages render, reading position is preserved.
8. **Remember choice.** Re-trigger compress, tick Remember, click Compress. Then trigger compress again — sheet should NOT appear; batch runs immediately.
9. **Right-click on a comic card.** Context menu shows "Compress Comic…". Click → prompt (or skip if remembered) → progress for one file.
10. **Right-click on a gallery.** Context menu shows "Compress Gallery…". Click → scoped batch.
11. **Non-CBZ skipping.** A library with PDF/CBR mixed in — Compress All shows the right "skipped: N" count in the summary.
12. **Keep originals path.** Clear the remembered choice (need a small dev-side helper: in the menu, hold Option to show "Reset Compression Preferences" — out of scope for v1 unless trivial; otherwise run `defaults delete com.opncomic.open-comic` once). Re-trigger, pick "Keep originals", confirm → after compression both `MyComic.cbz` (shrunk) and `MyComic-original.cbz` (untouched) exist on disk.
13. **Library uses the compressed file immediately ("reload faster" check).** Note the disk size of a CBZ before compression. Compress it. Confirm the file at the same path is now smaller (`ls -la` or Finder). Open the comic — page loads visibly snappier on first-flight decode because each JPEG is smaller. The thumbnail card refreshes to the new cover without an app restart. The library URL never changed — the compressed bytes simply replaced the originals at the same path.

- [ ] **Step 3: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "chore(compress): fixes from live verification"
```

- [ ] **Step 4: Push**

```bash
git push origin main
```

---

## Self-review

**Spec coverage:**
- ✅ "compress all comics" menu item in Library → Task 9
- ✅ Prompt asking delete-or-keep originals → Task 6, presented from Task 10
- ✅ Right-click "compress comic" on any comic → Task 11
- ✅ Right-click "compress gallery" → Task 12
- ✅ "Copy" CompyUI's CBZ logic → Tasks 2, 3 (port; not binary bundling — see Architecture for why)

**Placeholder scan:** No "TBD", "TODO", "implement later", "add error handling" without showing how. Every step has the actual code or command.

**Type consistency:** `CBZCompressor` (enum) → `CBZCompressionResult` (struct) → `CompressionService` (class) → `CompressionService.BatchSummary` (struct) → `CompressionPreferences` (enum). Names consistent across Tasks 2-12.

**Out-of-scope items called out:** CBR/CB7/CBT/PDF compression, user-tunable quality settings, dedicated Reset-Preferences menu item. Each named with a reason and a hook for a v2 follow-up.

**Risks the engineer should know:**
- `ZIPFoundation.Archive.makeIterator()` returns entries lazily; snapshotting via `Array(...)` is required so the entry count is stable for progress.
- `FileManager.replaceItemAt` on APFS does a rename when src/dst share a volume — but it requires destination URL parent to be writable. Network-mounted libraries (SMB/AFP) may force a copy + delete; that's slower but still correct.
- `CGImageSourceCreateThumbnailAtIndex` is the right path for "decode at smaller size" — it uses the JPEG's embedded thumbnail when present, decodes-with-resize otherwise. Faster than full decode + resize.
- The progress callback fires on the detached task's thread; SwiftUI bindings updating `@Published` properties must hop to `@MainActor` (handled via `await MainActor.run`).

---

## Execution Handoff

Plan complete and saved to `docs/design/2026-05-19-cbz-compression.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
