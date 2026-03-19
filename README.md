# Open Comic

A high-performance, native macOS comic book reader built with SwiftUI and AppKit. Designed for speed, smooth navigation, and handling massive comic libraries with ease.

## Features

- **Format Support:** Native reading of CBZ, CBR, CB7, CBT, and PDF archives.
- **Reading Modes:** Single Page, Double Page, Vertical Scroll, and Vertical Double.
- **Library Management:** Create custom galleries, scan multiple folders, and drag-to-reorder comics.
- **Instant Loading:** Background parallel thumbnail extraction and in-memory caching for zero-lag library scrolling.
- **Smart Persistence:** Remembers your exact reading position (down to the pixel in vertical modes) and preferred reading mode per comic.
- **Magnifier Loupe:** Right-click and hold anywhere on a page to activate a high-quality circular zoom loupe.
- **Native Performance:** Uses AppKit's `NSScrollView` under the hood for pixel-perfect scrolling and memory efficiency, wrapped in modern SwiftUI.

## Architecture Overview

The app is a hybrid SwiftUI/AppKit application. It uses SwiftUI for the main UI structure, library management, and state binding, but drops down to AppKit (`NSScrollView`, `NSImage`, `NSStackView`) for the core reading experience to bypass SwiftUI's lazy rendering limitations and achieve pixel-perfect scroll control.

### Core Components

| Component | Description |
|---|---|
| `DCApp` & `ContentView` | The entry point. Manages the global `LibraryViewModel` and switches between `LibraryView` and `ReaderView`. |
| `LibraryViewModel` | The source of truth for the library. Manages gallery persistence, folder scanning, and the in-memory thumbnail cache. |
| `ReaderViewModel` | Manages the state of the currently open comic, including page navigation, zoom level, and reading mode. |
| `ComicLoader` | Handles the extraction of images from archives. Uses `ZIPFoundation` for CBZ, `PDFDocument` for PDF, and shells out to `unar`/`tar` for CBR/CB7/CBT. |
| `ReadingPositionStore` | Persists reading progress, exact scroll offsets, reading modes, and page counts to `UserDefaults`. |

### Key UI Views

| View | Description |
|---|---|
| `LibraryView` | The main gallery interface. Uses `LazyVGrid` for sections and handles drag-and-drop reordering. |
| `ReaderView` | The reading interface. Switches between different layout modes based on `ReaderViewModel.readingMode`. |
| `VerticalComicScrollView` | A custom `NSViewRepresentable` wrapping `NSScrollView`. Used for vertical reading modes to ensure reliable scroll position restoration and memory-efficient rendering. |
| `ZoomableImageView` | Used for Single and Double page modes. Handles pinch-to-zoom and panning. |
| `MagnifierView` | The SwiftUI overlay that renders the right-click loupe. |

## Development Guide

### Prerequisites

- macOS 14.0+
- Xcode 15+ (or Swift 5.10+ toolchain)
- `unar` (required for CBR/CB7 support): `brew install unar`

### Building the App

The project uses Swift Package Manager for dependencies but is built as a standard macOS `.app` bundle using a custom shell script.

To build the release app bundle:

```bash
cd /path/to/OpenComic
bash scripts/make_app.sh
```

This script will:
1. Compile the binary using `xcodebuild`.
2. Assemble the `.app` bundle structure in `build/Open Comic.app`.
3. Copy the `Info.plist`, app icon (`DC.icns`), and any required framework bundles.
4. Ad-hoc sign the application.

### Working with AI Agents

This project has been heavily developed in collaboration with AI agents. When working on this codebase alongside an AI, keep the following context in mind:

1. **AppKit vs SwiftUI:** The reader view intentionally uses AppKit (`NSScrollView`) for vertical modes because SwiftUI's `ScrollView` + `LazyVStack` cannot reliably restore scroll positions to off-screen elements. Do not attempt to "modernize" `VerticalComicScrollView` back to pure SwiftUI without understanding this limitation.
2. **Memory Management:** `NSImage` caches decoded bitmap data aggressively. The thumbnail cache in `LibraryViewModel` specifically stores scaled-down JPEGs, not the original full-resolution images, to prevent massive memory leaks.
3. **Coordinate Systems:** `VerticalComicScrollView` uses a custom `FlippedStackView` to force a top-left origin (matching SwiftUI/UIKit), but `NSImage.draw(in:)` still assumes a bottom-left origin. `ComicPageView` handles the necessary context flipping.
4. **State Lifecycle:** `LibraryView` is conditionally rendered via an `if/else` in `ContentView`. This means `@State` variables in `LibraryView` are destroyed and recreated every time the reader is opened/closed. Persistent session state (like collapsed galleries) must live in `LibraryViewModel`.

## Dependencies

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) - For native, fast CBZ extraction without shelling out to command-line tools.
