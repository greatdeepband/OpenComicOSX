import SwiftUI
import AppKit

/// SwiftUI wrapper around `NSVisualEffectView` with the `.titlebar` material.
/// Used as the custom reader top-bar background so it matches the native
/// macOS window-toolbar chrome exactly. `SwiftUI`'s `.bar` material is close
/// but uses different vibrancy — this is the actual system titlebar look.
struct TitlebarEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .titlebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Reaches up to the hosting NSWindow and configures it to draw content under
/// the title-bar / traffic-light region. `.windowStyle(.hiddenTitleBar)` only
/// hides the title text; these three NSWindow knobs are what actually make
/// the window chrome one continuous strip with our content underneath.
struct FullSizeTitleBarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // Hairline divider at the bottom of the title-bar area looks odd
            // when our custom bar provides its own Divider; turn it off.
            window.isMovableByWindowBackground = false
        }
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct ReaderView: View {
    @EnvironmentObject var library: LibraryViewModel
    @StateObject private var vm: ReaderViewModel

    init(comic: Comic) {
        _vm = StateObject(wrappedValue: ReaderViewModel(comic: comic))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Reader content fills the full window height. The NSScrollView
            // inside MetalPageView therefore stretches from the top of the
            // window's content view to the bottom — avoiding the macOS 26
            // (Tahoe) bug where a non-full-height NSScrollView lets its
            // content render OVER anything above it in the same layout tree.
            // See: https://troz.net/post/2026/appkit-table-scroll-bug-in-macos-tahoe/
            GeometryReader { geo in
                ZStack {
                    Color.black
                    // NOTE: no .padding(.top, readerTopBarHeight) here —
                    // applying SwiftUI padding frames the NSScrollView at
                    // Y=topBarHeight, which defeats the macOS 26 Tahoe
                    // scroll-into-header workaround (the scroll view must
                    // stretch top-to-bottom of the window). Metal-backed
                    // branches use NSScrollView.contentInsets instead;
                    // SwiftUI-only branches (SpreadView, for now) apply their
                    // own top padding internally.
                    modeContent(containerSize: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in vm.containerSize = newSize }
                .onAppear { vm.containerSize = geo.size }
            }

            // Top bar overlay — sits visually above the reader content.
            VStack(spacing: 0) {
                readerTopBar
                Divider()
            }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .navigationTitle(vm.comic.title)
        .onAppear  { KeyMonitor.shared.start(handler: handleKey); let msg = "ReaderView.onAppear — readingMode=\(vm.readingMode), currentPage=\(vm.currentPage), savedScrollOffset=\(String(describing: vm.savedScrollOffset))"; print("[DEBUG] \(msg)"); Task { await DCLogger.shared.log(msg) } }
        .onDisappear { if library.openComic == nil { KeyMonitor.shared.stop() } }
    }

    /// Height of the reader top bar. Used to inset `modeContent`'s top edge
    /// so the page doesn't render behind the bar. Must match the bar's
    /// intrinsic height — currently 38pt per `readerTopBar`.
    private var readerTopBarHeight: CGFloat { 38 }

    private func handleKey(_ key: MonitoredKey) {
        let isVertical = vm.readingMode == .verticalScroll || vm.readingMode == .verticalDouble
        switch key {
        case .leftArrow, .keyA:   if !isVertical { vm.previousPage() }
        case .rightArrow, .keyD:  if !isVertical { vm.nextPage() }
        case .upArrow, .keyW:     if !isVertical { vm.zoomIn() }
        case .downArrow, .keyS:   if !isVertical { vm.zoomOut() }
        case .keyQ:               library.openAdjacentComic(offset: -1, currentMode: vm.readingMode.rawValue)
        case .keyE:               library.openAdjacentComic(offset:  1, currentMode: vm.readingMode.rawValue)
        case .backspace, .keyZ:  library.closeComic()
        case .cmdF:               toggleFullscreen()
        case .key1:               vm.readingMode = .singlePage;     vm.saveMode()
        case .key2:               vm.readingMode = .doublePage;     vm.saveMode()
        case .key3:               vm.readingMode = .verticalScroll; vm.saveMode()
        case .key4:               vm.readingMode = .verticalDouble; vm.saveMode()
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
        MetalPageView(
            pages: vm.comic.pages,
            layout: .singlePage,
            currentPage: vm.currentPage,
            pagesPerRow: 1,
            scale: vm.scale,
            containerWidth: containerSize.width,
            restorePage: vm.currentPage,
            restoreOffset: nil,
            pageManager: vm.pageManager,
            topContentInset: readerTopBarHeight,
            onPageChanged: { _ in /* single-page does not scroll between pages */ },
            onOffsetChanged: { _ in /* single-page ignores scroll fraction */ },
            onMagnificationChanged: { newScale in
                vm.setScaleFromScrollView(newScale)
            }
        )
    }

    // MARK: - Double Page

    @ViewBuilder
    private func doublePageView(containerSize: CGSize) -> some View {
        let _ = vm.cacheVersion  // creates SwiftUI dependency — re-evaluates when a page decode completes
        let leftIsSpread = vm.currentPage < vm.pageCount && vm.comic.pages[vm.currentPage].isSpread
        let leftImage  = vm.currentImage
        // Spread pages occupy the full slot alone — no right page.
        let rightImage: NSImage? = leftIsSpread ? nil : {
            let next = vm.currentPage + 1
            guard next < vm.pageCount else { return nil }
            return vm.image(for: next)
        }()

        SpreadView(
            leftImage: leftImage,
            rightImage: rightImage,
            leftIsSpread: leftIsSpread,
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
        // SpreadView is still SwiftUI-rendered in phase A-1; reserve top-bar
        // space via SwiftUI padding. Phase A-2 will migrate this to
        // MetalPageView + topContentInset.
        .padding(.top, readerTopBarHeight)
    }

    // MARK: - Vertical Scroll (single or double column)

    @ViewBuilder
    private func verticalScrollView(containerSize: CGSize, pagesPerRow: Int) -> some View {
        ZStack {
            MetalPageView(
                pages: vm.comic.pages,
                layout: .verticalStack(pagesPerRow: pagesPerRow),
                currentPage: vm.currentPage,
                pagesPerRow: pagesPerRow,
                scale: vm.scale,
                containerWidth: containerSize.width,
                restorePage: vm.currentPage,
                restoreOffset: vm.savedScrollOffset,
                pageManager: vm.pageManager,
                topContentInset: readerTopBarHeight,
                onPageChanged: { page in vm.updateCurrentPage(page) },
                onOffsetChanged: { fraction in vm.scrollOffsetFraction = fraction },
                onMagnificationChanged: { newScale in
                    vm.setScaleFromScrollView(newScale)
                }
            )
            // Note: NSScrollView handles scroll-wheel zoom natively via its own
            // magnification system — no SwiftUI .onScrollWheel intercept needed.
        }
    }

    // MARK: - Custom top bar

    /// Back button pinned to the left, trailing cluster pinned to the right
    /// (HStack with a Spacer between them). The transport sits on top of the
    /// same ZStack and uses the ZStack's default .center alignment — so it
    /// lands at the bar's exact horizontal midpoint regardless of how wide
    /// the back or trailing clusters are.
    @ViewBuilder
    private var readerTopBar: some View {
        ZStack {
            HStack(spacing: 10) {
                // Leading gutter reserves room for the traffic-light controls
                // that live in the same strip (.windowStyle(.hiddenTitleBar)).
                Spacer().frame(width: 72)
                backButton
                Spacer()
                trailingCluster
            }
            transportCluster
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(TitlebarEffectView())
    }

    private var backButton: some View {
        Button {
            vm.persistCurrentPosition()
            library.closeComic()
        } label: {
            Label("Library", systemImage: "chevron.left")
        }
        .help("Back to Library")
    }

    private var transportCluster: some View {
        let isVertical = vm.readingMode == .verticalScroll || vm.readingMode == .verticalDouble
        return HStack(spacing: 6) {
            Button {
                vm.persistCurrentPosition()
                library.openAdjacentComic(offset: -1, currentMode: vm.readingMode.rawValue)
            } label: {
                Image(systemName: "chevron.left.2")
            }
            .disabled(library.adjacentComicURL(offset: -1) == nil)
            .help("Previous comic (Q)")

            Button { vm.previousPage() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(vm.currentPage == 0 || isVertical)
            .help("Previous page (←/A)")

            Text("\(vm.currentPage + 1) / \(vm.pageCount)")
                .monospacedDigit()
                .font(.callout)
                .frame(minWidth: 72)

            Button { vm.nextPage() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(vm.currentPage >= vm.pageCount - 1 || isVertical)
            .help("Next page (→/D)")

            Button {
                vm.persistCurrentPosition()
                library.openAdjacentComic(offset: +1, currentMode: vm.readingMode.rawValue)
            } label: {
                Image(systemName: "chevron.right.2")
            }
            .disabled(library.adjacentComicURL(offset: +1) == nil)
            .help("Next comic (E)")
        }
    }

    private var trailingCluster: some View {
        HStack(spacing: 8) {
            if let url = library.lastOpenedURL {
                let fav = library.isFavorite(url: url)
                Button { library.toggleFavorite(url: url) } label: {
                    Image(systemName: fav ? "heart.fill" : "heart")
                        .foregroundStyle(fav ? Color.red : Color.primary)
                }
                .help(fav ? "Remove from Favorites" : "Add to Favorites")
            }

            Menu {
                Section("Zoom") {
                    Button("Zoom In")  { vm.zoomIn() }
                        .keyboardShortcut("=", modifiers: [.command])
                    Button("Zoom Out") { vm.zoomOut() }
                        .keyboardShortcut("-", modifiers: [.command])
                    Divider()
                    Button("Actual Size (100%)") { vm.zoomToActualSize() }
                    Button("Fit to Width")       { vm.fitToWidth(containerWidth: vm.containerSize.width) }
                    Button("Reset Zoom")         { vm.resetZoom() }
                }
                Section("Reading Mode") {
                    ForEach(ReadingMode.allCases, id: \.self) { mode in
                        Button {
                            vm.readingMode = mode
                            vm.saveMode()
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                if vm.readingMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Toggle Full Screen") { toggleFullscreen() }
                        .keyboardShortcut("f", modifiers: [.command, .control])
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("More options")
        }
    }
}

// MARK: - Spread view (Double Page — side-by-side with spread support)

/// Renders two pages side by side. When `leftIsSpread` is true, renders the
/// left image full-width (double-scan spread page). Right-click loupe shows
/// a magnified crop of the hovered page.
struct SpreadView: View {
    let leftImage:  NSImage?
    let rightImage: NSImage?
    let leftIsSpread: Bool
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
        let scaledTotal = containerSize.width * scale
        let pageW = (scaledTotal - 2) / 2
        let pageH = containerSize.height * scale

        ZStack {
            if leftIsSpread {
                if let img = leftImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: scaledTotal, height: pageH)
                        .offset(x: offset.width, y: offset.height)
                }
            } else {
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
            }

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

            // MouseCatcher handles pan + loupe
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
                    computeLoupe(at: pos)
                    showLoupe = true
                },
                onRightMoved: { pos in
                    loupePosition = pos
                    computeLoupe(at: pos)
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

    /// Compute loupe parameters for the page under the cursor.
    /// Spread mode: single full-width image. Normal mode: split at midX.
    private func computeLoupe(at pos: CGPoint) {
        let scaledTotal = containerSize.width * scale
        let spreadOrigin = (containerSize.width - scaledTotal) / 2 + offset.width
        let midX = spreadOrigin + scaledTotal / 2

        let isRight = pos.x >= midX && !leftIsSpread && rightImage != nil
        let img: NSImage
        let pageW: CGFloat

        if leftIsSpread {
            guard let left = leftImage else { return }
            img = left
            pageW = scaledTotal
        } else if isRight {
            guard let r = rightImage else { return }
            img = r
            pageW = (scaledTotal - 2) / 2
        } else {
            guard let l = leftImage else { return }
            img = l
            pageW = (scaledTotal - 2) / 2
        }

        let spreadH = containerSize.height * scale
        let localX: CGFloat
        if isRight && !leftIsSpread {
            localX = pos.x - midX
        } else {
            localX = pos.x - spreadOrigin
        }
        let localPos = CGPoint(x: localX, y: pos.y - (containerSize.height - spreadH) / 2 - offset.height)

        let pageContainerSize = CGSize(width: pageW, height: spreadH)
        let imgAR = img.size.width / img.size.height
        let conAR = pageContainerSize.width / pageContainerSize.height
        let ivSize: CGSize = imgAR > conAR
            ? CGSize(width: pageContainerSize.width, height: pageContainerSize.width / imgAR)
            : CGSize(width: pageContainerSize.height * imgAR, height: pageContainerSize.height)

        let ox = (pageContainerSize.width - ivSize.width) / 2
        let oy = (pageContainerSize.height - ivSize.height) / 2
        let cursorInIV = CGPoint(x: localPos.x - ox, y: localPos.y - oy)

        loupeImage = img
        loupeImageViewSize = ivSize
        loupeCursorInImage = cursorInIV
    }
}

// MARK: - Global key monitor (singleton)

enum MonitoredKey { case leftArrow, rightArrow, upArrow, downArrow, keyA, keyD, keyW, keyS, keyQ, keyE, backspace, cmdF, key1, key2, key3, key4, keyZ }

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
            let cmd  = event.modifierFlags.contains(.command)
            let none = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch (event.keyCode, cmd, none) {
            case (123, _, true): handler(.leftArrow);  return nil  // ←
            case (124, _, true): handler(.rightArrow); return nil  // →
            case (125, _, true): handler(.downArrow);  return nil  // ↓
            case (126, _, true): handler(.upArrow);    return nil  // ↑
            case (0,  _, true):  handler(.keyA);       return nil  // A
            case (2,  _, true):  handler(.keyD);       return nil  // D
            case (13, _, true):  handler(.keyW);       return nil  // W
            case (1,  _, true):  handler(.keyS);       return nil  // S
            case (12, _, true):  handler(.keyQ);       return nil  // Q
            case (14, _, true):  handler(.keyE);       return nil  // E
            case (51, _, true):  handler(.backspace);  return nil  // ⌫
            case (3, true, _):   handler(.cmdF);       return nil  // Cmd+F
            case (18, _, true):  handler(.key1);       return nil  // 1
            case (19, _, true):  handler(.key2);       return nil  // 2
            case (20, _, true):  handler(.key3);       return nil  // 3
            case (21, _, true):  handler(.key4);       return nil  // 4
            case (6,  _, true):  handler(.keyZ);       return nil  // Z
            default:             return event
            }
        }
    }

    func stop() {
        handler = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
