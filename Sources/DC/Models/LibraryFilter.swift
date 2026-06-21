import Foundation

func matchesQuery(filename: String, query: String) -> Bool {
    let q = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
    guard !q.isEmpty else { return true }
    let name = filename.lowercased()
    return q.allSatisfy { name.contains($0) }
}

// MARK: - Filter Model

enum StatusFilter: String, Codable, CaseIterable { case all, unread, inProgress, finished }

struct LibraryFilter: Codable, Equatable {
    var status: StatusFilter = .all
    var favoritedOnly: Bool = false
    var formats: Set<String> = []      // empty = all formats
    var isActive: Bool { status != .all || favoritedOnly || !formats.isEmpty }
}

/// Pure predicate: does a comic pass the active filter? `format` is the lowercased extension.
func comicMatchesFilter(status: ReadingStatus, isFavorited: Bool, format: String, filter: LibraryFilter) -> Bool {
    // status
    switch filter.status {
    case .all: break
    case .unread:     if case .unread = status {} else { return false }
    case .inProgress: if case .inProgress = status {} else { return false }
    case .finished:   if case .finished = status {} else { return false }
    }
    // favorited
    if filter.favoritedOnly && !isFavorited { return false }
    // format (empty set = all)
    if !filter.formats.isEmpty && !filter.formats.contains(format.lowercased()) { return false }
    return true
}
