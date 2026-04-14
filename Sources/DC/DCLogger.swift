import Foundation

/// Lightweight debug logger. Writes timestamped lines to /tmp/dc_debug.log.
/// Enable/disable at compile time via the DEBUG_PAGES flag, or flip the runtime switch.
actor DCLogger {
    static let shared = DCLogger()

    /// Set to false to silence all output without recompiling.
    var enabled = true

    private let logURL = URL(fileURLWithPath: "/tmp/dc_debug.log")
    private var handle: FileHandle?
    private var isTruncated = false

    private init() {}

    /// Truncates the log file so it doesn't grow unbounded across runs.
    /// Safe to call multiple times — only truncates once.
    func truncate() async {
        guard !isTruncated else { return }
        isTruncated = true
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
        await raw("=== DC Debug Log started \(Date()) ===")
    }

    func log(_ message: String) async {
        guard enabled else { return }
        let ts = Self.timestamp()
        await raw("[\(ts)] \(message)")
    }

    private func raw(_ line: String) {
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
