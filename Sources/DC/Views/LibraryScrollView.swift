import SwiftUI

func appendScrollLog(_ s: String) {
    let data = Data(s.utf8)
    let path = "/tmp/scroll_debug.txt"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Scroll offset tracking via GeometryReader + PreferenceKey

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Invisible background view that reports the VStack's Y position in global coordinates.
/// When the user scrolls down by N points, the VStack moves up by N points, so
/// globalFrame.minY decreases. Scroll offset = -(globalFrame.minY - initialMinY).
/// We use a named coordinate space "libraryScroll" anchored to the ScrollView.
struct ScrollOffsetTracker: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .preference(
                    key: ScrollOffsetKey.self,
                    // minY in the "libraryScroll" coordinate space is negative of scroll offset
                    value: -geo.frame(in: .named("libraryScroll")).minY
                )
        }
        .frame(height: 0)
    }
}

// MARK: - NSView helper

import AppKit

extension NSView {
    /// Finds the first NSScrollView in the receiver's subview tree (depth-first).
    var firstScrollView: NSScrollView? {
        if let sv = self as? NSScrollView { return sv }
        for sub in subviews {
            if let found = sub.firstScrollView { return found }
        }
        return nil
    }
}
