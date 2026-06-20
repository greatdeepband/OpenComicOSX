import SwiftUI
import AppKit
import CoreVideo

// Loupe behavior for the MetalPageView Coordinator. Owns the NSEvent
// monitor lifecycle, cursor visibility balance, and the SwiftUI overlay
// state computation. The actual loupe view (MagnifierView) is rendered
// by ReaderView; this extension only emits state via `onLoupeOverlay`.

extension MetalPageView.Coordinator {

    /// Installs a window-local left-mouse monitor. Unlike an overlay
    /// view, the monitor doesn't consume events — scroll/pinch still work.
    /// Left-click-and-hold activates the loupe.
    func installLoupeMonitor() {
        guard loupeEventMonitor == nil else { return }
        loupeEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleLoupeEvent(event)
            return event
        }
    }

    func handleLoupeEvent(_ event: NSEvent) {
        guard let scrollView = scrollView,
              let window = scrollView.window,
              event.window === window else { return }

        // The navbar sits OVER the scrollView (NSScrollView spans the full
        // window with a `topContentInset` reserving the strip), so cursor
        // coords still resolve inside scrollView.bounds when the user is
        // interacting with the toolbar. We only block the INITIAL
        // `.leftMouseDown` that originates in the strip — once a drag has
        // started below the strip (`loupeDragActive == true`), subsequent
        // `.leftMouseDragged` events keep firing regardless of where the
        // cursor wanders, so the loupe behaves symmetrically on all four
        // edges (left / right / bottom / top — fade-to-black at the page
        // edge in every direction).
        //
        // The navbar sits OVER the scrollView in window-coordinate space.
        // `event.locationInWindow` uses BOTTOM-LEFT origin (proven by
        // `updateLoupe` at :240-243 which maps y via `windowHeight - windowPt.y`).
        // The top toolbar band therefore has the LARGEST y values.
        // We use `isInTopBarBand` (window coords) — NOT a scroll-view-local
        // test — so the guard is geometrically correct regardless of
        // NSScrollView's flipped coordinate system.
        let svLocal = scrollView.convert(event.locationInWindow, from: nil)

        // Vertical-stack layouts retain the original immediate-loupe behaviour.
        // Paged layouts (singlePage / doubleSpread) use the hold-for-loupe /
        // tap-to-turn state machine below.
        switch layout {
        case .verticalStack:
            handleLoupeEventVertical(
                event, window: window, scrollView: scrollView,
                svLocal: svLocal
            )
        case .singlePage, .doubleSpread:
            handleLoupeEventPaged(
                event, window: window, scrollView: scrollView,
                svLocal: svLocal
            )
        }
    }

    // MARK: - Vertical-stack loupe (unchanged behaviour)

    private func handleLoupeEventVertical(
        _ event: NSEvent,
        window: NSWindow,
        scrollView: NSScrollView,
        svLocal: CGPoint
    ) {
        switch event.type {
        case .leftMouseDown:
            // Window-frame resize hot zone guard. AppKit reserves a thin
            // margin around the window frame for cursor-driven resize
            // tracking. Because the reader uses `.fullSizeContentView`,
            // the NSScrollView spans the full frame and these resize
            // hot zones sit OVER scrollView.bounds. Without this guard
            // the loupe monitor swallows the .leftMouseDown that AppKit
            // needs to start its resize session — the cursor gets
            // hidden, the loupe overlay flashes, and the resize drag
            // glitches.
            let p = event.locationInWindow
            let f = window.frame
            let m = ReaderConstants.windowResizeMargin
            let inEdge =
                p.x < m ||
                p.x > f.width  - m ||
                p.y < m ||
                p.y > f.height - m
            // Corner hot zones are bigger than straight-edge hot zones —
            // the diagonal-resize cursor activates in a ~14pt square at
            // each corner. Without this, a click in the bottom-left or
            // bottom-right corner would fire the loupe instead of starting
            // a window resize.
            let c = ReaderConstants.windowResizeCornerMargin
            let inXCorner = p.x < c || p.x > f.width  - c
            let inYCorner = p.y < c || p.y > f.height - c
            let inCorner  = inXCorner && inYCorner
            if inEdge || inCorner { return }
            // Top-bar exemption: window coords are bottom-left origin →
            // the toolbar band occupies the LARGEST y values.
            if isInTopBarBand(locationInWindowY: p.y,
                              windowHeight: f.height,
                              topBarHeight: ReaderConstants.topBarHeight) { return }
            loupeDragActive = true
            updateLoupe(at: event.locationInWindow, in: window)
        case .leftMouseDragged:
            guard loupeDragActive else { return }
            updateLoupe(at: event.locationInWindow, in: window)
        case .leftMouseUp:
            if loupeDragActive {
                loupeDragActive = false
                showCursorIfNeeded()
                hideLoupe()
            }
        default:
            break
        }
    }

    // MARK: - Paged loupe (hold-for-loupe / tap-to-turn)

    private func handleLoupeEventPaged(
        _ event: NSEvent,
        window: NSWindow,
        scrollView: NSScrollView,
        svLocal: CGPoint
    ) {
        switch event.type {
        case .leftMouseDown:
            // A fresh down disarms tap-turn until this down is ACCEPTED below.
            // An exempted down (navbar band / resize edge) returns early and
            // leaves this false, so the matching .leftMouseUp can't fire a
            // page-turn from the previous accepted down's coordinates.
            loupeGestureArmed = false
            // Window-frame resize hot zone guard (verbatim from vertical path).
            let p = event.locationInWindow
            let f = window.frame
            let m = ReaderConstants.windowResizeMargin
            let inEdge =
                p.x < m ||
                p.x > f.width  - m ||
                p.y < m ||
                p.y > f.height - m
            let c = ReaderConstants.windowResizeCornerMargin
            let inXCorner = p.x < c || p.x > f.width  - c
            let inYCorner = p.y < c || p.y > f.height - c
            let inCorner  = inXCorner && inYCorner
            if inEdge || inCorner {
                pendingLoupeTimer?.cancel(); pendingLoupeTimer = nil
                return
            }
            // Top-bar exemption: window coords are bottom-left origin →
            // the toolbar band occupies the LARGEST y values. Cancel any
            // stale timer so a later .leftMouseUp can't fire a page-turn.
            if isInTopBarBand(locationInWindowY: p.y,
                              windowHeight: f.height,
                              topBarHeight: ReaderConstants.topBarHeight) {
                pendingLoupeTimer?.cancel(); pendingLoupeTimer = nil
                return
            }
            guard event.clickCount == 1 else { return }

            // Capture window point and scroll-view-local position; do NOT
            // activate the loupe or hide the cursor yet.
            let downWindowPt = event.locationInWindow
            let win = window
            pendingLoupeDownLocation = svLocal
            pendingLoupeDownTime = CACurrentMediaTime()
            loupeGestureArmed = true   // down accepted → tap-turn may fire on up

            pendingLoupeTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(LoupeHoldThreshold))
                guard let self, self.pendingLoupeTimer != nil else { return }
                self.loupeDragActive = true
                self.updateLoupe(at: downWindowPt, in: win)   // escalation hides the cursor
                self.pendingLoupeTimer = nil
            }

        case .leftMouseDragged:
            if pendingLoupeTimer != nil {
                // Gesture still pending — check if the finger moved too far.
                let dx = svLocal.x - pendingLoupeDownLocation.x
                let dy = svLocal.y - pendingLoupeDownLocation.y
                let movement = (dx * dx + dy * dy).squareRoot()
                if movement > LoupeMoveTolerance {
                    pendingLoupeTimer?.cancel()
                    pendingLoupeTimer = nil
                    loupeDragActive = true
                    updateLoupe(at: event.locationInWindow, in: window)
                }
            } else if loupeDragActive {
                updateLoupe(at: event.locationInWindow, in: window)
            }
            // else: no pending timer and no active loupe — ignore (drag after
            // a pass-through down event such as resize or top-strip).

        case .leftMouseUp:
            pendingLoupeTimer?.cancel()
            pendingLoupeTimer = nil

            if loupeDragActive {
                // End active loupe session.
                loupeDragActive = false
                showCursorIfNeeded()
                hideLoupe()
            } else {
                // Quick tap — cursor was never hidden; restore unconditionally
                // (no-ops if the cursor is already visible).
                guard event.clickCount == 1 else { showCursorIfNeeded(); return }
                // Only turn the page if THIS gesture's down was accepted (not a
                // navbar / scrubber / resize click). Without this, an exempted
                // down still reached here and turned the page using a stale
                // down-x — the "clicking the navbar turns pages" bug.
                guard loupeGestureArmed else { showCursorIfNeeded(); return }
                loupeGestureArmed = false
                // Turn the page using the stored down-x for direction.
                switch tapTurnDirection(
                    downX: pendingLoupeDownLocation.x,
                    viewportWidth: scrollView.frame.width
                ) {
                case .previous: onPageNavSwipe?(-1)
                case .next:     onPageNavSwipe?(+1)
                }
            }

        default:
            break
        }
    }

    func hideCursorIfNeeded() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    func showCursorIfNeeded() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    /// Resolves the page under the cursor, fetches its NSImage, and emits
    /// a `LoupeOverlayState` to the SwiftUI overlay via `onLoupeOverlay`.
    /// The loupe is a SwiftUI view inside the reader's container — no
    /// NSPanel or child window —
    /// `.clipped()` on the container naturally clips the loupe circle to
    /// the reader frame, producing the progressive edge-clipping the user
    /// asked for without any manual window-bezel arithmetic.
    func updateLoupe(at windowPt: CGPoint, in window: NSWindow) {
        guard let scrollView = scrollView,
              let documentView = scrollView.documentView else { return }

        loupeTaskID &+= 1
        loupeTask?.cancel()

        let docPt = documentView.convert(windowPt, from: nil)

        // Convert windowPt (AppKit bottom-left in window coords) to
        // SwiftUI top-left within the ZStack that fills the window. The
        // reader uses fullSizeContentView + hiddenTitleBar, so the
        // window's content area spans the full frame height.
        let windowHeight = window.frame.height
        let overlayPosition = CGPoint(
            x: windowPt.x,
            y: windowHeight - windowPt.y
        )

        guard !pages.isEmpty else {
            emitLoupe(nil)
            return
        }

        // Resolve the page under the cursor. When the cursor sits in a
        // row/column gap or past the document edges, stick to the last
        // active page (or the first visible page if there isn't one yet)
        // so the loupe stays on screen for the entire drag — the
        // pre-Metal single/double-page UX where the loupe was always
        // visible while the mouse was held, with content fading to
        // black at the image edges via MagnifierView's intersection
        // clip. The loupe panel still tracks the real cursor; only its
        // magnified content is anchored to a real page.
        let rawSeqIdx = findSequentialIndex(at: docPt)
        let seqIdx: Int
        if rawSeqIdx >= 0, rawSeqIdx < pages.count {
            seqIdx = rawSeqIdx
        } else if let active = loupeActivePage,
                  active >= 0, active < pages.count {
            seqIdx = active
        } else {
            let initial: Int
            switch layout {
            case .singlePage, .doubleSpread:
                initial = currentPage
            case .verticalStack:
                initial = lastVisibleRange.lowerBound
            }
            seqIdx = max(0, min(initial, pages.count - 1))
        }
        loupeActivePage = seqIdx

        let pageID = sequentialToID[seqIdx]
        guard let pageRect = pagePositions[pageID] else {
            emitLoupe(nil)
            return
        }
        let cursorInImage = CGPoint(
            x: docPt.x - pageRect.minX,
            y: docPt.y - pageRect.minY
        )
        let imageViewSize = pageRect.size

        hideCursorIfNeeded()

        // Fast path: image is already in the loupe's local cache or in
        // the page manager's nonisolated NSCache.
        if let cached = loupeImage, cached.page == seqIdx {
            emitLoupe(LoupeOverlayState(
                position: overlayPosition,
                image: cached.nsImage,
                imageViewSize: imageViewSize,
                cursorInImage: cursorInImage
            ))
            return
        }

        if let img = pageManager?.nsImage(for: seqIdx) {
            loupeImage = (seqIdx, img)
            emitLoupe(LoupeOverlayState(
                position: overlayPosition,
                image: img,
                imageViewSize: imageViewSize,
                cursorInImage: cursorInImage
            ))
            return
        }

        // Target page's NSImage isn't decoded yet. Emit a FALLBACK state
        // using the last cached image so the loupe position keeps tracking
        // the cursor (otherwise the loupe freezes mid-drag — exactly the
        // "stops in the middle when crossing the gutter" symptom in
        // double-page mode). Map cursor to the cached page's rect if it's
        // still laid out; otherwise use the target rect (content will
        // briefly look stale but POSITION updates smoothly).
        if let cached = loupeImage {
            let staleSize: CGSize
            let staleCursor: CGPoint
            if cached.page >= 0, cached.page < pages.count,
               let cachedRect = pagePositions[pages[cached.page].id] {
                staleSize = cachedRect.size
                staleCursor = CGPoint(
                    x: docPt.x - cachedRect.minX,
                    y: docPt.y - cachedRect.minY
                )
            } else {
                staleSize = imageViewSize
                staleCursor = cursorInImage
            }
            emitLoupe(LoupeOverlayState(
                position: overlayPosition,
                image: cached.nsImage,
                imageViewSize: staleSize,
                cursorInImage: staleCursor
            ))
        }

        guard let pageManager = pageManager else { return }
        let pageSource = pages[seqIdx].source
        let myID = loupeTaskID
        loupeTask = Task { [weak self] in
            var buffer = await pageManager.page(for: seqIdx)
            if buffer == nil {
                buffer = await pageManager.decodePage(pageIndex: seqIdx, from: pageSource)
            }
            guard !Task.isCancelled,
                  let b = buffer,
                  let nsImage = MetalPageView.Coordinator.nsImage(from: b) else { return }
            await MainActor.run {
                guard let self = self, self.loupeTaskID == myID else { return }
                self.loupeImage = (seqIdx, nsImage)
                self.emitLoupe(LoupeOverlayState(
                    position: overlayPosition,
                    image: nsImage,
                    imageViewSize: imageViewSize,
                    cursorInImage: cursorInImage
                ))
            }
        }
    }

    func emitLoupe(_ state: LoupeOverlayState?) {
        if state == nil { showCursorIfNeeded() }
        onLoupeOverlay?(state)
    }

    func hideLoupe() {
        // Invalidate any in-flight fetch so its emit doesn't run
        // after the user has released the mouse.
        loupeTaskID &+= 1
        loupeTask?.cancel()
        loupeTask = nil
        loupeImage = nil
        loupeActivePage = nil
        onLoupeOverlay?(nil)
        showCursorIfNeeded()
    }

    /// Converts a 32BGRA CVPixelBuffer into an NSImage by snapshotting
    /// pixel memory into a CGImage. Called off the main actor; the result
    /// is Sendable (NSImage + CGImage are value-semantic enough here).
    nonisolated static func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        return makeNSImageFromPixelBuffer(pixelBuffer)
    }
}
