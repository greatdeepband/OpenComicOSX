import SwiftUI

@main
struct DCApp: App {
    @StateObject private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup("Open Comic") {
            ContentView()
                .environmentObject(library)
        }
        // Hide the standard title bar so the reader's custom strip can
        // integrate with the traffic-light region — one continuous chrome row
        // instead of a stacked title bar + toolbar.
        .windowStyle(.hiddenTitleBar)
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
