import Foundation

/// Lightweight debug logger. Writes timestamped lines to a per-user app
/// Caches directory (e.g. ~/Library/Caches/<bundle-id>/dc_debug.log).
///
/// Default behaviour:
///   • DEBUG builds — enabled. Log captures everything for live debugging.
///   • Release builds — disabled. Release users don't write dc_debug.log
///     by default. Flip `DCLogger.shared.enabled = true` at runtime (e.g.
///     when guiding a user through reproducing a bug report) to capture.
///
/// `enabled` is a runtime switch so a release build can still be coaxed into
/// logging without rebuilding — useful for bug-report triage.
actor DCLogger {
    static let shared = DCLogger()

    /// Set to true to capture, false to silence. Default differs per
    /// build configuration (see type doc).
    #if DEBUG
    var enabled = true
    #else
    var enabled = false
    #endif

    /// Resolved lazily; `nil` means the directory could not be created —
    /// in that case all writes are silently skipped.
    private let logURL: URL? = {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "open-comic"
        let dir = caches.appendingPathComponent(bundleID, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("dc_debug.log")
    }()
    private var handle: FileHandle?
    private var isTruncated = false

    private init() {}

    /// Lazy-opens the file handle on first write, so DCLogger works without an explicit start call.
    /// Returns without creating a handle if the log directory is unavailable.
    private func ensureHandle() {
        guard handle == nil, let logURL else { return }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
    }

    /// Truncates the log file so it doesn't grow unbounded across runs.
    /// Safe to call multiple times — only truncates once.
    func truncate() async {
        guard !isTruncated else { return }
        isTruncated = true
        ensureHandle()
        raw("=== DC Debug Log started \(Date()) ===")
    }

    func log(_ message: String) async {
        guard enabled else { return }
        // Truncate on very first write so a fresh app run starts a new log.
        if !isTruncated {
            isTruncated = true
            ensureHandle()
            // Write header immediately.
            let header = "=== DC Debug Log started \(Date()) ===\n"
            let data = header.data(using: .utf8) ?? Data()
            try? handle?.write(contentsOf: data)
        }
        let ts = Self.timestamp()
        raw("[\(ts)] \(message)")
    }

    private func raw(_ line: String) {
        guard logURL != nil else { return } // no usable log dir — skip silently
        ensureHandle()
        let data = (line + "\n").data(using: .utf8) ?? Data()
        do {
            try handle?.write(contentsOf: data)
        } catch {
            // Write failure — log to console rather than crashing.
            print("DCLogger: write failed: \(error)")
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
