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

        // Per-entry-type aggregation across the batch, summed from each
        // CBZCompressionResult. Tells the user WHY compression was
        // marginal — e.g. "of your 200 MB, 5 MB was JPEGs (rewritten)
        // and 195 MB was PNGs (passed through unchanged)".
        var totalJpegsSeen: Int = 0
        var totalJpegsRewritten: Int = 0
        var totalJpegsSkipped: Int = 0      // sum of bitonal + threshold + failed
        var totalPngsPassed: Int = 0
        var totalPngsConverted: Int = 0
        var totalOthersPassed: Int = 0

        static func == (l: BatchSummary, r: BatchSummary) -> Bool {
            l.attempted == r.attempted
                && l.succeeded == r.succeeded
                && l.skippedNonCBZ == r.skippedNonCBZ
                && l.failed == r.failed
                && l.totalInputBytes == r.totalInputBytes
                && l.totalOutputBytes == r.totalOutputBytes
                && l.errors.count == r.errors.count
                && l.totalJpegsSeen == r.totalJpegsSeen
                && l.totalJpegsRewritten == r.totalJpegsRewritten
                && l.totalJpegsSkipped == r.totalJpegsSkipped
                && l.totalPngsPassed == r.totalPngsPassed
                && l.totalPngsConverted == r.totalPngsConverted
                && l.totalOthersPassed == r.totalOthersPassed
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
        convertPNGs: Bool = false,
        onFileCompleted: ((URL) -> Void)? = nil
    ) {
        guard case .idle = state else { return }
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
                        skipThreshold: ReaderConstants.cbzCompressionSkipThreshold,
                        convertPNGs: convertPNGs
                    )
                    summary.succeeded += 1
                    summary.totalInputBytes += result.inputBytes
                    summary.totalOutputBytes += result.outputBytes
                    summary.totalJpegsSeen += result.jpegsSeen
                    summary.totalJpegsRewritten += result.jpegsRewritten
                    summary.totalJpegsSkipped += result.jpegsSkippedBitonal
                        + result.jpegsSkippedThreshold
                        + result.jpegsFailed
                    summary.totalPngsPassed += result.pngsPassed
                    summary.totalPngsConverted += result.pngsConverted
                    summary.totalOthersPassed += result.othersPassed
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
