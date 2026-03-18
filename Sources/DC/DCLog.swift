import Foundation

func dcLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/dc_debug.log")
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path) {
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        }
    } else {
        try? data.write(to: url)
    }
}
