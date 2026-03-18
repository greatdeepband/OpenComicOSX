import Foundation
import AppKit
import PDFKit
import ZIPFoundation

/// Loads a comic from disk into a `Comic` model.
/// Supported natively: CBZ (ZIP), PDF.
/// CBR/CB7/CBT require external tools (unrar, 7z, tar) — handled via Process.
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

    static func load(url: URL) throws -> Comic {
        guard let format = ComicFormat.from(url: url) else {
            throw LoadError.unsupportedFormat(url.pathExtension)
        }
        switch format {
        case .cbz:
            return try loadCBZ(url: url)
        case .pdf:
            return try loadPDF(url: url)
        case .cbr:
            return try loadArchive(url: url, tool: "unrar", args: ["e", "-inul", "-y"])
        case .cb7:
            return try loadArchive(url: url, tool: "7z", args: ["e", "-y"])
        case .cbt:
            return try loadTAR(url: url)
        case .epub:
            throw LoadError.unsupportedFormat("epub (coming soon)")
        }
    }

    // MARK: - CBZ (ZIP)

    private static func loadCBZ(url: URL) throws -> Comic {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        try FileManager.default.unzipItem(at: url, to: tmpDir)

        // Load images eagerly (force bitmap data into memory) BEFORE deleting tmp dir.
        let pages = try loadImagesFromDirectory(tmpDir, eager: true)
        try? FileManager.default.removeItem(at: tmpDir)

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
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = NSImage(size: size)
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()
            pages.append(ComicPage(id: i, image: image))
        }
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        return Comic(url: url, format: .pdf, pages: pages)
    }

    // MARK: - TAR (CBT)

    private static func loadTAR(url: URL) throws -> Comic {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let result = shell("tar", args: ["-xf", url.path, "-C", tmpDir.path])
        guard result == 0 else { throw LoadError.extractionFailed("tar exited \(result)") }

        let pages = try loadImagesFromDirectory(tmpDir, eager: true)
        try? FileManager.default.removeItem(at: tmpDir)

        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        return Comic(url: url, format: .cbt, pages: pages)
    }

    // MARK: - Generic archive via external tool (CBR, CB7)

    private static func loadArchive(url: URL, tool: String, args: [String]) throws -> Comic {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Extract flat into tmpDir (no subdirectory nesting from the tool itself)
        let fullArgs = args + [url.path, "-o\(tmpDir.path)"]
        let result = shell(tool, args: fullArgs)
        guard result == 0 else {
            throw LoadError.extractionFailed(
                "\(tool) not found or failed (exit \(result)). " +
                "Install via Homebrew: brew install \(tool == "unrar" ? "unrar" : "sevenzip")"
            )
        }

        let pages = try loadImagesFromDirectory(tmpDir, eager: true)
        try? FileManager.default.removeItem(at: tmpDir)

        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        return Comic(url: url, format: ComicFormat.from(url: url)!, pages: pages)
    }

    // MARK: - Helpers

    /// Recursively finds all image files under `dir`, sorted by relative path,
    /// and loads them into NSImage instances.
    ///
    /// - Parameter eager: When true, forces each image's bitmap data into memory
    ///   immediately so the file can be safely deleted afterwards.
    private static func loadImagesFromDirectory(_ dir: URL, eager: Bool = false) throws -> [ComicPage] {
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "avif"])

        // Use deep enumerator so images inside subdirectories are found.
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var imageFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            // Skip macOS metadata files (e.g. __MACOSX/)
            let components = fileURL.pathComponents
            if components.contains("__MACOSX") { continue }
            imageFiles.append(fileURL)
        }

        // Sort by the path relative to the root dir for natural page order.
        imageFiles.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        return imageFiles.enumerated().compactMap { (idx, fileURL) in
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            if eager {
                // Force decode: draw into a 1×1 context to ensure bitmap data is loaded.
                image.lockFocus()
                image.unlockFocus()
            }
            return ComicPage(id: idx, image: image)
        }
    }

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
}
