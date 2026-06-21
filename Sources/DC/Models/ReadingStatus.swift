import Foundation

enum ReadingStatus: Equatable {
    case unread
    case inProgress(Double)
    case finished
}

enum ManualStatus: String {
    case unread
    case finished
}

/// Manual override wins; else derive from reading position (0.98 = finished).
func effectiveStatus(override: ManualStatus?, page: Int, total: Int) -> ReadingStatus {
    if override == .finished { return .finished }
    if override == .unread { return .unread }
    guard total > 1, page > 0 else { return .unread }
    let f = Double(page) / Double(total - 1)
    return f >= 0.98 ? .finished : .inProgress(f)
}
