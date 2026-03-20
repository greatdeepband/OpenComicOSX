import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: LibraryViewModel

    var body: some View {
        ZStack {
            // LibraryView stays alive at all times — never destroyed.
            // This preserves the NSScrollView and its scroll position naturally.
            LibraryView()
                .allowsHitTesting(library.openComic == nil)
                .opacity(library.openComic == nil ? 1 : 0)

            if let comic = library.openComic {
                ReaderView(comic: comic)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
