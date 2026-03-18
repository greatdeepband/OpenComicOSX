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
                modeContent(containerSize: geo.size)
            }
            // Pass real container size to vm so Fit to Width works correctly.
            .onChange(of: geo.size) { _, newSize in vm.containerSize = newSize }
            .onAppear { vm.containerSize = geo.size }
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

    // MARK: - Mode content

    @ViewBuilder
    private func modeContent(containerSize: CGSize) -> some View {
        switch vm.readingMode {
        case .singlePage:
            singlePageView(containerSize: containerSize)

        case .doublePage:
            doublePageView(containerSize: containerSize)

        case .verticalScroll:
            verticalScrollView(containerSize: containerSize)
        }
    }

    // MARK: - Single Page

    @ViewBuilder
    private func singlePageView(containerSize: CGSize) -> some View {
        if let image = vm.currentImage {
            ZoomableImageView(
                image: image,
                scale: $vm.scale,
                offset: $vm.offset,
                minScale: vm.minScale,
                maxScale: vm.maxScale
            )
            .gesture(TapGesture(count: 2).onEnded {
                if vm.scale > 1.05 { vm.resetZoom() }
                else { vm.fitToWidth(containerWidth: containerSize.width) }
            })
        } else {
            Text("No pages found").foregroundStyle(.secondary)
        }
    }

    // MARK: - Double Page

    @ViewBuilder
    private func doublePageView(containerSize: CGSize) -> some View {
        let leftImage  = vm.currentImage
        let rightImage: NSImage? = {
            let next = vm.currentPage + 1
            guard next < vm.pageCount else { return nil }
            return vm.comic.pages[next].image
        }()

        HStack(spacing: 2) {
            if let img = leftImage {
                LoupableImage(image: img)
                    .frame(maxWidth: containerSize.width / 2, maxHeight: containerSize.height)
            }
            if let img = rightImage {
                LoupableImage(image: img)
                    .frame(maxWidth: containerSize.width / 2, maxHeight: containerSize.height)
            } else {
                Spacer().frame(maxWidth: containerSize.width / 2)
            }
        }
        .scaleEffect(vm.scale)
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
        .contentShape(Rectangle())
        .onScrollWheel { event in
            let factor: CGFloat = event.deltaY > 0 ? 0.95 : 1.05
            vm.scale = (vm.scale * factor).clamped(to: vm.minScale...vm.maxScale)
        }
        .gesture(MagnifyGesture()
            .onEnded { v in
                vm.scale = (vm.scale * v.magnification).clamped(to: vm.minScale...vm.maxScale)
            }
        )
        .onTapGesture(count: 2) {
            if vm.scale > 1.05 { vm.resetZoom() }
            else { vm.fitToWidth(containerWidth: containerSize.width) }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -30 {
                vm.goTo(page: min(vm.currentPage + 2, vm.pageCount - 1))
            } else if v.translation.width > 30 {
                vm.goTo(page: max(vm.currentPage - 2, 0))
            }
        })
    }

    // MARK: - Vertical Scroll

    @ViewBuilder
    private func verticalScrollView(containerSize: CGSize) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    ForEach(vm.comic.pages) { page in
                        LoupableImage(image: page.image)
                            .frame(maxWidth: containerSize.width * vm.scale,
                                   maxHeight: containerSize.height * vm.scale)
                            .id(page.id)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(vm.currentPage, anchor: .top)
            }
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
                Button("Fit to Width")    { vm.fitToWidth(containerWidth: vm.containerSize.width) }
                Button("Actual Size (100%)") { vm.zoomToActualSize() }
                Divider()
                ForEach(ReadingMode.allCases, id: \.self) { mode in
                    Button(action: { vm.readingMode = mode }) {
                        HStack {
                            Text(mode.rawValue)
                            if vm.readingMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Global key monitor (singleton)

enum MonitoredKey { case leftArrow, rightArrow, upArrow, downArrow, cmdF }

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
            case (3,   true):  handler(.cmdF);       return nil
            default:           return event
            }
        }
    }

    func stop() {
        handler = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
