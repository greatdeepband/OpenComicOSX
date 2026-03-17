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
            return try loadArchive(url: url, tool: "unrar", args: ["p", "-inul"])
        case .cb7:
            return try loadArchive(url: url, tool: "7z", args: ["e", "-so"])
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
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.unzipItem(at: url, to: tmpDir)
        let pages = try loadImagesFromDirectory(tmpDir)
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
            let scale: CGFloat = 2.0  // render at 2x for sharpness
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
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = shell("tar", args: ["-xf", url.path, "-C", tmpDir.path])
        guard result == 0 else { throw LoadError.extractionFailed("tar exited \(result)") }
        let pages = try loadImagesFromDirectory(tmpDir)
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        return Comic(url: url, format: .cbt, pages: pages)
    }

    // MARK: - Generic archive via external tool (CBR, CB7)

    private static func loadArchive(url: URL, tool: String, args: [String]) throws -> Comic {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fullArgs = args + [url.path, tmpDir.path]
        let result = shell(tool, args: fullArgs)
        guard result == 0 else {
            throw LoadError.extractionFailed("\(tool) not found or failed (exit \(result)). Install via Homebrew: brew install \(tool == "unrar" ? "unrar" : "sevenzip")")
        }
        let pages = try loadImagesFromDirectory(tmpDir)
        guard !pages.isEmpty else { throw LoadError.noImagesFound }
        return Comic(url: url, format: ComicFormat.from(url: url)!, pages: pages)
    }

    // MARK: - Helpers

    /// Reads all image files from a directory, sorted by filename.
    private static func loadImagesFromDirectory(_ dir: URL) throws -> [ComicPage] {
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"])
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let imageFiles = files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return imageFiles.enumerated().compactMap { (idx, fileURL) in
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
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
