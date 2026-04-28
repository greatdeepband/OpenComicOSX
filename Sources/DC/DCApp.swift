import SwiftUI

@main
struct DCApp: App {
    @StateObject private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup("Open Comic") {
            ContentView()
                .environmentObject(library)
        }
        // Default `.windowStyle(.titleBar)` (no override). On macOS 26 the
        // `.hiddenTitleBar` style hides the traffic-light buttons until the
        // user hovers, which we don't want — we keep them visible by leaving
        // the title bar in place and using `FullSizeTitleBarConfigurator`
        // to make it transparent and stretch the content underneath.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Comic…") {
                    library.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Clear All Cache…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear All Cache?"
                    alert.informativeText = "This will delete all extracted page caches, thumbnails, and reading positions. Galleries and favorites are kept. Thumbnails will regenerate automatically."
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .warning
                    if alert.runModal() == .alertFirstButtonReturn {
                        library.clearAllCache()
                    }
                }
            }
        }
    }
}
