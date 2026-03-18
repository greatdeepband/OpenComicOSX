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
            .onChange(of: geo.size) { _, newSize in vm.containerSize = newSize }
            .onAppear { vm.containerSize = geo.size }
        }
        .toolbar { toolbarContent }
        .navigationTitle(vm.comic.title)
        .onAppear  { KeyMonitor.shared.start(handler: handleKey) }
        .onDisappear { KeyMonitor.shared.stop() }
    }

    private func handleKey(_ key: MonitoredKey) {
        let isVertical = vm.readingMode == .verticalScroll || vm.readingMode == .verticalDouble
        switch key {
        case .leftArrow:   if !isVertical { vm.previousPage() }
        case .rightArrow:  if !isVertical { vm.nextPage() }
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
            verticalScrollView(containerSize: containerSize, pagesPerRow: 1)
        case .verticalDouble:
            verticalScrollView(containerSize: containerSize, pagesPerRow: 2)
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

        SpreadView(
            leftImage: leftImage,
            rightImage: rightImage,
            scale: $vm.scale,
            offset: $vm.offset,
            minScale: vm.minScale,
            maxScale: vm.maxScale,
            containerSize: containerSize,
            onDoubleTap: {
                if vm.scale > 1.05 { vm.resetZoom() }
                else { vm.fitToWidth(containerWidth: containerSize.width) }
            }
        )
    }

    // MARK: - Vertical Scroll (single or double column)

    @ViewBuilder
    private func verticalScrollView(containerSize: CGSize, pagesPerRow: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    if pagesPerRow == 1 {
                        ForEach(vm.comic.pages) { page in
                            LoupableImage(image: page.image)
                                .frame(maxWidth: containerSize.width * vm.scale)
                                .id(page.id)
                                // When this page's top edge enters the viewport, mark it as current.
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: TopPagePreferenceKey.self,
                                            value: geo.frame(in: .named("scroll")).minY < 80 ? page.id : -1
                                        )
                                    }
                                )
                        }
                    } else {
                        let totalWidth = containerSize.width * vm.scale
                        let pageWidth  = (totalWidth - 2) / 2
                        let pairs = stride(from: 0, to: vm.pageCount, by: 2).map { i -> (ComicPage, ComicPage?) in
                            let left = vm.comic.pages[i]
                            let right = (i + 1 < vm.pageCount) ? vm.comic.pages[i + 1] : nil
                            return (left, right)
                        }
                        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                            HStack(spacing: 2) {
                                LoupableImage(image: pair.0.image)
                                    .frame(width: pageWidth)
                                if let rightPage = pair.1 {
                                    LoupableImage(image: rightPage.image)
                                        .frame(width: pageWidth)
                                } else {
                                    Spacer()
                                        .frame(width: pageWidth)
                                }
                            }
                            .frame(width: totalWidth)
                            .id(pair.0.id)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TopPagePreferenceKey.self,
                                        value: geo.frame(in: .named("scroll")).minY < 80 ? pair.0.id : -1
                                    )
                                }
                            )
                        }
                    }
                }
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(TopPagePreferenceKey.self) { pageID in
                if pageID >= 0 && pageID != vm.currentPage {
                    vm.updateCurrentPage(pageID)
                }
            }
            .onScrollWheel { event in
                let factor: CGFloat = event.deltaY > 0 ? 0.95 : 1.05
                vm.scale = (vm.scale * factor).clamped(to: vm.minScale...vm.maxScale)
            }
            .onAppear {
                let targetPage = min(vm.currentPage, vm.pageCount - 1)
                guard targetPage > 0 else { return }
                Task { @MainActor in
                    // Retry until the scroll lands (LazyVStack renders lazily).
                    // Stop early once vm.currentPage reaches the target.
                    for _ in 0..<20 {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                        proxy.scrollTo(vm.comic.pages[targetPage].id, anchor: .top)
                        if !vm.isRestoringPosition { break } // tracker confirmed landing
                    }
                    vm.isRestoringPosition = false
                }
            }
        }
    }

    // Preference key: reports the page index nearest the top of the scroll view.
    private struct TopPagePreferenceKey: PreferenceKey {
        static var defaultValue: Int = -1
        static func reduce(value: inout Int, nextValue: () -> Int) {
            let next = nextValue()
            // Take the highest page index that is still within the viewport top area.
            if next >= 0 { value = next }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: {
                vm.persistCurrentPosition()
                library.closeComic()
            }) {
                Label("Library", systemImage: "chevron.left")
            }
        }

        ToolbarItemGroup(placement: .principal) {
            let isVertical = vm.readingMode == .verticalScroll || vm.readingMode == .verticalDouble
            Button(action: { vm.previousPage() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(vm.currentPage == 0 || isVertical)

            Text("\(vm.currentPage + 1) / \(vm.pageCount)")
                .monospacedDigit()
                .frame(minWidth: 80)

            Button(action: { vm.nextPage() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(vm.currentPage >= vm.pageCount - 1 || isVertical)
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
                    Button(action: { vm.readingMode = mode; vm.saveMode() }) {
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

// MARK: - Spread view (Double Page with spread-level loupe)

/// Renders two pages side by side with a single MouseCatcher covering the whole spread.
/// The loupe samples from whichever page the cursor is over, eliminating the cross-boundary glitch.
struct SpreadView: View {
    let leftImage:  NSImage?
    let rightImage: NSImage?
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    let minScale: CGFloat
    let maxScale: CGFloat
    let containerSize: CGSize
    let onDoubleTap: () -> Void

    @State private var showLoupe = false
    @State private var loupePosition: CGPoint = .zero
    @State private var loupeImage: NSImage? = nil
    @State private var loupeImageViewSize: CGSize = .zero
    @State private var loupeCursorInImage: CGPoint = .zero

    var body: some View {
        // Derive live page width from container + scale so pages reflow on window resize.
        let scaledTotal = containerSize.width * scale
        let pageW = (scaledTotal - 2) / 2  // 2pt gap
        let pageH = containerSize.height * scale

        ZStack {
            // Pages — use real frame widths, no scaleEffect
            HStack(spacing: 2) {
                if let img = leftImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: pageW, height: pageH)
                }
                if let img = rightImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: pageW, height: pageH)
                } else {
                    Spacer().frame(width: pageW)
                }
            }
            .frame(width: scaledTotal)
            .offset(x: offset.width, y: offset.height)

            // Loupe overlay
            if showLoupe, let img = loupeImage {
                MagnifierView(
                    image: img,
                    cursorInImageView: loupeCursorInImage,
                    imageViewSize: loupeImageViewSize
                )
                .position(x: loupePosition.x, y: loupePosition.y)
                .allowsHitTesting(false)
            }

            // Single MouseCatcher covers the full spread
            MouseCatcher(
                onLeftDragBegan: { _ in },
                onLeftDragMoved: { delta in
                    guard scale > 1.0 else { return }
                    let spreadWidth  = containerSize.width  * scale
                    let spreadHeight = containerSize.height * scale
                    let maxX = max(0, (spreadWidth  - containerSize.width)  / 2)
                    let maxY = max(0, (spreadHeight - containerSize.height) / 2)
                    offset = CGSize(
                        width:  (offset.width  + delta.width) .clamped(to: -maxX...maxX),
                        height: (offset.height + delta.height).clamped(to: -maxY...maxY)
                    )
                },
                onLeftDragEnded: { _ in },
                onRightBegan: { pos in
                    loupePosition = pos
                    updateLoupe(at: pos)
                    showLoupe = true
                },
                onRightMoved: { pos in
                    loupePosition = pos
                    updateLoupe(at: pos)
                },
                onRightEnded: { showLoupe = false }
            )
            .allowsHitTesting(true)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
        .contentShape(Rectangle())
        .onScrollWheel { event in
            let factor: CGFloat = event.deltaY > 0 ? 0.95 : 1.05
            let newScale = (scale * factor).clamped(to: minScale...maxScale)
            scale = newScale
            if newScale <= 1.0 { offset = .zero }
        }
        .gesture(MagnifyGesture()
            .onEnded { v in
                let newScale = (scale * v.magnification).clamped(to: minScale...maxScale)
                scale = newScale
                if newScale <= 1.0 { offset = .zero }
            }
        )
        .onTapGesture(count: 2) { onDoubleTap() }
    }

    /// Determine which page the cursor is over and compute loupe parameters for that page.
    private func updateLoupe(at pos: CGPoint) {
        // Use the same scaled dimensions as the layout.
        let scaledTotal = containerSize.width * scale
        let pageW = (scaledTotal - 2) / 2
        let pageH = containerSize.height * scale
        // The spread is centred in the container; compute its origin.
        let spreadOriginX = (containerSize.width - scaledTotal) / 2 + offset.width
        let spreadOriginY = (containerSize.height - pageH) / 2 + offset.height

        // Which side is the cursor on?
        let leftEdge  = spreadOriginX
        let midX      = spreadOriginX + pageW + 2
        let isLeft    = pos.x < midX
        guard let img = isLeft ? leftImage : rightImage else { return }

        // Cursor relative to the page's top-left corner
        let localX = isLeft ? pos.x - leftEdge : pos.x - midX
        let localY = pos.y - spreadOriginY
        let localPos = CGPoint(x: localX, y: localY)
        let pageContainerSize = CGSize(width: pageW, height: pageH)

        // Compute rendered image size within its page frame (scaledToFit)
        let imgAR = img.size.width / img.size.height
        let conAR = pageContainerSize.width / pageContainerSize.height
        let ivSize: CGSize = imgAR > conAR
            ? CGSize(width: pageContainerSize.width, height: pageContainerSize.width / imgAR)
            : CGSize(width: pageContainerSize.height * imgAR, height: pageContainerSize.height)

        let ox = (pageContainerSize.width  - ivSize.width)  / 2
        let oy = (pageContainerSize.height - ivSize.height) / 2
        let cursorInIV = CGPoint(x: localPos.x - ox, y: localPos.y - oy)

        loupeImage = img
        loupeImageViewSize = ivSize
        loupeCursorInImage = cursorInIV
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
