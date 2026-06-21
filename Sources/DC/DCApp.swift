import SwiftUI
import AppKit

// MARK: - View menu commands (Reading Mode / Direction via .focusedSceneValue bridge)

struct ReaderViewCommands: Commands {
    @FocusedValue(\.readerVM) private var readerVM: ReaderViewModel?

    var body: some Commands {
        CommandMenu("View") {
            Section("Reading Mode") {
                ForEach(ReadingMode.allCases, id: \.self) { mode in
                    Button {
                        readerVM?.readingMode = mode
                        readerVM?.saveMode()
                    } label: {
                        HStack {
                            Text(mode.menuTitle)
                            if readerVM?.readingMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .keyboardShortcut(mode.menuKeyEquivalent, modifiers: .command)
                    .disabled(readerVM == nil)
                }
            }
            Divider()
            Section("Reading Direction") {
                Button {
                    readerVM?.toggleReadingDirection()
                } label: {
                    Text(readerVM?.isRTL == true ? "Switch to Left-to-Right" : "Switch to Right-to-Left")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(readerVM == nil)
            }
        }
    }
}

private extension ReadingMode {
    var menuTitle: String {
        switch self {
        case .singlePage:     return "Single Page"
        case .doublePage:     return "Double Page"
        case .verticalScroll: return "Vertical Scroll"
        case .verticalDouble: return "Vertical Double"
        }
    }

    var menuKeyEquivalent: KeyEquivalent {
        switch self {
        case .singlePage:     return "1"
        case .doublePage:     return "2"
        case .verticalScroll: return "3"
        case .verticalDouble: return "4"
        }
    }
}

// MARK: - App Delegate (required for Finder "Open With" / double-click file opens)
// `onOpenURL` alone does NOT receive Finder-initiated opens; only the delegate
// method `application(_:open:)` does. The static buffer holds URLs that arrive
// before the SwiftUI scene has wired its handler (cold-launch race).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingURLs: [URL] = []
    static var onOpen: ((URL) -> Void)? {
        didSet { if onOpen != nil { let q = pendingURLs; pendingURLs = []; q.forEach { onOpen?($0) } } }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { if let h = AppDelegate.onOpen { h(url) } else { AppDelegate.pendingURLs.append(url) } }
    }
}

@main
struct DCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library: LibraryViewModel   // was: = LibraryViewModel()

    // Migration MUST run before LibraryViewModel() is constructed: its init()
    // reads recentComics/galleries/favorites/thumbnailScheme_fnv1a_v1 from
    // UserDefaults.standard immediately, and writes thumbnailScheme_fnv1a_v1
    // if absent (triggering a full thumbnail wipe). Running the migration here
    // guarantees the new-domain prefs are populated before any of those reads.
    init() {
        OpncomicDefaultsMigration.runIfNeeded()
        _library = StateObject(wrappedValue: LibraryViewModel())
    }

    var body: some Scene {
        WindowGroup("Open Comic") {
            ContentView()
                .environmentObject(library)
                // Wire delegate buffer flush: cold-launch Finder opens land in
                // AppDelegate.pendingURLs before this runs; assigning onOpen
                // drains the queue immediately.
                .task { AppDelegate.onOpen = { url in Task { await library.load(url: url) } } }
                // URL-scheme opens (e.g. opencomic://…) — does NOT fire for
                // Finder double-click / "Open With"; the delegate handles those.
                .onOpenURL { url in Task { await library.load(url: url) } }
        }
        // Default `.windowStyle(.titleBar)` (no override). On macOS 26 the
        // `.hiddenTitleBar` style hides the traffic-light buttons until the
        // user hovers, which we don't want — we keep them visible by leaving
        // the title bar in place and using `FullSizeTitleBarConfigurator`
        // to make it transparent and stretch the content underneath.
        .commands {
            ReaderViewCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open Comic…") {
                    library.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Compress All Comics…") {
                    library.requestCompressAll()
                }
                .disabled(library.allComicURLs.isEmpty)
                Divider()
                Button("Clear Image Caches…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear Image Caches?"
                    alert.informativeText = "Removes extracted pages and thumbnails. Your reading progress is kept."
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .warning
                    if alert.runModal() == .alertFirstButtonReturn {
                        library.clearImageCaches()
                    }
                }
                Button("Reset Reading Progress…") {
                    let alert = NSAlert()
                    alert.messageText = "Reset Reading Progress?"
                    alert.informativeText = "Removes reading positions, page counts, and recents. Cached images are kept."
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .warning
                    if alert.runModal() == .alertFirstButtonReturn {
                        library.resetReadingProgress()
                    }
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Open Comic") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Open Comic",
                        .credits: NSAttributedString(
                            string: "Bundles ZIPFoundation (MIT) and The Unarchiver / unar, lsar (LGPL-2.1).",
                            attributes: [.font: NSFont.systemFont(ofSize: 11)])
                    ])
                }
            }
            CommandGroup(after: .help) {   // 'after:' keeps the system Help Search field
                Button("Open Comic Help") {
                    if let url = URL(string: "https://github.com/greatdeepband/OpenComicOSX#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
