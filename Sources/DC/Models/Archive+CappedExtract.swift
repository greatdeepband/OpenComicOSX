import Foundation
import ZIPFoundation

// MARK: - Capped-extract helper

extension Archive {
    /// Thrown when a single entry's decompressed bytes exceed the caller-supplied
    /// cap. Distinct from all I/O errors so callers can handle it separately.
    enum CappedExtractError: Error { case entryTooLarge }

    /// Extracts `entry` into `Data`, throwing `CappedExtractError.entryTooLarge`
    /// if the decompressed stream exceeds `cap` bytes before the extract finishes.
    ///
    /// This is the **single source of truth** for the streaming decompression-bomb
    /// guard used on the production CBZ decode paths:
    ///
    ///   - `MetalPageManager.decodeArchiveEntry` (full-res page decode)
    ///   - `MetalPageManager.extractEntry`       (thumbnail decode)
    ///   - `ComicLoader.validateCBZ`             (symlink-body extraction)
    ///   - `PageSource.decode()` `.zipData` branch (incremental decode — uses the
    ///     cap but accumulates into CGImageSource; handled inline, cap supplied
    ///     by caller)
    ///
    /// A lying central directory that declares a tiny `uncompressedSize` for a
    /// massive entry is only observable during streaming extraction. This cap
    /// ensures such an entry cannot inflate without bound into RAM.
    ///
    /// - Parameters:
    ///   - entry:     The `Entry` to extract.
    ///   - cap:       Maximum allowed decompressed bytes (use
    ///                `ReaderConstants.maxUncompressedBytes`).
    ///   - skipCRC32: Passed through to `Archive.extract`; set `true` when the
    ///                CRC is irrelevant (e.g. reading a symlink target string).
    /// - Returns: The fully decompressed entry contents.
    /// - Throws: `CappedExtractError.entryTooLarge` if the stream exceeds `cap`;
    ///           any `ZIPFoundation` I/O error on extraction failure.
    func extractEntryData(_ entry: Entry, cap: Int64, skipCRC32: Bool = false) throws -> Data {
        var data = Data()
        var total: Int64 = 0
        _ = try self.extract(entry, skipCRC32: skipCRC32) { chunk in
            total += Int64(chunk.count)
            guard total <= cap else { throw CappedExtractError.entryTooLarge }
            data.append(chunk)
        }
        return data
    }
}
