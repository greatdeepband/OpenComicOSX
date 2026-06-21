import SwiftUI
import AppKit

// MARK: - FocusedValue bridge (ReaderViewModel → menu commands)

struct ReaderVMKey: FocusedValueKey {
    typealias Value = ReaderViewModel
}

extension FocusedValues {
    var readerVM: ReaderViewModel? {
        get { self[ReaderVMKey.self] }
        set { self[ReaderVMKey.self] = newValue }
    }
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
            // Make sure the traffic lights stay visible — `.windowStyle
            // (.hiddenTitleBar)` plus `.toolbar(.hidden, for: .windowToolbar)`
            // can leave the standardWindowButtons hidden in some macOS
            // versions; re-asserting them here is cheap and idempotent.
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            // Enable .mouseMoved events so the ReaderView's local monitor
            // receives mouse-moved notifications for edge-triggered chrome reveal.
            // Without this, local NSEvent monitors for .mouseMoved are silently dead.
            window.acceptsMouseMovedEvents = true
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

    /// Controls the keyboard-shortcuts reference overlay (toggled by `?`).
    @State private var showShortcutsOverlay: Bool = false

    /// First-run gesture coachmark — shown once, gated on UserDefaults.
    @State private var showCoachmark: Bool = false

    /// True while the Go-to-page popover (on the "N / M" count) is open.
    /// ReaderToolbar binds to this so TransportCapsule can raise/lower the
    /// flag.  The .onChange below stops KeyMonitor while the field is active
    /// (MED-2: a SwiftUI popover is a separate NSWindow — firstResponder
    /// checks are unreliable; explicit stop/start is the robust route).
    @State private var goToPageOpen: Bool = false

    /// Auto-hide state: true = chrome (top bar + bottom scrubber) is visible.
    /// Starts visible; idle timer hides after ~4 s unless a suppressor is active.
    @State private var chromeVisible: Bool = true
    /// Handle to the in-flight idle-hide task. Cancelled + replaced on every reveal().
    @State private var idleHideTask: Task<Void, Never>? = nil
    /// Local NSEvent monitor for .mouseMoved (installed on appear, removed on disappear).
    @State private var mouseMovedMonitor: Any? = nil
    /// True while the pointer is hovering over the top bar or bottom scrubber.
    /// Suppresses auto-hide while hovered; restarts the idle timer on hover-exit.
    @State private var chromeHovered: Bool = false
    /// Reduce-motion environment flag — read from the SwiftUI environment.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(comic: Comic) {
        _vm = StateObject(wrappedValue: ReaderViewModel(comic: comic))
    }

    // MARK: - Body layers
    // `body` composes these (bottom→top in the ZStack). Extracted from `body`
    // so the view tree type-checks quickly and each layer reads on its own —
    // pure structure, no behavior change (all state stays on `self`).

    /// Full-bleed Metal page content + the loupe magnifier overlay, inside a
    /// GeometryReader that feeds the container size to the view model. The
    /// NSScrollView stretches the full window height (no SwiftUI top padding) so
    /// the macOS 26 (Tahoe) scroll-into-header bug can't fire; the immersive
    /// black shows through the carved contentInset bands when the chrome hides.
    private var pageContentLayer: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
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
            .onChange(of: geo.size) { _, newSize in vm.containerSize = newSize }
            .onAppear { vm.containerSize = geo.size }
        }
    }

    /// Top scrim — darkens under the capsule strip so glass capsules are
    /// self-bounding over bright art (Books/TV pattern); invisible over the
    /// black letterbox. Fades with the chrome.
    private var topScrim: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: ReaderConstants.topBarHeight + 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .opacity(chromeVisible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chromeVisible)
    }

    /// Bottom scrim — darkens under the floating scrubber. Fades with the chrome.
    private var bottomScrim: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: ReaderConstants.scrubberStripHeight
                    + ReaderConstants.scrubberBottomPadding + 40)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .opacity(chromeVisible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chromeVisible)
    }

    /// Top bar (the capsule strip) + its hairline seam. Fades + disables hit
    /// testing with the chrome; hovering keeps the chrome up, leaving restarts
    /// the idle-hide timer.
    private var topBarOverlay: some View {
        readerTopBar
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chromeVisible)
            .onHover { hovering in
                chromeHovered = hovering
                if !hovering { reveal() }
            }
    }

    /// Floating bottom scrubber — sits above the window sill, clearing the
    /// resize hot zone + full-screen safe area. Same fade/hover behavior as the
    /// top bar.
    private var bottomScrubberOverlay: some View {
        VStack {
            Spacer()
            PageScrubber(vm: vm)
                .padding(.horizontal, 24)
                .padding(.bottom, ReaderConstants.scrubberBottomPadding)
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chromeVisible)
        .onHover { hovering in
            chromeHovered = hovering
            if !hovering { reveal() }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Bottom → top: page + loupe, the two chrome scrims, the top bar,
            // the floating scrubber, then the always-on progress hairline (kept
            // OUTSIDE the chrome opacity group so it persists when chrome hides —
            // the only position cue in full-bleed mode). Each layer is a computed
            // property above.
            pageContentLayer
            topScrim
            bottomScrim
            topBarOverlay
            bottomScrubberOverlay
            progressHairline
        }
        .toolbar(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .background(FullSizeTitleBarConfigurator())
        .navigationTitle(vm.comic.title)
        // Expose the reader VM to app-level menu commands via FocusedValues.
        // Without this, DCApp.commands can't reach the private @StateObject.
        .focusedSceneValue(\.readerVM, vm)
        // Keyboard-shortcuts overlay — shown when user presses `?`
        .overlay {
            if showShortcutsOverlay {
                ReaderShortcutsOverlay(isPresented: $showShortcutsOverlay)
            }
        }
        .overlay {
            if showCoachmark && !showShortcutsOverlay {
                ReaderCoachmark(isPresented: $showCoachmark)
            }
        }
        .onAppear {
            KeyMonitor.shared.start(handler: handleKey)
            reveal()
            mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [self] event in
                guard metalLoupe == nil else { return event }
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return event }
                let y = event.locationInWindow.y
                if isInEdgeRevealZone(y: y, windowHeight: window.frame.height, edgeZone: 72) {
                    reveal()
                }
                return event
            }
            if !UserDefaults.hasSeenReaderCoachmark {
                showCoachmark = true
            }
            Task { await DCLogger.shared.log("ReaderView.onAppear — readingMode=\(vm.readingMode), currentPage=\(vm.currentPage), savedScrollOffset=\(String(describing: vm.savedScrollOffset))") }
        }
        .onDisappear {
            if library.openComic == nil { KeyMonitor.shared.stop() }
            if let m = mouseMovedMonitor { NSEvent.removeMonitor(m); mouseMovedMonitor = nil }
            idleHideTask?.cancel()
        }
        // MED-2: pause the KeyMonitor while the Go-to-page popover is open.
        // A SwiftUI .popover renders in a child NSWindow, making firstResponder
        // checks unreliable.  Explicit stop/start is the authoritative guard
        // that prevents digits 1–4 from switching reading mode while the
        // numeric text field has focus.  KeyMonitor.start() is guarded by
        // `monitor == nil`, so re-arming after close is always clean.
        .onChange(of: goToPageOpen) { _, open in
            if open {
                KeyMonitor.shared.stop()
            } else {
                KeyMonitor.shared.start(handler: handleKey)
            }
        }
    }

    /// Height of the reader top bar. Used to inset `modeContent`'s top edge
    /// so the page doesn't render behind the bar. Must match the bar's
    /// intrinsic height — currently sourced from `ReaderConstants.topBarHeight`.
    private var readerTopBarHeight: CGFloat { ReaderConstants.topBarHeight }

    private func handleKey(_ key: MonitoredKey) {
        reveal()
        if showCoachmark {
            showCoachmark = false
            UserDefaults.standard.set(true, forKey: "hasSeenReaderCoachmark")
            return
        }
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
        case .keyR:               vm.toggleReadingDirection()
        case .keyQuestion:        showShortcutsOverlay.toggle()
        }
    }

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /// Show chrome and (re)start the 4-second idle-hide timer.
    /// Called by key presses, edge mouse-move, and on appear.
    /// Suppressed while a popover is open, VoiceOver is active, or
    /// `shouldAutoHide` returns false for other reasons.
    private func reveal() {
        chromeVisible = true
        idleHideTask?.cancel()
        idleHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
            // `chromeHovered` is read here (not captured at Task creation) so
            // the check reflects the state AT fire-time, not when reveal() ran.
            if shouldAutoHide(
                chromeVisible: chromeVisible,
                popoverOpen: goToPageOpen,
                hovering: chromeHovered,
                voiceOver: voiceOver
            ) {
                chromeVisible = false
            }
        }
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
            // When chrome is hidden AND the user is at fit-to-window scale,
            // reclaim the reserved bands so the page fills the full window
            // (edge-to-edge). Keep the inset when zoomed (scale > 1.01) to
            // prevent the scroll-into-header / overflow-above-clip bleed bug.
            topContentInset: (chromeVisible || vm.scale > 1.01) ? readerTopBarHeight : 0,
            chromeVisible: chromeVisible,
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
            // Same edge-to-edge logic as single-page: reclaim inset on
            // chrome-hide at fit-to-window scale; keep inset when zoomed.
            topContentInset: (chromeVisible || vm.scale > 1.01) ? readerTopBarHeight : 0,
            chromeVisible: chromeVisible,
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
                // Vertical modes now also reclaim the top inset on chrome-hide
                // so the page fills edge-to-edge (matching single/double behaviour).
                // Scroll compensation in MetalPageView.updateNSView adjusts the
                // content offset to prevent a visible jump when the inset changes.
                topContentInset: chromeVisible ? readerTopBarHeight : 0,
                chromeVisible: chromeVisible,
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
                      onToggleFullScreen: toggleFullscreen,
                      goToPageOpen: $goToPageOpen)
    }

    /// Always-on 1.5pt progress hairline — stays visible when chrome is hidden
    /// so the user always has a position cue in full-bleed mode.
    @ViewBuilder
    private var progressHairline: some View {
        GeometryReader { geo in
            let frac = scrubberFraction(
                forPage: vm.currentPage,
                pageCount: vm.pageCount,
                isRTL: vm.isRTL
            )
            ZStack(alignment: .bottomLeading) {
                // Faint track — visible over both black and bright art
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .frame(height: 1.5)
                // Filled portion
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 0)
                    .frame(width: max(frac * geo.size.width, 0), height: 1.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}


// MARK: - Global key monitor (singleton)

enum MonitoredKey { case leftArrow, rightArrow, upArrow, downArrow, keyA, keyD, keyW, keyS, keyQ, keyE, backspace, key1, key2, key3, key4, keyZ, keyR, keyQuestion }

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
            case (6,  _, true):  handler(.keyZ);        return nil  // Z
            case (15, _, true):  handler(.keyR);        return nil  // R
            case (44, _, true):  handler(.keyQuestion); return nil  // ? (slash key)
            default:             return event
            }
        }
    }

    func stop() {
        handler = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
