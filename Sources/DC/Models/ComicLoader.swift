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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("DC/Pages")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

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

    private static func loadCoverCBZ(url: URL) -> NSImage? {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        guard (try? FileManager.default.unzipItem(at: url, to: tmpDir)) != nil else { return nil }
        return firstImageInDirectory(tmpDir)
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
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let result = shell("tar", args: ["-xf", url.path, "-C", tmpDir.path])
        guard result == 0 else { return nil }
        return firstImageInDirectory(tmpDir)
    }

    private static func loadCoverWithUnar(url: URL) -> NSImage? {
        let unarPaths = ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"]
        let unarPath = unarPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "unar"
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

        guard let first = imageFiles.first, let image = NSImage(contentsOf: first) else { return nil }
        image.lockFocus()
        image.unlockFocus()
        return image
    }

    // MARK: - CBZ (ZIP)

    private static func loadCBZ(url: URL) throws -> Comic {
        let cacheDir = persistentPageCacheDir(for: url)

        // If already extracted, use cached files directly.
        if !isCacheStale(cacheDir: cacheDir, sourceURL: url) {
            let pages = try pagesFromDirectory(cacheDir)
            if !pages.isEmpty {
                return Comic(url: url, format: .cbz, pages: pages)
            }
        }

        // Extract to persistent cache.
        try? FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: url, to: cacheDir)

        let pages = try pagesFromDirectory(cacheDir)
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
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
        return Comic(url: url, format: .cbt, pages: pages)
    }

    // MARK: - CBR / CB7 via unar

    private static func loadWithUnar(url: URL) throws -> Comic {
        let unarPaths = ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"]
        let unarPath = unarPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "unar"

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
        return Comic(url: url, format: ComicFormat.from(url: url)!, pages: pages)
    }

    // MARK: - Persistent cache helpers

    /// Returns the persistent cache directory for a comic's extracted pages.
    static func persistentPageCacheDir(for url: URL) -> URL {
        let hash = abs(url.path.hashValue)
        return pageCacheDir.appendingPathComponent("\(hash)")
    }

    /// Returns true if the cache doesn't exist or the source file is newer than the cache.
    private static func isCacheStale(cacheDir: URL, sourceURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return true }
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let cacheAttrs = try? FileManager.default.attributesOfItem(atPath: cacheDir.path)
        guard let srcMod = attrs?[.modificationDate] as? Date,
              let cacheMod = cacheAttrs?[.modificationDate] as? Date else { return true }
        return srcMod > cacheMod
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
}
