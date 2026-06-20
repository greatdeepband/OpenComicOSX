import Foundation
import AppKit
import PDFKit
import ZIPFoundation
import os

/// Loads a comic from disk into a `Comic` model.
/// Pages are NOT decoded into memory at load time — only file URLs / PDF page refs are stored.
/// Decoding happens lazily via `PageSource.decode()` when the reader needs a specific page.
enum ComicLoader {

    enum LoadError: LocalizedError {
        case unsupportedFormat(String)
        case noImagesFound
        case extractionFailed(String)
        /// Archive declares more entries than `maxArchiveEntries` (entry-count
        /// bomb) — the associated value is the declared count.
        case tooManyEntries(Int)
        /// Archive's declared uncompressed size exceeds `maxUncompressedBytes`
        /// (decompression bomb) — associated value is the declared total.
        case archiveTooLarge(Int64)
        /// An entry's path would escape the extraction directory (absolute
        /// path, `..` traversal, or an escaping symlink) — i.e. a zip-slip /
        /// tar-slip attack. Associated value is the offending entry name.
        case unsafeEntryPath(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext): return "Unsupported format: \(ext)"
            case .noImagesFound: return "No images found in the archive."
            case .extractionFailed(let msg): return "Extraction failed: \(msg)"
            case .tooManyEntries(let n): return "Archive declares too many entries (\(n)); refusing to extract."
            case .archiveTooLarge(let bytes): return "Archive declares an uncompressed size that is too large (\(bytes) bytes); refusing to extract."
            case .unsafeEntryPath(let path): return "Archive contains an unsafe entry path that would escape the extraction directory: \(path)"
            }
        }
    }

    /// Persistent directory where extracted comic pages are cached.
    /// Keyed by a hash of the comic URL so re-opening is instant.
    static let pageCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("DC/Pages")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Resolves the path to a bundled tool (unar or lsar).
    /// Checks the app bundle's Resources/bin first, then falls back to common Homebrew locations.
    private static func bundledToolPath(_ name: String) -> String {
        // 1. Bundled binary inside Open Comic.app/Contents/Resources/bin/
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("bin/\(name)")
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        // 2. Homebrew on Apple Silicon
        let arm = "/opt/homebrew/bin/\(name)"
        if FileManager.default.fileExists(atPath: arm) { return arm }
        // 3. Homebrew on Intel
        let intel = "/usr/local/bin/\(name)"
        if FileManager.default.fileExists(atPath: intel) { return intel }
        // 4. PATH fallback (will fail gracefully if not found)
        return name
    }

    static func load(url: URL) async throws -> Comic {
        guard let format = ComicFormat.from(url: url) else {
            throw LoadError.unsupportedFormat(url.pathExtension)
        }
        switch format {
        case .cbz:
            return try loadCBZ(url: url)
        case .pdf:
            return try await loadPDF(url: url)
        case .cbr, .cb7:
            return try loadWithUnar(url: url)
        case .cbt:
            return try loadTAR(url: url)
        }
    }

    // MARK: - Cover-only fast load (for thumbnails)

    static func loadCover(url: URL) async -> NSImage? {
        guard let format = ComicFormat.from(url: url) else { return nil }
        switch format {
        case .cbz:  return loadCoverCBZ(url: url)
        case .pdf:  return await loadCoverPDF(url: url)
        case .cbr, .cb7: return loadCoverWithUnar(url: url)
        case .cbt:  return loadCoverTAR(url: url)
        }
    }

    /// Fast path for bulk thumbnail generation: returns a CGImage already scaled
    /// to the 200×280 thumbnail canvas, skipping the NSImage wrapper entirely.
    /// This avoids the redundant scaledCGImage() pass in saveThumbnailAndCache.
    static func loadCoverCGImage(url: URL) async -> CGImage? {
        guard let format = ComicFormat.from(url: url) else { return nil }
        let maxPixels = 560  // 280pt × 2 Retina
        let w = 400, h = 560 // 200pt × 2 Retina

        // Get the raw thumbnail CGImage from the appropriate loader.
        let rawCG: CGImage?
        switch format {
        case .cbz:
            rawCG = loadCoverCGImageCBZ(url: url, maxPixels: maxPixels)
        case .pdf:
            rawCG = await loadCoverPDF(url: url).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        case .cbr, .cb7:
            rawCG = loadCoverWithUnar(url: url).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        case .cbt:
            rawCG = loadCoverTAR(url: url).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }
        guard let src = rawCG else { return nil }

        // Scale to exact 400×560 canvas in one CGContext pass.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium  // .medium is visually identical at this size, faster than .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// CBZ-specific fast path: streams the cover entry and returns a CGImage at maxPixels.
    private static func loadCoverCGImageCBZ(url: URL, maxPixels: Int) -> CGImage? {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            Task { await DCLogger.shared.log("[CBZ] cover-fast-path archive open failed for \(url.lastPathComponent): \(error)") }
            return nil
        }
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        let entries = archive
            .filter { $0.type == .file
                && imageExtensions.contains(($0.path as NSString).pathExtension.lowercased())
                && !$0.path.contains("__MACOSX") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard let firstEntry = entries.first else { return nil }

        let accumulated: Data
        do {
            accumulated = try archive.extractEntryData(firstEntry, cap: ReaderConstants.maxUncompressedBytes)
        } catch { return nil }
        let imageSource = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(imageSource, accumulated as CFData, true)

        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, opts as CFDictionary)
    }

    private static func loadCoverCBZ(url: URL) -> NSImage? {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            Task { await DCLogger.shared.log("[CBZ] cover archive open failed for \(url.lastPathComponent): \(error)") }
            return nil
        }

        // Find the first image entry by sorted path — no extraction needed.
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        let entries = archive
            .filter { entry in
                entry.type == .file
                && imageExtensions.contains((entry.path as NSString).pathExtension.lowercased())
                && !entry.path.contains("__MACOSX")
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard let firstEntry = entries.first else { return nil }

        // Extract the cover entry through the capped helper so a lying central
        // directory cannot inflate an attacker-controlled entry without bound.
        let coverData: Data
        do {
            coverData = try archive.extractEntryData(firstEntry, cap: ReaderConstants.maxUncompressedBytes)
        } catch {
            Task { await DCLogger.shared.log("[CBZ] capped extract failed for \(url.lastPathComponent): \(error)") }
            return nil
        }
        let imageSource = CGImageSourceCreateIncremental(nil)
        // Feed the full (bounded) bytes and signal end-of-data in one step.
        CGImageSourceUpdateData(imageSource, coverData as CFData, true)

        // Decode at thumbnail resolution — never loads the full-res bitmap.
        let maxPixels = 560
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary)
        else { return nil }

        return NSImage(cgImage: cgThumb, size: .zero)
    }

    /// PDF cover render. PDFKit is not thread-safe and covers are loaded with
    /// concurrency (see `LibraryViewModel`'s `withTaskGroup`), so the page draw
    /// is owned by `PDFKitGate`'s serial executor. The gate renders into a BGRA
    /// `CVPixelBuffer` at the page's natural (2×) size, which is then wrapped as
    /// an `NSImage`; the caller downscales to the thumbnail canvas afterwards.
    private static func loadCoverPDF(url: URL) async -> NSImage? {
        guard let doc = PDFDocument(url: url) else { return nil }
        guard await PDFKitGate.shared.pageCount(doc) > 0 else { return nil }
        let size = await PDFKitGate.shared.naturalSize(doc, index: 0)
        guard let buffer = await PDFKitGate.shared.renderPage(doc, index: 0, pixelSize: size) else {
            return nil
        }
        return makeNSImageFromPixelBuffer(buffer)
    }

    private static func loadCoverTAR(url: URL) -> NSImage? {
        // List entries with tar -tf, find the first image, extract only that file.
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        guard let listing = shellOutputFull(systemTarPath, args: ["-tf", url.path]) else { return nil }
        let firstImage = listing
            .components(separatedBy: "\n")
            .filter { line in
                let ext = (line as NSString).pathExtension.lowercased()
                return imageExtensions.contains(ext) && !line.contains("__MACOSX")
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
        guard let entryPath = firstImage else { return nil }
        // `entryPath` is a member name from the archive's own listing — i.e.
        // attacker-controlled for a downloaded comic. Reject a name that would
        // escape the extraction directory (absolute / `..`) before we ask tar
        // to write it. (The cover path is best-effort, so we just bail to nil.)
        guard !isUnsafeEntryName(entryPath) else {
            Task { await DCLogger.shared.log("[CBT] cover entry name rejected as unsafe: \(entryPath)") }
            return nil
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Extract only the single cover entry. `entryPath` is a member name
        // read out of the archive's own listing — i.e. attacker-controlled for
        // a downloaded comic. bsdtar permutes options after operands, so a
        // member named like `--use-compress-program=…` would otherwise be
        // parsed as an option and execute an arbitrary program. The `--`
        // separator forces everything after it to be treated as an operand
        // (a member name to extract), never an option.
        let result = shellFull(systemTarPath, args: ["-xf", url.path, "-C", tmpDir.path, "--", entryPath])
        guard result == 0 else { return nil }
        return firstImageInDirectory(tmpDir)
    }

    private static func loadCoverWithUnar(url: URL) -> NSImage? {
        let unarPath = bundledToolPath("unar")
        let lsarPath = bundledToolPath("lsar")
        // Use lsar -j (JSON) to list entries — avoids whitespace-splitting bugs with
        // filenames that contain spaces. Parse XADFileName for each entry.
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        guard let jsonStr = shellOutputFull(lsarPath, args: ["-j", url.path]),
              let jsonData = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let contents = root["lsarContents"] as? [[String: Any]]
        else {
            Task { await DCLogger.shared.log("[CBR] lsar -j listing unavailable/unparseable for \(url.lastPathComponent) — falling back to full extraction") }
            return loadCoverWithUnarFull(url: url)
        }
        let firstImage = contents
            .compactMap { $0["XADFileName"] as? String }
            .filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return imageExtensions.contains(ext) && !name.contains("__MACOSX")
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
        guard let entryPath = firstImage else { return loadCoverWithUnarFull(url: url) }
        // `entryPath` comes from the archive's own listing (attacker-controlled
        // for a downloaded comic). unar is not getopt-based, so it has no `--`
        // end-of-options separator — the only way a member name can be misread
        // as a flag is if it begins with "-". In that case skip the single-file
        // optimization and fall back to full extraction, which passes no
        // member operand at all and so cannot be confused for an option.
        guard !entryPath.hasPrefix("-") else { return loadCoverWithUnarFull(url: url) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Extract only the single cover entry.
        let result = shellFull(unarPath, args: ["-o", tmpDir.path, "-force-overwrite", url.path, entryPath])
        guard result == 0 else { return loadCoverWithUnarFull(url: url) }
        return firstImageInDirectory(tmpDir)
    }

    /// Fallback: full extraction when lsar is unavailable or the single-file extract fails.
    private static func loadCoverWithUnarFull(url: URL) -> NSImage? {
        let unarPath = bundledToolPath("unar")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let result = shellFull(unarPath, args: ["-o", tmpDir.path, "-force-overwrite", url.path])
        guard result == 0 else { return nil }
        return firstImageInDirectory(tmpDir)
    }

    private static func firstImageInDirectory(_ dir: URL) -> NSImage? {
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var imageFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            if fileURL.pathComponents.contains("__MACOSX") { continue }
            imageFiles.append(fileURL)
        }
        imageFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard let first = imageFiles.first else { return nil }
        return scaledCoverImage(from: first)
    }

    /// Loads a cover image scaled to the thumbnail canvas size using CGImageSource.
    /// This avoids decoding the full-resolution bitmap into RAM — the OS scales the
    /// image during decode, keeping peak memory per extraction to ~1–2 MB instead
    /// of the 50–100 MB a full-res comic page would require.
    private static func scaledCoverImage(from url: URL) -> NSImage? {
        // Thumbnail target: 2× the logical thumbnail size to cover Retina displays.
        let maxPixels = 560  // 280 pt × 2 (Retina)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else {
            // Fallback: load full image (e.g. for unusual formats CGImageSource can't thumbnail).
            guard let image = NSImage(contentsOf: url) else { return nil }
            image.lockFocus(); image.unlockFocus()
            return image
        }
        return NSImage(cgImage: cgThumb, size: .zero)
    }

    // MARK: - CBZ (ZIP)

    private static func loadCBZ(url: URL) throws -> Comic {
        // Load entire CBZ into RAM upfront. This eliminates all disk IO during
        // scrolling — page decodes read from memory instead of re-opening the
        // ZIP file on disk for every page.
        // Memory cost: compressed file size (50-200 MB typical).
        let archiveData: Data
        do {
            // .mappedIfSafe lets the OS page the file in lazily on local
            // storage (no upfront full-file RAM copy); it transparently falls
            // back to a normal read on network/removable volumes where mmap is
            // unsafe. Page decodes then read from the mapped bytes on demand.
            archiveData = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            Task { await DCLogger.shared.log("[CBZ] Data(contentsOf:) failed for \(url.lastPathComponent): \(error)") }
            throw LoadError.extractionFailed("Could not read ZIP archive from disk: \(error.localizedDescription)")
        }
        let archive: Archive
        do {
            archive = try Archive(data: archiveData, accessMode: .read)
        } catch {
            Task { await DCLogger.shared.log("[CBZ] Archive(data:) failed for \(url.lastPathComponent): \(error)") }
            throw LoadError.extractionFailed("Could not open ZIP archive: \(error.localizedDescription)")
        }
        // Pre-flight validation (zip-slip + entry-count + declared-size bomb).
        // CBZ defers actual decompression to decode time, so this only trusts
        // the central directory; a lying central directory is caught at first
        // decode by the streaming counter in `Comic.swift`'s `.zipData` path.
        try validateCBZ(archive)
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "avif"])
        let entries = archive
            .filter { entry in
                entry.type == .file
                && imageExtensions.contains((entry.path as NSString).pathExtension.lowercased())
                && !entry.path.contains("__MACOSX")
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !entries.isEmpty else { throw LoadError.noImagesFound }
        let pages: [ComicPage] = entries.enumerated().map { (idx, entry) in
            ComicPage(id: idx, source: .zipData(archiveData, entry.path))
        }
        return Comic(url: url, format: .cbz, pages: pages)
    }

    // MARK: - PDF

    private static func loadPDF(url: URL) async throws -> Comic {
        guard let doc = PDFDocument(url: url) else {
            throw LoadError.extractionFailed("Could not open PDF.")
        }
        // All PDFKit access goes through the gate. Page count and per-page
        // natural size are read on the gate's serial executor, then injected
        // into each `ComicPage` so the (non-thread-safe) `PageSource.naturalSize`
        // `.pdf` branch is never invoked at runtime.
        let count = await PDFKitGate.shared.pageCount(doc)
        var pages: [ComicPage] = []
        for i in 0..<count {
            let sz = await PDFKitGate.shared.naturalSize(doc, index: i)
            pages.append(ComicPage(id: i, source: .pdf(doc, i), naturalSize: sz))
        }
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        return Comic(url: url, format: .pdf, pages: pages)
    }

    // MARK: - Pre-extraction validation (zip-slip + decompression-bomb caps)

    /// True if a member NAME alone is unsafe — i.e. it would write outside the
    /// extraction directory. Catches absolute paths and any `..` traversal
    /// component. Reused at the cover paths (`loadCoverTAR`) where the chosen
    /// entry name is attacker-controlled.
    private static func isUnsafeEntryName(_ name: String) -> Bool {
        if name.hasPrefix("/") { return true }                 // absolute
        // Normalise to forward-slash components and reject any `..` segment.
        let components = name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return components.contains("..")
    }

    /// True if a SYMLINK escapes the extraction directory. Resolves the link
    /// target relative to the link's own directory and rejects a target that is
    /// absolute or climbs above the root. The link entry's own name is assumed
    /// already checked via `isUnsafeEntryName`.
    private static func symlinkEscapes(entryName: String, target: String) -> Bool {
        if target.hasPrefix("/") { return true }               // absolute target
        let entryDir = (entryName as NSString).deletingLastPathComponent
        // Resolve the target relative to the link's own directory, then walk the
        // components keeping a running depth below the extraction root. A `..`
        // that pops the depth below zero at any point means the link escapes the
        // root — regardless of where in the path it appears (so
        // `pages/../../etc/passwd` is caught, not just a leading `..`).
        let joined = entryDir.isEmpty ? target : entryDir + "/" + target
        var depth = 0
        for component in joined.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            if component == ".." {
                depth -= 1
                if depth < 0 { return true }   // climbed above the root
            } else {
                depth += 1
            }
        }
        return false
    }

    /// Validates a tar (CBT) archive before extraction: lists entry NAMES with
    /// `tar -tf` (robust — never parses the locale/space-fragile `-tv` size
    /// columns), enforces the entry-count cap, and rejects any zip-slip name.
    /// tar listings do not reliably expose per-entry uncompressed size, so the
    /// size bomb cap is NOT enforced here (documented limitation — entry-count
    /// cap only for CBT).
    private static func validateTAR(url: URL) throws {
        guard let listing = shellOutputFull(systemTarPath, args: ["-tf", url.path]) else {
            throw LoadError.extractionFailed("tar listing failed")
        }
        let names = listing.components(separatedBy: "\n").filter { !$0.isEmpty }
        if names.count > ReaderConstants.maxArchiveEntries {
            throw LoadError.tooManyEntries(names.count)
        }
        for name in names where isUnsafeEntryName(name) {
            throw LoadError.unsafeEntryPath(name)
        }
        // CBT: per-entry size not reliably available from tar; entry-count cap
        // is the only bomb guard. Streaming size is still bounded at decode of
        // the extracted files via the OS image decoder's own limits.
    }

    /// Validates a CBR/CB7 archive before extraction using `lsar -j` JSON:
    /// entry-count cap, zip-slip names, escaping symlinks, and the uncompressed
    /// size cap (sum of `XADFileSize`). Solid-RAR fallback: if total size sums
    /// to 0 while entries exist (lsar can omit `XADFileSize` for solid blocks),
    /// fall back to a tighter 1_000-entry cap and log.
    private static func validateUnar(url: URL) throws {
        let lsarPath = bundledToolPath("lsar")
        guard let jsonStr = shellOutputFull(lsarPath, args: ["-j", url.path]),
              let jsonData = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let contents = root["lsarContents"] as? [[String: Any]]
        else {
            // lsar unavailable/unparseable — let extraction proceed (it will
            // fail loudly if the archive is genuinely broken). Logged for audit.
            Task { await DCLogger.shared.log("[CBR] lsar -j listing unavailable/unparseable for \(url.lastPathComponent) — skipping pre-flight validation") }
            return
        }
        if contents.count > ReaderConstants.maxArchiveEntries {
            throw LoadError.tooManyEntries(contents.count)
        }
        var totalSize: Int64 = 0
        for entry in contents {
            guard let name = entry["XADFileName"] as? String else { continue }
            if isUnsafeEntryName(name) { throw LoadError.unsafeEntryPath(name) }
            // Symlink escape test.
            let isSymlink = (entry["XADIsSymbolicLink"] as? NSNumber)?.boolValue
                ?? (entry["XADIsSymbolicLink"] as? Bool) ?? false
            if isSymlink, let target = entry["XADLinkDestination"] as? String,
               symlinkEscapes(entryName: name, target: target) {
                throw LoadError.unsafeEntryPath(name)
            }
            if let size = entry["XADFileSize"] as? Int64 {
                totalSize += size
            } else if let size = (entry["XADFileSize"] as? NSNumber)?.int64Value {
                totalSize += size
            }
        }
        if totalSize == 0 && !contents.isEmpty {
            // Solid-RAR or a format where lsar omits per-entry sizes. We can't
            // sum a bomb cap, so apply a tighter entry-count cap instead.
            if contents.count > 1_000 {
                Task { await DCLogger.shared.log("[CBR] solid-archive size unavailable for \(url.lastPathComponent); applying 1_000-entry cap (\(contents.count) entries)") }
                throw LoadError.tooManyEntries(contents.count)
            }
            Task { await DCLogger.shared.log("[CBR] solid-archive size unavailable for \(url.lastPathComponent); proceeding under 1_000-entry cap (\(contents.count) entries)") }
        } else if totalSize > ReaderConstants.maxUncompressedBytes {
            throw LoadError.archiveTooLarge(totalSize)
        }
    }

    /// Validates a CBZ archive before its (deferred) decode by walking the
    /// central directory: entry-count cap, zip-slip names, escaping symlinks,
    /// and the uncompressed size cap (sum of central-dir `uncompressedSize`).
    /// NOTE: because `loadCBZ` defers extraction to decode time, this pre-flight
    /// sum trusts the central directory; a *lying* central directory is caught
    /// only at first decode by the streaming byte counter in `Comic.swift`.
    private static func validateCBZ(_ archive: Archive) throws {
        var count = 0
        var totalSize: Int64 = 0
        for entry in archive {
            count += 1
            if count > ReaderConstants.maxArchiveEntries {
                throw LoadError.tooManyEntries(count)
            }
            let path = entry.path
            if isUnsafeEntryName(path) { throw LoadError.unsafeEntryPath(path) }
            if entry.type == .symlink {
                // Read the link target (stored as the entry's content) and test
                // for escape. Cheap — symlink bodies are a few bytes; the cap
                // guards against a malicious .symlink entry with a huge body.
                let targetData = (try? archive.extractEntryData(
                    entry, cap: ReaderConstants.maxUncompressedBytes, skipCRC32: true)) ?? Data()
                if let target = String(data: targetData, encoding: .utf8),
                   symlinkEscapes(entryName: path, target: target) {
                    throw LoadError.unsafeEntryPath(path)
                }
            }
            totalSize += Int64(entry.uncompressedSize)
        }
        if totalSize > ReaderConstants.maxUncompressedBytes {
            throw LoadError.archiveTooLarge(totalSize)
        }
    }

    // MARK: - TAR (CBT)

    private static func loadTAR(url: URL) throws -> Comic {
        let cacheDir = persistentPageCacheDir(for: url)

        if !isCacheStale(cacheDir: cacheDir, sourceURL: url) {
            let pages = try pagesFromDirectory(cacheDir)
            if !pages.isEmpty { return Comic(url: url, format: .cbt, pages: pages) }
        }

        // Pre-extraction validation (zip-slip + entry-count bomb) — BEFORE we
        // write anything to disk.
        try validateTAR(url: url)

        try? FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Clean up the cacheDir on any failure AFTER this point. `success` is
        // flipped immediately after the non-empty page check below (BEFORE the
        // best-effort manifest write); the manifest is not a success condition,
        // and the pages point INTO cacheDir so a premature delete corrupts a
        // good load.
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: cacheDir) } }

        let result = shellFull(systemTarPath, args: ["-xf", url.path, "-C", cacheDir.path])
        guard result == 0 else { throw LoadError.extractionFailed("tar exited \(result)") }

        let pages = try pagesFromDirectory(cacheDir)
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        success = true
        let comic = Comic(url: url, format: .cbt, pages: pages)
        // Write cache manifest for content-based staleness check on next open.
        if let meta = tarArchiveMetadata(url: url) {
            saveManifest(for: cacheDir, entryCount: meta.entryCount, totalUncompressedSize: meta.totalUncompressedSize, sourceURL: url)
        }
        Task.detached(priority: .background) { prunePageCache(keepCount: 5) }
        return comic
    }

    // MARK: - CBR / CB7 via unar

    private static func loadWithUnar(url: URL) throws -> Comic {
        let unarPath = bundledToolPath("unar")

        let cacheDir = persistentPageCacheDir(for: url)

        if !isCacheStale(cacheDir: cacheDir, sourceURL: url) {
            let pages = try pagesFromDirectory(cacheDir)
            if !pages.isEmpty {
                return Comic(url: url, format: ComicFormat.from(url: url)!, pages: pages)
            }
        }

        // Pre-extraction validation (zip-slip + entry-count + size bomb) —
        // BEFORE we write anything to disk.
        try validateUnar(url: url)

        try? FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Clean up cacheDir on any failure after this point. success flips
        // immediately after the non-empty page check (before the manifest).
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: cacheDir) } }

        let result = shellFull(unarPath, args: ["-o", cacheDir.path, "-force-overwrite", url.path])
        guard result == 0 else {
            throw LoadError.extractionFailed(
                "unar failed (exit \(result)). Make sure unar is installed: brew install unar"
            )
        }

        let pages = try pagesFromDirectory(cacheDir)
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        success = true
        let comic = Comic(url: url, format: ComicFormat.from(url: url)!, pages: pages)
        // Write cache manifest for content-based staleness check on next open.
        if let meta = unrarArchiveMetadata(url: url) {
            saveManifest(for: cacheDir, entryCount: meta.entryCount, totalUncompressedSize: meta.totalUncompressedSize, sourceURL: url)
        }
        // Prune old cache entries — keep only the 5 most recently opened.
        Task.detached(priority: .background) { prunePageCache(keepCount: 5) }
        return comic
    }

    // MARK: - Persistent cache helpers

    /// FNV-1a hash — stable across processes (unlike Swift's hashValue).
    private static func stablePageHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    /// Returns the persistent cache directory for a comic's extracted pages.
    static func persistentPageCacheDir(for url: URL) -> URL {
        let hash = stablePageHash(url.path)
        return pageCacheDir.appendingPathComponent("\(hash)")
    }

    /// Keeps only the N most-recently-modified cache directories, deletes the rest.
    static func prunePageCache(keepCount: Int = 5) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pageCacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let sorted = entries
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in sorted.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Cache manifest (content-based staleness)

    /// Content-based cache validation — avoids fragile mtime comparison.
    struct CacheManifest: Codable {
        let entryCount: Int
        let totalUncompressedSize: Int64
        let sourcePath: String
        let sourceMtime: Double
    }

    /// Path to the manifest file inside a cache directory.
    private static func manifestURL(for cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent(".dc_cache_manifest.json")
    }

    /// Loads the cache manifest if it exists.
    private static func loadManifest(for cacheDir: URL) -> CacheManifest? {
        let url = manifestURL(for: cacheDir)
        // Absent file is the normal cold-cache path; only log decode failures.
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(CacheManifest.self, from: data)
        } catch {
            Task { await DCLogger.shared.log("[CACHE] Manifest decode failed at \(url.path): \(error) — will rebuild cache") }
            return nil
        }
    }

    /// Saves a cache manifest after successful extraction.
    private static func saveManifest(for cacheDir: URL, entryCount: Int, totalUncompressedSize: Int64, sourceURL: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let manifest = CacheManifest(
            entryCount: entryCount,
            totalUncompressedSize: totalUncompressedSize,
            sourcePath: sourceURL.path,
            sourceMtime: mtime
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(manifest)
        } catch {
            Task { await DCLogger.shared.log("[CACHE] Manifest encode failed for \(sourceURL.lastPathComponent): \(error)") }
            return
        }
        do {
            try data.write(to: manifestURL(for: cacheDir))
        } catch {
            Task { await DCLogger.shared.log("[CACHE] Manifest write failed at \(manifestURL(for: cacheDir).path): \(error)") }
        }
    }

    /// Returns true if the cache doesn't exist, the manifest is missing, or the content
    /// doesn't match the source (entry count or total size changed).
    private static func isCacheStale(cacheDir: URL, sourceURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return true }
        guard let manifest = loadManifest(for: cacheDir) else { return true }
        // Source path must match.
        guard manifest.sourcePath == sourceURL.path else { return true }
        // Get current archive metadata.
        let format = ComicFormat.from(url: sourceURL)
        let metadata = archiveMetadata(for: sourceURL, format: format)
        guard let meta = metadata else { return true }
        // Entry count must match.
        guard meta.entryCount == manifest.entryCount else { return true }
        // For formats that report total size, compare it.
        if manifest.totalUncompressedSize > 0,
           meta.totalUncompressedSize != manifest.totalUncompressedSize {
            return true
        }
        return false
    }

    /// Archive metadata for content-based cache validation.
    private struct ArchiveMetadata {
        let entryCount: Int
        let totalUncompressedSize: Int64
    }

    /// Reads archive metadata without full decompression.
    private static func archiveMetadata(for url: URL, format: ComicFormat?) -> ArchiveMetadata? {
        guard let format else { return nil }
        switch format {
        case .cbz:  return cbzArchiveMetadata(url: url)
        case .cbr, .cb7: return unrarArchiveMetadata(url: url)
        case .cbt:  return tarArchiveMetadata(url: url)
        case .pdf: return nil
        }
    }

    /// Reads ZIP central directory to get entry count and total uncompressed size.
    private static func cbzArchiveMetadata(url: URL) -> ArchiveMetadata? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "avif"])
        var count = 0
        var totalSize: Int64 = 0
        for entry in archive {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext), !entry.path.contains("__MACOSX") else { continue }
            count += 1
            totalSize += Int64(entry.uncompressedSize)
        }
        return ArchiveMetadata(entryCount: count, totalUncompressedSize: totalSize)
    }

    /// Parses lsar -j JSON output to get image entry count and total XADFileSize.
    private static func unrarArchiveMetadata(url: URL) -> ArchiveMetadata? {
        let lsarPath = bundledToolPath("lsar")
        guard let jsonStr = shellOutputFull(lsarPath, args: ["-j", url.path]),
              let jsonData = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let contents = root["lsarContents"] as? [[String: Any]]
        else { return nil }
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        var count = 0
        var totalSize: Int64 = 0
        for entry in contents {
            guard let name = entry["XADFileName"] as? String else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext), !name.contains("__MACOSX") else { continue }
            count += 1
            if let size = entry["XADFileSize"] as? Int64 {
                totalSize += size
            }
        }
        return ArchiveMetadata(entryCount: count, totalUncompressedSize: totalSize)
    }

    /// Uses tar -tf to get image entry count (size not available from tar listing).
    private static func tarArchiveMetadata(url: URL) -> ArchiveMetadata? {
        guard let listing = shellOutputFull(systemTarPath, args: ["-tf", url.path]) else { return nil }
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        let count = listing
            .components(separatedBy: "\n")
            .filter { line in
                let ext = (line as NSString).pathExtension.lowercased()
                return imageExtensions.contains(ext) && !line.contains("__MACOSX")
            }
            .count
        return ArchiveMetadata(entryCount: count, totalUncompressedSize: 0)
    }

    /// Builds ComicPage array from image files in a directory (no decoding).
    private static func pagesFromDirectory(_ dir: URL) throws -> [ComicPage] {
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "avif"])

        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var imageFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            if fileURL.pathComponents.contains("__MACOSX") { continue }
            imageFiles.append(fileURL)
        }

        imageFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        return imageFiles.enumerated().map { (idx, fileURL) in
            ComicPage(id: idx, source: .file(fileURL))
        }
    }

    // MARK: - Shell helpers

    /// Absolute path to the system tar. We invoke this directly rather than via
    /// `/usr/bin/env tar` so a poisoned `PATH` can never substitute a different
    /// `tar` binary. (`unar`/`lsar` are likewise resolved to absolute paths via
    /// `bundledToolPath`.)
    private static let systemTarPath = "/usr/bin/tar"

    // NOTE on the two helpers below: each does `try task.run()` inside a
    // do/catch rather than `try?`. Reading `terminationStatus` (or calling
    // `waitUntilExit`) on a Process that never launched raises an ObjC
    // `NSInvalidArgumentException` — an uncatchable crash. `run()` throws when
    // the executable is missing, which is exactly the `bundledToolPath`
    // bare-name fallback case (`unar`/`lsar` neither bundled nor in Homebrew).
    // Returning a failure sentinel here lets callers fall back gracefully.
    //
    // Both arm a watchdog (see `armWatchdog`) BEFORE the blocking
    // `waitUntilExit()`/`readDataToEndOfFile()`. A malicious or corrupt archive
    // can wedge the child forever; the watchdog terminates then kills it after
    // `ReaderConstants.subprocessTimeout`. Killing the child closes its stdout,
    // so a parent blocked in `readDataToEndOfFile()` (an UNBOUNDED sync read
    // that no semaphore could interrupt) gets EOF and returns.

    /// Arms a one-shot watchdog that terminates+kills `task` after
    /// `subprocessTimeout`, and returns the lock the caller's
    /// `terminationHandler` uses to cancel the kill on normal exit.
    ///
    /// The `Bool` state is the single-shot flag: whichever of {normal exit,
    /// watchdog} flips it from `false` to `true` first wins, and the loser is a
    /// no-op. `terminationHandler` must set it to `true` (under the lock) before
    /// the watchdog fires to cancel the kill; the watchdog only kills if it was
    /// still `false`. The flag is read/written exclusively under the unfair
    /// lock, so there is no race between the two callbacks.
    private static func armWatchdog(_ task: Process) -> OSAllocatedUnfairLock<Bool> {
        // false = not-yet-handled; the first writer to flip it to true wins.
        let handled = OSAllocatedUnfairLock<Bool>(initialState: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + ReaderConstants.subprocessTimeout) {
            let shouldKill = handled.withLock { state -> Bool in
                if state { return false }   // already exited normally — stand down
                state = true
                return true
            }
            guard shouldKill else { return }
            task.terminate()                // SIGTERM first
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)   // closes child stdout → unblocks read
            }
            Task { await DCLogger.shared.log("[SUBPROC] watchdog killed a subprocess after \(ReaderConstants.subprocessTimeout)s timeout") }
        }
        return handled
    }

    @discardableResult
    private static func shellFull(_ executablePath: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        // Arm the watchdog BEFORE the blocking wait. terminationHandler claims
        // the single-shot flag on normal exit, cancelling the kill.
        let handled = armWatchdog(task)
        task.terminationHandler = { _ in handled.withLock { $0 = true } }
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Runs a full-path executable and returns its stdout as a String, or nil on failure.
    private static func shellOutputFull(_ executablePath: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        // Arm the watchdog BEFORE the blocking read. A child that writes more
        // than the pipe buffer (~64 KB — e.g. `lsar -j` on a many-page archive,
        // or `tar -tf` on a large CBT) blocks on write() until the buffer is
        // read; reading first (rather than waiting first) avoids that deadlock.
        // readDataToEndOfFile is an unbounded sync read — if the child wedges,
        // only the watchdog's SIGKILL (which closes the child's stdout) can
        // unblock it. terminationHandler cancels the kill on normal exit.
        let handled = armWatchdog(task)
        task.terminationHandler = { _ in handled.withLock { $0 = true } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
