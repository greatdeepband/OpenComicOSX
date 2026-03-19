import SwiftUI
import AppKit

/// A transparent NSViewRepresentable wrapper that sits inside the library ScrollView's
/// view hierarchy and continuously saves/restores the raw NSScrollView vertical offset.
/// This bypasses SwiftUI's LazyVGrid materialisation problem entirely.
struct LibraryScrollSaver: NSViewRepresentable {
    @Binding var offset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = _ScrollSaverView()
        view.offsetBinding = $offset
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? _ScrollSaverView else { return }
        // If the offset changed externally (reader close → restore), apply it.
        view.pendingRestore = offset
        view.applyRestoreIfNeeded()
    }
}

private final class _ScrollSaverView: NSView {
    var offsetBinding: Binding<CGFloat>?
    var pendingRestore: CGFloat = 0
    private var observer: NSObjectProtocol?
    private var hasRestored = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let sv = enclosingScrollView else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: sv,
            queue: .main
        ) { [weak self] _ in
            guard let self, let sv = self.enclosingScrollView else { return }
            let y = sv.contentView.bounds.origin.y
            self.offsetBinding?.wrappedValue = y
        }
        // Restore once the scroll view is in the window.
        applyRestoreIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
            hasRestored = false
        }
    }

    func applyRestoreIfNeeded() {
        guard !hasRestored, pendingRestore > 0,
              let sv = enclosingScrollView else { return }
        hasRestored = true
        DispatchQueue.main.async {
            sv.contentView.scroll(to: NSPoint(x: 0, y: self.pendingRestore))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }
}
