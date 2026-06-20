import SwiftUI
import AppKit

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
            // Make sure the traffic lights stay visible — `.windowStyle
            // (.hiddenTitleBar)` plus `.toolbar(.hidden, for: .windowToolbar)`
            // can leave the standardWindowButtons hidden in some macOS
            // versions; re-asserting them here is cheap and idempotent.
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
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

    /// SwiftUI loupe overlay state. MetalPageView's Coordinator emits a
    /// `LoupeOverlayState?` on every drag frame; we render the circle here
    /// as a SwiftUI MagnifierView so the reader's ZStack bounds naturally
    /// clip the loupe to the reader frame.
    @State private var metalLoupe: LoupeOverlayState? = nil

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
                    Color(NSColor.windowBackgroundColor)
                    // NOTE: no .padding(.top, readerTopBarHeight) here —
                    // applying SwiftUI padding frames the NSScrollView at
                    // Y=topBarHeight, which defeats the macOS 26 Tahoe
                    // scroll-into-header workaround (the scroll view must
                    // stretch top-to-bottom of the window).
                    // MetalPageView reserves the top-bar band internally
                    // via NSScrollView.contentInsets.
                    modeContent(containerSize: geo.size)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Page \(vm.currentPage+1) of \(vm.pageCount), \(vm.comic.title)")
                        .onChange(of: vm.currentPage) { _, _ in
                            NSAccessibility.post(
                                element: (NSApp.keyWindow ?? NSApp.mainWindow) as Any,
                                notification: .announcementRequested,
                                userInfo: [
                                    .announcement: "Page \(vm.currentPage+1) of \(vm.pageCount)",
                                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                                ]
                            )
                        }
                    // Loupe overlay — sits in the same ZStack so the top bar
                    // (rendered above in the outer ZStack) covers it as the
                    // cursor approaches the top, and the window edge clips
                    // the circle on every other side.
                    if let loupe = metalLoupe {
                        MagnifierView(
                            image: loupe.image,
                            cursorInImageView: loupe.cursorInImage,
                            imageViewSize: loupe.imageViewSize
                        )
                        .position(x: loupe.position.x, y: loupe.position.y)
                        .allowsHitTesting(false)
                    }
                }
                // .clipped() removed — was suspected to cause black state on
                // mode switch. The window itself clips, and the loupe overlay
                // is naturally bounded by the SwiftUI hierarchy.
                .onChange(of: geo.size) { _, newSize in vm.containerSize = newSize }
                .onAppear { vm.containerSize = geo.size }
            }

            // Top bar overlay — sits visually above the reader content.
            // Geometry invariant: bar (topBarHeight - scrubberStripHeight = 50pt)
            // + scrubber (scrubberStripHeight = 22pt) = topBarHeight (72pt).
            // The separator under the buttons is drawn as an OVERLAY (not a
            // layout Divider) so it adds no height — keeping the scrubber's
            // bottom edge at window-Y == topBarHeight, inside isInTopBarBand.
            VStack(spacing: 0) {
                readerTopBar
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(ReaderConstants.toolbarSegmentDividerOpacity))
                            .frame(height: 1)
                    }
                // Scrubber strip — framed at scrubberStripHeight so its bottom
                // edge sits at window-Y == topBarHeight → inside the band.
                PageScrubber(vm: vm)
                    .frame(height: ReaderConstants.scrubberStripHeight)
                    .padding(.horizontal, 24)
            }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .background(FullSizeTitleBarConfigurator())
        .navigationTitle(vm.comic.title)
        .onAppear { KeyMonitor.shared.start(handler: handleKey); Task { await DCLogger.shared.log("ReaderView.onAppear — readingMode=\(vm.readingMode), currentPage=\(vm.currentPage), savedScrollOffset=\(String(describing: vm.savedScrollOffset))") } }
        .onDisappear { if library.openComic == nil { KeyMonitor.shared.stop() } }
    }

    /// Height of the reader top bar. Used to inset `modeContent`'s top edge
    /// so the page doesn't render behind the bar. Must match the bar's
    /// intrinsic height — currently sourced from `ReaderConstants.topBarHeight`.
    private var readerTopBarHeight: CGFloat { ReaderConstants.topBarHeight }

    private func handleKey(_ key: MonitoredKey) {
        let isVertical = vm.readingMode == .verticalScroll || vm.readingMode == .verticalDouble
        switch key {
        case .leftArrow, .keyA:
            if !isVertical {
                switch navStep(forwardInput: false, isRTL: vm.isRTL) {
                case .next: vm.nextPage()
                case .prev: vm.previousPage()
                }
            }
        case .rightArrow, .keyD:
            if !isVertical {
                switch navStep(forwardInput: true, isRTL: vm.isRTL) {
                case .next: vm.nextPage()
                case .prev: vm.previousPage()
                }
            }
        case .upArrow, .keyW:     if !isVertical { vm.zoomIn() }
        case .downArrow, .keyS:   if !isVertical { vm.zoomOut() }
        // Persist BEFORE leaving the comic — the toolbar buttons do this, but
        // the keyboard equivalents previously didn't, so exiting a vertical
        // comic via Q/E/Z/Backspace silently discarded the session's scroll
        // offset (only persistCurrentPosition saves it in vertical modes).
        case .keyQ:               vm.persistCurrentPosition()
                                  library.openAdjacentComic(offset: -1, currentMode: vm.readingMode.rawValue)
        case .keyE:               vm.persistCurrentPosition()
                                  library.openAdjacentComic(offset:  1, currentMode: vm.readingMode.rawValue)
        case .backspace, .keyZ:  vm.persistCurrentPosition()
                                  library.closeComic()
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
            containerHeight: containerSize.height,
            isRTL: vm.isRTL,
            restorePage: vm.currentPage,
            restoreOffset: nil,
            pageManager: vm.pageManager,
            topContentInset: readerTopBarHeight,
            scrollRequestNonce: vm.scrollRequestNonce,
            onPageChanged: { _ in /* single-page does not scroll between pages */ },
            onOffsetChanged: { _ in /* single-page ignores scroll fraction */ },
            onMagnificationChanged: { newScale in
                vm.setScaleFromScrollView(newScale)
            },
            onLoupeOverlay: { state in metalLoupe = state },
            onPageNavSwipe: { offset in
                switch navStep(forwardInput: offset > 0, isRTL: vm.isRTL) {
                case .next: vm.nextPage()
                case .prev: vm.previousPage()
                }
            },
            onComicNavSwipe: { offset in
                library.openAdjacentComic(offset: offset, currentMode: vm.readingMode.rawValue)
            }
        )
    }

    // MARK: - Double Page

    @ViewBuilder
    private func doublePageView(containerSize: CGSize) -> some View {
        MetalPageView(
            pages: vm.comic.pages,
            layout: .doubleSpread,
            currentPage: vm.currentPage,
            pagesPerRow: 2,
            scale: vm.scale,
            containerWidth: containerSize.width,
            containerHeight: containerSize.height,
            isRTL: vm.isRTL,
            restorePage: vm.currentPage,
            restoreOffset: nil,
            pageManager: vm.pageManager,
            topContentInset: readerTopBarHeight,
            scrollRequestNonce: vm.scrollRequestNonce,
            onPageChanged: { _ in /* double-page advances via keyboard, not scroll */ },
            onOffsetChanged: { _ in /* double-page ignores scroll fraction */ },
            onMagnificationChanged: { newScale in
                vm.setScaleFromScrollView(newScale)
            },
            onLoupeOverlay: { state in metalLoupe = state },
            onPageNavSwipe: { offset in
                switch navStep(forwardInput: offset > 0, isRTL: vm.isRTL) {
                case .next: vm.nextPage()
                case .prev: vm.previousPage()
                }
            },
            onComicNavSwipe: { offset in
                library.openAdjacentComic(offset: offset, currentMode: vm.readingMode.rawValue)
            }
        )
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
                // Live in-session offset (vm.scrollOffsetFraction) is what we
                // use to remember position across mode switches. Falls back
                // to the on-disk savedScrollOffset on first comic open. The
                // saved fraction is only valid for the same pagesPerRow it
                // was captured under — switching between vertical-single (1)
                // and vertical-double (2) changes the doc height, so the
                // fraction would land the user on the wrong page. In that
                // case, pass nil so the page-based restore takes over.
                restoreOffset: {
                    if vm.scrollOffsetPagesPerRow == pagesPerRow,
                       vm.scrollOffsetFraction != 0 {
                        return vm.scrollOffsetFraction
                    }
                    if vm.scrollOffsetFraction == 0 {
                        guard ReadingPositionStore.shouldUseSavedOffset(
                            savedPagesPerRow: vm.savedScrollPagesPerRow,
                            currentPagesPerRow: pagesPerRow
                        ) else { return nil }
                        return vm.savedScrollOffset
                    }
                    return nil
                }(),
                pageManager: vm.pageManager,
                topContentInset: readerTopBarHeight,
                scrollRequestNonce: vm.scrollRequestNonce,
                onPageChanged: { page in vm.updateCurrentPage(page) },
                onOffsetChanged: { fraction in
                    vm.scrollOffsetFraction = fraction
                    vm.scrollOffsetPagesPerRow = pagesPerRow
                },
                onMagnificationChanged: { newScale in
                    vm.setScaleFromScrollView(newScale)
                },
                onLoupeOverlay: { state in metalLoupe = state }
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
    /// Reader's top-bar chrome — three Liquid-Glass capsules over a
    /// transparent strip. Implementation lives in `ReaderToolbar.swift`.
    private var readerTopBar: some View {
        ReaderToolbar(vm: vm,
                      library: library,
                      onToggleFullScreen: toggleFullscreen)
    }
}


// MARK: - Global key monitor (singleton)

enum MonitoredKey { case leftArrow, rightArrow, upArrow, downArrow, keyA, keyD, keyW, keyS, keyQ, keyE, backspace, key1, key2, key3, key4, keyZ }

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
