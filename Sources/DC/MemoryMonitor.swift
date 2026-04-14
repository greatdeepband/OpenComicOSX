import Foundation
import AppKit
import Darwin.Mach

// MARK: - MemoryMonitor

/// Polls process memory usage and thumbnail-cache stats at a configurable interval.
///
/// Stats are:
///   - Published to the UI via @Published properties (for the debug overlay).
///   - Written to DCLogger (/tmp/dc_debug.log) so they can be tailed remotely.
///
/// Usage:
///   MemoryMonitor.shared.start(library: libraryViewModel)
///   MemoryMonitor.shared.stop()
@MainActor
final class MemoryMonitor: ObservableObject {

    static let shared = MemoryMonitor()

    // MARK: - Published stats (drive the UI overlay)

    /// Resident memory in bytes as reported by mach task_info.
    @Published var residentBytes: UInt64 = 0
    /// Number of NSImage objects currently held in the thumbnail NSCache.
    @Published var cacheCount: Int = 0
    /// Number of thumbnail files on disk in the cache directory.
    @Published var diskCount: Int = 0
    /// Formatted resident memory string, e.g. "142.3 MB".
    @Published var residentFormatted: String = "—"
    /// Timestamp of the last sample.
    @Published var lastSampleTime: Date = Date()

    // MARK: - Private state

    private var timer: Timer?
    private weak var library: LibraryViewModel?

    private init() {}

    var memoryStatus: String {
        let mb = Double(residentBytes) / (1024 * 1024)
        if mb < 50 {
            return "Clean"
        } else if mb < 200 {
            return "Moderate"
        } else if mb < 500 {
            return "High"
        } else {
            return "Critical"
        }
    }

    var memoryPressure: String {
        let mb = Double(residentBytes) / (1024 * 1024)
        if mb < 100 {
            return "nominal"
        } else if mb < 400 {
            return "elevated"
        } else if mb < 700 {
            return "warning"
        } else {
            return "critical"
        }
    }

    // MARK: - Control

    func start(library: LibraryViewModel, interval: TimeInterval = 5) {
        self.library = library
        Task { await sample() }  // immediate first sample
        print("Memory status: \(memoryStatus)")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sample() }
        }
        Task { await DCLogger.shared.log("MEMORY_MONITOR started (interval=\(Int(interval))s)") }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Task { await DCLogger.shared.log("MEMORY_MONITOR stopped") }
    }

    deinit {
        timer?.invalidate()
        Task { await DCLogger.shared.log("MEMORY_MONITOR stopped") }
    }

    // MARK: - Sampling

    private func sample() async {
        let resident = currentResidentBytes()
        let count    = library?.thumbnailCacheCount ?? 0
        let disk     = diskThumbnailCount()

        residentBytes     = resident
        cacheCount        = count
        diskCount         = disk
        residentFormatted = Self.formatBytes(resident)
        lastSampleTime    = Date()

        let ts = Self.timestamp()
        await DCLogger.shared.log(
            "MEM [\(ts)]  resident=\(residentFormatted)  cache=\(count) imgs  disk=\(disk) files"
        )
    }

    // MARK: - mach task_info resident memory

    private func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: - Disk thumbnail count

    private func diskThumbnailCount() -> Int {
        let dir = LibraryViewModel.thumbnailCacheDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".jpg") }.count
    }

    // MARK: - Formatting helpers

    static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
