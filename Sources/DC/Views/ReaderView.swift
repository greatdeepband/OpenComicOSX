import SwiftUI
import AppKit

struct ReaderView: View {
    @EnvironmentObject var library: LibraryViewModel
    @StateObject private var vm: ReaderViewModel

    init(comic: Comic) {
        _vm = StateObject(wrappedValue: ReaderViewModel(comic: comic))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                pageContent(containerSize: geo.size)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(vm.comic.title)
        // Install a local event monitor so arrow keys work regardless of focus.
        .background(KeyEventHandler { key in
            switch key {
            case .leftArrow:  vm.previousPage()
            case .rightArrow: vm.nextPage()
            case .upArrow:    vm.zoomIn()
            case .downArrow:  vm.zoomOut()
            }
        })
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageContent(containerSize: CGSize) -> some View {
        if let image = vm.currentImage {
            ZoomableImageView(
                image: image,
                scale: $vm.scale,
                offset: $vm.offset,
                minScale: vm.minScale,
                maxScale: vm.maxScale
            )
            .gesture(
                TapGesture(count: 2).onEnded {
                    if vm.scale > 1.05 {
                        vm.resetZoom()
                    } else {
                        vm.fitToWidth(containerWidth: containerSize.width)
                    }
                }
            )
        } else {
            Text("No pages found")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: { library.closeComic() }) {
                Label("Library", systemImage: "chevron.left")
            }
        }

        ToolbarItemGroup(placement: .principal) {
            Button(action: { vm.previousPage() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(vm.currentPage == 0)

            Text("\(vm.currentPage + 1) / \(vm.pageCount)")
                .monospacedDigit()
                .frame(minWidth: 80)

            Button(action: { vm.nextPage() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(vm.currentPage >= vm.pageCount - 1)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { vm.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
            }

            Text(String(format: "%.0f%%", vm.scale * 100))
                .monospacedDigit()
                .frame(minWidth: 48)

            Button(action: { vm.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
            }

            Button(action: { vm.resetZoom() }) {
                Image(systemName: "1.magnifyingglass")
            }

            Menu {
                Button("Fit to Width") {
                    vm.fitToWidth(containerWidth: 900)
                }
                Button("Actual Size (100%)") { vm.zoomToActualSize() }
                Divider()
                ForEach(ReadingMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { vm.readingMode = mode }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Key event handler

enum ArrowKey { case leftArrow, rightArrow, upArrow, downArrow }

/// Installs an NSEvent local monitor for key-down events.
/// Fires the callback for arrow keys and suppresses the event so it doesn't
/// propagate to other responders (e.g. scroll views).
struct KeyEventHandler: NSViewRepresentable {
    let onArrowKey: (ArrowKey) -> Void

    func makeNSView(context: Context) -> _KeyHandlerView {
        let v = _KeyHandlerView()
        v.onArrowKey = onArrowKey
        return v
    }

    func updateNSView(_ v: _KeyHandlerView, context: Context) {
        v.onArrowKey = onArrowKey
    }
}

final class _KeyHandlerView: NSView {
    var onArrowKey: ((ArrowKey) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 123: self.onArrowKey?(.leftArrow);  return nil   // suppress
                case 124: self.onArrowKey?(.rightArrow); return nil
                case 125: self.onArrowKey?(.downArrow);  return nil
                case 126: self.onArrowKey?(.upArrow);    return nil
                default:  return event
                }
            }
        } else {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
