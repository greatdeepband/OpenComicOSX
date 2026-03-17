import SwiftUI

@main
struct DCApp: App {
    @StateObject private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Comic…") {
                    library.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
