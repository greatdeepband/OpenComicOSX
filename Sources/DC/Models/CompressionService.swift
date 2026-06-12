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

    /// Within-file progress for the file currently being compressed. Each
    /// CBZ has 100s of entries; without this the bar stays at 0/1 for the
    /// whole compression of a big single-comic batch. Combined with
    /// filesCompleted/filesTotal in the view layer for a smooth bar.
    @Published var entryCompleted: Int = 0
    @Published var entryTotal: Int = 0

    private var runningTask: Task<Void, Never>? = nil

    /// Returns a `<stem>-original.cbz` URL next to `url` that does not already
    /// exist on disk, so preserving the original never overwrites an existing
    /// file. Tries `<stem>-original.cbz` first, then `-original-2`, `-3`, …
    /// `nonisolated` so it can be unit-tested off the main actor; it touches no
    /// instance state. Note this is best-effort, not atomic against a racing
    /// writer — the compressor's tmp-write + atomic `replaceItemAt` is what
    /// actually protects the source file from a concurrent run.
    nonisolated static func backupURL(for url: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        let first = parent.appendingPathComponent("\(stem)-original.cbz")
        if !FileManager.default.fileExists(atPath: first.path) { return first }
        var n = 2
        while true {
            let candidate = parent.appendingPathComponent("\(stem)-original-\(n).cbz")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

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
                    self?.entryCompleted = 0
                    self?.entryTotal = 0
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
                    // Never overwrite an existing file when preserving the
                    // original. The old code removed any pre-existing
                    // `<name>-original.cbz` first — but on a second compression
                    // of the same comic that file IS the pristine backup from
                    // the first run, so deleting it and copying the (already
                    // compressed) current file over it destroyed the only
                    // full-quality copy. `backupURL(for:)` returns the first
                    // non-colliding name instead, so an existing backup (or an
                    // unrelated user file of that name) is left intact.
                    let target = Self.backupURL(for: url)
                    do {
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
                        convertPNGs: convertPNGs,
                        progress: { [weak self] _, current, total in
                            // Hop to MainActor — compressCBZ's progress
                            // callback fires from the detached Task's thread.
                            Task { @MainActor [weak self] in
                                self?.entryCompleted = current
                                self?.entryTotal = total
                            }
                        }
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
                    summary.errors.append((url, error.localizedDescription))
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
        entryCompleted = 0
        entryTotal = 0
    }
}
