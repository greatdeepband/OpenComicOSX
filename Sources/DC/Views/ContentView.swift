import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: LibraryViewModel

    var body: some View {
        Group {
            if let comic = library.openComic {
                ReaderView(comic: comic)
            } else {
                LibraryView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
