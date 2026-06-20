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
                    .id(comic.url)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        // Configure the NSWindow so content extends under the title-bar
        // region. DCApp uses the default `.titleBar` window style; this
        // FullSizeTitleBarConfigurator makes the title bar full-size +
        // transparent, giving one integrated chrome strip instead of a
        // stacked title bar + content layout.
        .background(FullSizeTitleBarConfigurator())
    }
}
