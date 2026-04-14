# DC — Agent Instructions

DC is a native macOS comic reader built with Swift 5.10+ and Swift Package Manager.

## Project Layout

```
Sources/DC/
  DCApp.swift          — @main entry point
  DCLogger.swift        — lightweight timestamped logger (/tmp/dc_debug.log)
  MemoryMonitor.swift   — @MainActor memory/caching telemetry
  Models/
    Comic.swift         — comic metadata (title, page count, URL)
    ComicLoader.swift   — ZIPFoundation-based .cbz loading
    ReadingPosition.swift
  Utilities/
  ViewModels/
    LibraryViewModel.swift  — gallery/comic library state, @Published, thumbnail NSCache
    ReaderViewModel.swift   — reading session state, current page, zoom
  Views/
    ContentView.swift           — root SwiftUI view
    LibraryView.swift           — gallery grid (NSCollectionView-like via LazyVGrid)
    ReaderView.swift            — single-page reader (NSImageView-based)
    VerticalComicScrollView.swift — vertical scroll mode
    ZoomableImageView.swift      — pinch/zoom NSImageView wrapper
    MagnifierView.swift
```

**Package manager:** SPM only (no CocoaPods, no Carthage)
**Dependency:** [ZIPFoundation](https://github.com/weichsel/ZIPFoundation.git) — handles .cbz extraction
**Platform:** macOS 14.0+
**Architecture:** AppKit + SwiftUI hybrid — AppKit for image views (performance), SwiftUI for UI chrome

## Memory Philosophy

DC must stay under 200 MB RSS in typical use. Every feature must be weighed against its memory cost:
- NSImage cache hard-capped via `NSCache.countLimit`
- Disk thumbnail cache pruned aggressively (see `LibraryViewModel.thumbnailCacheDir`)
- `MemoryMonitor` polls every 5s and logs to `/tmp/dc_debug.log`
- `@Published` properties drive a debug overlay — avoid strong retain cycles
- Background work dispatched to `DispatchQueue` with `.utility` QoS

## Threading Conventions

- `@MainActor` on all `ObservableObject` view models — SwiftUI bindings are main-thread-only
- `DCLogger` uses a dedicated `DispatchQueue` (label: `"com.dc.logger"`) for async writes
- Image decompression on background queue, cached result back to main thread
- `MemoryMonitor` samples on a `Timer` scheduled from the main actor

## Error Handling

- Result type on loaders (`Result<[NSImage], Error>`)
- Logs errors via `DCLogger.shared.log("ERROR: \(err)")` — never silently swallow
- No user-facing alerts for recoverable errors (missing thumbnail = placeholder)

## Code Style

- All public members documented with `///` doc comments
- `// MARK: -` section headers in every file
- `self` used explicitly in initializers and mutating contexts only
- CapitalCase for types/protocols, camelCase for functions/variables

## Build & Run

```bash
swift build      # compile only
swift run        # build and execute
swift test       # if/when tests exist
```

The `swift build` command must succeed before any change is committed.

## Working Directory

All opencode sessions run from the project root (`/Volumes/Media/__Manus copy/DC`), which contains `Package.swift`.
