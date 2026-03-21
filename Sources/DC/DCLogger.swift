import Foundation

/// Lightweight debug logger. Writes timestamped lines to /tmp/dc_debug.log.
/// Enable/disable at compile time via the DEBUG_PAGES flag, or flip the runtime switch.
final class DCLogger {
    static let shared = DCLogger()

    /// Set to false to silence all output without recompiling.
    var enabled = true

    private let logURL = URL(fileURLWithPath: "/tmp/dc_debug.log")
    private let queue = DispatchQueue(label: "com.dc.logger", qos: .utility)
    private var handle: FileHandle?

    private init() {
        queue.async { [self] in
            // Truncate log on each launch so it doesn't grow unbounded.
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: logURL)
            raw("=== DC Debug Log started \(Date()) ===")
        }
    }

    func log(_ message: String) {
        guard enabled else { return }
        queue.async { [self] in
            let ts = Self.timestamp()
            raw("[\(ts)] \(message)")
        }
    }

    private func raw(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        handle?.write(data)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
