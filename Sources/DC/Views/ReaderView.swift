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
        .onAppear  { KeyMonitor.shared.start(handler: handleKey) }
        .onDisappear { KeyMonitor.shared.stop() }
    }

    private func handleKey(_ key: MonitoredKey) {
        switch key {
        case .leftArrow:   vm.previousPage()
        case .rightArrow:  vm.nextPage()
        case .upArrow:     vm.zoomIn()
        case .downArrow:   vm.zoomOut()
        case .cmdF:        toggleFullscreen()
        }
    }

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
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

            Button(action: { toggleFullscreen() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }

            Menu {
                Button("Fit to Width") { vm.fitToWidth(containerWidth: 900) }
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

// MARK: - Global key monitor (singleton)

enum MonitoredKey {
    case leftArrow, rightArrow, upArrow, downArrow, cmdF
}

/// Singleton NSEvent local monitor. Installed on .onAppear, removed on .onDisappear.
/// Using a singleton avoids duplicate monitors when the view re-renders.
final class KeyMonitor {
    static let shared = KeyMonitor()
    private var monitor: Any?
    private var handler: ((MonitoredKey) -> Void)?

    private init() {}

    func start(handler: @escaping (MonitoredKey) -> Void) {
        self.handler = handler
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let handler = self.handler else { return event }

            let cmd = event.modifierFlags.contains(.command)

            switch (event.keyCode, cmd) {
            case (123, false): handler(.leftArrow);  return nil
            case (124, false): handler(.rightArrow); return nil
            case (125, false): handler(.downArrow);  return nil
            case (126, false): handler(.upArrow);    return nil
            case (3,   true):  handler(.cmdF);       return nil   // keyCode 3 = F
            default:           return event
            }
        }
    }

    func stop() {
        handler = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
