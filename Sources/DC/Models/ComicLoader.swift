import Foundation
import AppKit
import PDFKit
import ZIPFoundation

/// Loads a comic from disk into a `Comic` model.
/// Pages are NOT decoded into memory at load time — only file URLs / PDF page refs are stored.
/// Decoding happens lazily via `PageSource.decode()` when the reader needs a specific page.
enum ComicLoader {

    enum LoadError: LocalizedError {
        case unsupportedFormat(String)
        case noImagesFound
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext): return "Unsupported format: \(ext)"
            case .noImagesFound: return "No images found in the archive."
            case .extractionFailed(let msg): return "Extraction failed: \(msg)"
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

    static func load(url: URL) throws -> Comic {
        guard let format = ComicFormat.from(url: url) else {
            throw LoadError.unsupportedFormat(url.pathExtension)
        }
        switch format {
        case .cbz:
            return try loadCBZ(url: url)
        case .pdf:
            return try loadPDF(url: url)
        case .cbr, .cb7:
            return try loadWithUnar(url: url)
        case .cbt:
            return try loadTAR(url: url)
        case .epub:
            throw LoadError.unsupportedFormat("epub (coming soon)")
        }
    }

    // MARK: - Cover-only fast load (for thumbnails)

    static func loadCover(url: URL) -> NSImage? {
        guard let format = ComicFormat.from(url: url) else { return nil }
        switch format {
        case .cbz:  return loadCoverCBZ(url: url)
        case .pdf:  return loadCoverPDF(url: url)
        case .cbr, .cb7: return loadCoverWithUnar(url: url)
        case .cbt:  return loadCoverTAR(url: url)
        case .epub: return nil
        }
    }

    /// Fast path for bulk thumbnail generation: returns a CGImage already scaled
    /// to the 200×280 thumbnail canvas, skipping the NSImage wrapper entirely.
    /// This avoids the redundant scaledCGImage() pass in saveThumbnailAndCache.
    static func loadCoverCGImage(url: URL) -> CGImage? {
        guard let format = ComicFormat.from(url: url) else { return nil }
        let maxPixels = 560  // 280pt × 2 Retina
        let w = 400, h = 560 // 200pt × 2 Retina

        // Get the raw thumbnail CGImage from the appropriate loader.
        let rawCG: CGImage?
        switch format {
        case .cbz:
            rawCG = loadCoverCGImageCBZ(url: url, maxPixels: maxPixels)
        case .pdf:
            rawCG = loadCoverPDF(url: url).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        case .cbr, .cb7:
            rawCG = loadCoverWithUnar(url: url).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        case .cbt:
            rawCG = loadCoverTAR(url: url).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        case .epub:
            return nil
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
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        let entries = archive
            .filter { $0.type == .file
                && imageExtensions.contains(($0.path as NSString).pathExtension.lowercased())
                && !$0.path.contains("__MACOSX") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard let firstEntry = entries.first else { return nil }

        let imageSource = CGImageSourceCreateIncremental(nil)
        var accumulated = Data()
        do {
            try archive.extract(firstEntry) { chunk in
                accumulated.append(chunk)
                CGImageSourceUpdateData(imageSource, accumulated as CFData, false)
            }
            CGImageSourceUpdateData(imageSource, accumulated as CFData, true)
        } catch { return nil }

        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, opts as CFDictionary)
    }

    private static func loadCoverCBZ(url: URL) -> NSImage? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }

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

        // Stream the entry bytes directly into an incremental CGImageSource.
        // The consumer closure is called in chunks (~64 KB each), so we never
        // hold the full decompressed image in RAM as a single Data allocation.
        let imageSource = CGImageSourceCreateIncremental(nil)
        var lastData = Data()
        var success = false

        do {
            try archive.extract(firstEntry) { chunk in
                lastData.append(chunk)
                // Feed each chunk to the incremental decoder.
                CGImageSourceUpdateData(imageSource, lastData as CFData, false)
            }
            // Signal end-of-data so the decoder can finalise.
            CGImageSourceUpdateData(imageSource, lastData as CFData, true)
            success = true
        } catch {
            print("CBZ stream extract failed for \(url.lastPathComponent): \(error)")
        }

        guard success else { return nil }

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

    private static func loadCoverPDF(url: URL) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 1.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
        }
        image.unlockFocus()
        return image
    }

    private static func loadCoverTAR(url: URL) -> NSImage? {
        // List entries with tar -tf, find the first image, extract only that file.
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        guard let listing = shellOutput("tar", args: ["-tf", url.path]) else { return nil }
        let firstImage = listing
            .components(separatedBy: "\n")
            .filter { line in
                let ext = (line as NSString).pathExtension.lowercased()
                return imageExtensions.contains(ext) && !line.contains("__MACOSX")
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
        guard let entryPath = firstImage else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Extract only the single cover entry.
        let result = shell("tar", args: ["-xf", url.path, "-C", tmpDir.path, entryPath])
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
        // CBZ: read the ZIP central directory only — no extraction to disk.
        // ZIPFoundation gives us entry paths; pages are decoded on-demand via
        // Archive streaming when the reader requests each page.
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw LoadError.extractionFailed("Could not open ZIP archive.")
        }
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
            ComicPage(id: idx, source: .zip(url, entry.path))
        }
        return Comic(url: url, format: .cbz, pages: pages)
    }

    // MARK: - PDF

    private static func loadPDF(url: URL) throws -> Comic {
        guard let doc = PDFDocument(url: url) else {
            throw LoadError.extractionFailed("Could not open PDF.")
        }
        var pages: [ComicPage] = []
        for i in 0..<doc.pageCount {
            pages.append(ComicPage(id: i, source: .pdf(doc, i)))
        }
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        return Comic(url: url, format: .pdf, pages: pages)
    }

    // MARK: - TAR (CBT)

    private static func loadTAR(url: URL) throws -> Comic {
        let cacheDir = persistentPageCacheDir(for: url)

        if !isCacheStale(cacheDir: cacheDir, sourceURL: url) {
            let pages = try pagesFromDirectory(cacheDir)
            if !pages.isEmpty { return Comic(url: url, format: .cbt, pages: pages) }
        }

        try? FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let result = shell("tar", args: ["-xf", url.path, "-C", cacheDir.path])
        guard result == 0 else { throw LoadError.extractionFailed("tar exited \(result)") }

        let pages = try pagesFromDirectory(cacheDir)
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
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

        try? FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let result = shellFull(unarPath, args: ["-o", cacheDir.path, "-force-overwrite", url.path])
        guard result == 0 else {
            throw LoadError.extractionFailed(
                "unar failed (exit \(result)). Make sure unar is installed: brew install unar"
            )
        }

        let pages = try pagesFromDirectory(cacheDir)
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
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
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheManifest.self, from: data)
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
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(for: cacheDir))
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
        case .pdf, .epub: return nil
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
        guard let listing = shellOutput("tar", args: ["-tf", url.path]) else { return nil }
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

    @discardableResult
    private static func shell(_ command: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [command] + args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    @discardableResult
    private static func shellFull(_ executablePath: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Runs a command and returns its stdout as a String, or nil on failure.
    private static func shellOutput(_ command: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [command] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Runs a full-path executable and returns its stdout as a String, or nil on failure.
    private static func shellOutputFull(_ executablePath: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
