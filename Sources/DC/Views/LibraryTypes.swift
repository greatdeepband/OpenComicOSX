import Foundation

// MARK: - LibrarySection

/// The active selection in the library sidebar. Drives the detail pane.
enum LibrarySection: Hashable, Codable {
    case home
    case favorites
    case recents
    case allComics
    case gallery(UUID)

    var storageKey: String {
        switch self {
        case .home:         return "home"
        case .favorites:    return "favorites"
        case .recents:      return "recents"
        case .allComics:    return "allComics"
        case .gallery(let id): return "gallery.\(id.uuidString)"
        }
    }
}

// MARK: - CardSize

enum CardSize: String, CaseIterable, Codable {
    case small, medium, large, extraLarge

    /// Adaptive minimum for LazyVGrid's GridItem.
    var minimum: CGFloat {
        switch self {
        case .small:      return 140
        case .medium:     return 180
        case .large:      return 240
        case .extraLarge: return 320
        }
    }

    var maximum: CGFloat { minimum * 1.25 }

    var titleFontSize: CGFloat {
        switch self {
        case .small:      return 11
        case .medium:     return 13
        case .large:      return 14
        case .extraLarge: return 16
        }
    }
}

// MARK: - SortOrder

enum LibrarySortOrder: String, CaseIterable, Codable {
    case manual               // user drag order (galleries only)
    case recentlyAdded        // file mtime
    case recentlyRead         // from recents list
    case alphabetical         // title A–Z
    case progress             // reading progress ascending (unread first)
    case format               // by extension

    var label: String {
        switch self {
        case .manual:         return "Custom Order"
        case .recentlyAdded:  return "Recently Added"
        case .recentlyRead:   return "Recently Read"
        case .alphabetical:   return "A–Z"
        case .progress:       return "Progress"
        case .format:         return "Format"
        }
    }
}
