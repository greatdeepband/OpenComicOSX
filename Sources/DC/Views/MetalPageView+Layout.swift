import SwiftUI
import AppKit

// Layout, scroll, visible-range, and rebuild methods for the
// MetalPageView Coordinator. Owns the documentView geometry math
// (rebuildVerticalStack / rebuildSinglePage / rebuildDoubleSpread),
// the centring math (recenterIfContentFits), and the visible-range
// computation that drives prefetch + render scheduling.

extension MetalPageView.Coordinator {

    /// Called from `MetalCanvasView.layout()` after AppKit commits the
    /// frame change. If a render was armed but couldn't paint earlier
    /// (drawableSize = 0 because clipView hadn't sized yet), retry here.
    func handleLayoutCompleted() {
        tryInitialRender()
    }

    /// Body of the `clipViewGeometryChanged` notification handler. The
    /// `@objc` selector itself lives on the Coordinator class declaration
    /// in MetalPageView.swift so NotificationCenter.addObserver(_,
    /// selector:) can resolve it via the ObjC runtime — `@objc` extension
    /// methods on `final class : NSObject` aren't reliably exposed there.
    func clipViewGeometryChangedImpl() {
        // Keep the metalLayer aligned to the new clip geometry regardless
        // — this also matters for unzoomed scroll events on vertical
        // modes where magnification can resize the clipView.bounds.
        metalView?.updateMetalLayerFrame()
        // While the initial render is still pending, re-fit single/double-
        // page layouts to the now-known clip height. The first rebuild may
        // have used the containerWidth fallback because the clipView
        // wasn't sized yet; once it is, re-rebuild produces the correct
        // documentView frame and drawableSize so the render can succeed.
        if pendingInitialRender {
            switch layout {
            case .singlePage, .doubleSpread:
                rebuildLayout()
                metalView?.updateMetalLayerFrame()
            case .verticalStack:
                break
            }
        }
        tryInitialRender()
    }

    /// Consumes `pendingInitialRender` if the drawable is now ready.
    /// Safe to call from any layout hook — no-op if the render has
    /// already been delivered for this rebuild cycle. If the drawable
    /// still isn't ready, retries on a back-off timer so we don't get
    /// stranded waiting for a notification that may never fire (e.g.
    /// when the scroll view's clipView happens to be sized correctly
    /// from the moment the view is attached, so no boundsDidChange
    /// notification follows).
    func tryInitialRender(retryAttempt: Int = 0) {
        guard pendingInitialRender else { return }
        guard let metalView = metalView else { return }
        // Ensure drawable geometry is current before sampling size.
        metalView.updateMetalLayerFrame()
        let drawable = metalView.metalLayer?.drawableSize ?? .zero
        if drawable.width > 1, drawable.height > 1 {
            pendingInitialRender = false
            updateVisibleRange()
            return
        }
        // Drawable not yet ready. Retry on a back-off timer up to
        // `ReaderConstants.initialRenderMaxRetries` times. After that we
        // give up — first user scroll or page turn will trigger
        // updateVisibleRange and recover via the normal path.
        guard retryAttempt < ReaderConstants.initialRenderMaxRetries else {
            pendingInitialRender = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ReaderConstants.initialRenderRetryDelay) { [weak self] in
            self?.tryInitialRender(retryAttempt: retryAttempt + 1)
        }
    }

    func needsRebuild(containerWidth: CGFloat, pagesPerRow: Int, pages: [ComicPage], layout: ReadingLayout, currentPage: Int, scale: CGFloat) -> Bool {
        if abs(lastContainerWidth - containerWidth) > 1 { return true }
        if lastPagesPerRow != pagesPerRow { return true }
        if lastLayout != layout { return true }
        // For non-vertical layouts, a page-turn or scale change requires a
        // layout rebuild because pagePositions / pageYOffsets must reflect
        // the new page / zoomed frame size.
        switch layout {
        case .singlePage, .doubleSpread:
            if lastCurrentPage != currentPage { return true }
            if abs(lastScale - scale) > ReaderConstants.scaleEqualityEpsilon { return true }
        case .verticalStack:
            break
        }
        return false
    }

    func rebuildLayout() {
        Task { await DCLogger.shared.log("SWITCH: rebuildLayout entry layout=\(layout) pages.count=\(pages.count) currentPage=\(currentPage)") }
        guard let metalView = metalView else {
            Task { await DCLogger.shared.log("SWITCH: rebuildLayout NIL metalView - bailing") }
            return
        }

        // Arm the post-layout render retry. MetalCanvasView.layout() will
        // fire onLayoutCompleted after AppKit commits the frame change;
        // that's the earliest moment the drawable is guaranteed to have
        // a non-zero size, so we can safely issue the first render then.
        pendingInitialRender = true

        pagePositions.removeAll()
        pageYOffsets.removeAll()

        sequentialToID = pages.map { $0.id }
        idToSequential.removeAll()
        for (seqIdx, pageID) in sequentialToID.enumerated() {
            idToSequential[pageID] = seqIdx
        }

        switch layout {
        case .verticalStack:
            rebuildVerticalStack()
        case .singlePage:
            rebuildSinglePage()
        case .doubleSpread:
            rebuildDoubleSpread()
        }

        lastContainerWidth = containerWidth
        lastPagesPerRow = pagesPerRow

        metalView.needsDisplay = true
    }

    /// Stacks every page top-to-bottom at `containerWidth * scale` (for
    /// `pagesPerRow == 1`) or split side-by-side honoring `.isSpread`
    /// (for `pagesPerRow == 2`).
    func rebuildVerticalStack() {
        guard let metalView = metalView else { return }
        let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth
        var y: CGFloat = 0

        let gap = ReaderConstants.verticalPageGap
        let gutter = ReaderConstants.doublePageGutter
        if pagesPerRow == 1 {
            for i in 0..<pages.count {
                let page = pages[i]
                let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                let h = totalWidth * ar
                let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                pagePositions[page.id] = rect
                pageYOffsets.append(y)
                y += h + gap
            }
        } else {
            var i = 0
            while i < pages.count {
                let page = pages[i]

                if page.isSpread {
                    let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                    let h = totalWidth * ar
                    let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                    pagePositions[page.id] = rect
                    pageYOffsets.append(y)
                    y += h + gap
                    i += 1
                } else {
                    let pageWidth = (totalWidth - gutter) / 2
                    let leftAR = page.naturalSize.height / max(page.naturalSize.width, 1)
                    let leftH = pageWidth * leftAR
                    let leftRect = CGRect(x: 0, y: y, width: pageWidth, height: leftH)
                    pagePositions[page.id] = leftRect
                    pageYOffsets.append(y)

                    var rightH: CGFloat = leftH
                    if i + 1 < pages.count && !pages[i + 1].isSpread {
                        let rightPage = pages[i + 1]
                        let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                        rightH = pageWidth * rightAR
                        let rightRect = CGRect(x: pageWidth + gutter, y: y, width: pageWidth, height: rightH)
                        pagePositions[rightPage.id] = rightRect
                        pageYOffsets.append(y)
                        i += 2
                    } else {
                        i += 1
                    }

                    y += max(leftH, rightH) + gap
                }
            }
        }

        let totalHeight = y
        metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
    }

    /// One page, sized to fit the viewport at `scale = 1.0` (both
    /// dimensions — equivalent to SwiftUI `.scaledToFit()`). Zoom is
    /// achieved by scaling the documentView frame so NSScrollView treats
    /// the zoomed size as the real document size — this avoids
    /// CAMetalLayer compositing issues that `magnification` introduces
    /// on macOS.
    func rebuildSinglePage() {
        guard let metalView = metalView else { return }
        guard currentPage >= 0 && currentPage < pages.count else {
            metalView.frame = CGRect(x: 0, y: 0, width: max(1, containerWidth), height: 1)
            return
        }
        let page = pages[currentPage]
        let pageAR = page.naturalSize.height / max(page.naturalSize.width, 1)

        // Fit-to-window base size: the page fits entirely inside the
        // usable viewport (width × height-below-top-bar) at scale=1.0.
        // Pick the more restrictive of "fit-by-width" and "fit-by-height".
        //
        // First-rebuild trap: on a fresh mode switch, the scroll view's
        // clipView may not have laid out yet, so its bounds height is 0.
        // Without a guard, viewportH would collapse to 1, fitBaseWidth
        // would go near-zero, and the documentView would be sized to a
        // ~1pt placeholder. The drawable then clamps to (1,1), the render
        // never succeeds, and the page stays black until the user turns a
        // page (which forces a re-rebuild with a properly-sized clipView).
        // Fall back to containerWidth as a sensible viewport-height proxy
        // until the clipView actually reports its true size; the
        // clipViewGeometryChanged observer re-rebuilds once it does.
        let topInset = scrollView?.contentInsets.top ?? 0
        let actualClipH = scrollView?.contentView.bounds.size.height ?? 0
        let clipH = actualClipH > 1 ? actualClipH : containerWidth
        let viewportH = max(1, clipH - topInset)
        let fitWidthFromW = containerWidth
        let fitWidthFromH = viewportH / max(pageAR, ReaderConstants.aspectRatioFloor)
        let fitBaseWidth = max(1, min(fitWidthFromW, fitWidthFromH))

        let scaledWidth = fitBaseWidth * scale
        let scaledHeight = scaledWidth * pageAR

        // Pad the documentView to at least the usable viewport so the
        // page sits centred inside a doc that's never narrower than the
        // clipView. NSClipView's constrainBoundsRect clamps negative
        // bounds origins back to 0 when the doc is smaller than the
        // clip — so a tightly-sized doc would always anchor flush-left
        // when the user switches into single-page from a wider mode
        // (double-page). Sizing the doc up and centring the page rect
        // inside it sidesteps the clamp entirely.
        let docW = max(scaledWidth, containerWidth)
        let docH = max(scaledHeight, viewportH)
        let pageRect = CGRect(
            x: (docW - scaledWidth) / 2,
            y: (docH - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        pagePositions[page.id] = pageRect
        pageYOffsets.append(0)

        metalView.frame = CGRect(x: 0, y: 0, width: docW, height: docH)
    }

    /// One or two pages side-by-side for a double-page spread. If the
    /// current page is a natural spread (`.isSpread`), it fills the
    /// document full-width and there is no right page. Otherwise the
    /// current page occupies the left slot and `currentPage + 1` (if
    /// it exists and isn't itself a spread) occupies the right slot.
    /// Zoom via frame-resize (no magnification transform).
    func rebuildDoubleSpread() {
        guard let metalView = metalView else { return }
        guard currentPage >= 0 && currentPage < pages.count else {
            metalView.frame = CGRect(x: 0, y: 0, width: max(1, containerWidth), height: 1)
            return
        }

        let leftPage = pages[currentPage]
        let rightIdx = currentPage + 1
        let rightPage: ComicPage? = (rightIdx < pages.count && !pages[rightIdx].isSpread)
            ? pages[rightIdx] : nil

        // Fit-to-window base size — same methodology as rebuildSinglePage.
        // Same clipH-fallback trap applies: fall back to containerWidth
        // when the clipView hasn't sized yet.
        let topInset = scrollView?.contentInsets.top ?? 0
        let actualClipH = scrollView?.contentView.bounds.size.height ?? 0
        let clipH = actualClipH > 1 ? actualClipH : containerWidth
        let viewportH = max(1, clipH - topInset)

        let spreadAR: CGFloat
        if leftPage.isSpread {
            spreadAR = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
        } else {
            let leftAR = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
            let rightAR = rightPage.map { $0.naturalSize.height / max($0.naturalSize.width, 1) } ?? leftAR
            // spread-AR = max(leftAR, rightAR) / 2 — the taller page over
            // a spread that's twice as wide as one page.
            spreadAR = max(leftAR, rightAR) / 2
        }

        let fitBaseWidth = max(1, min(containerWidth, viewportH / max(spreadAR, ReaderConstants.aspectRatioFloor)))
        let totalWidth = fitBaseWidth * scale

        // Doc-padding: same rationale as rebuildSinglePage — pad the
        // documentView to ≥ usable viewport so the spread is centred via
        // intrinsic doc layout (NSClipView won't clamp negative bounds
        // origins back to 0).
        if leftPage.isSpread {
            let h = totalWidth * spreadAR
            let docW = max(totalWidth, containerWidth)
            let docH = max(h, viewportH)
            let xOff = (docW - totalWidth) / 2
            let yOff = (docH - h) / 2
            let rect = CGRect(x: xOff, y: yOff, width: totalWidth, height: h)
            pagePositions[leftPage.id] = rect
            pageYOffsets.append(0)
            metalView.frame = CGRect(x: 0, y: 0, width: docW, height: docH)
            return
        }

        let gutter = ReaderConstants.doublePageGutter
        let pageWidth = (totalWidth - gutter) / 2
        let leftAR = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
        let leftH = pageWidth * leftAR

        var rightH: CGFloat = leftH
        if let rp = rightPage {
            let rightAR = rp.naturalSize.height / max(rp.naturalSize.width, 1)
            rightH = pageWidth * rightAR
        }

        let spreadHeight = max(leftH, rightH)
        let docW = max(totalWidth, containerWidth)
        let docH = max(spreadHeight, viewportH)
        let xOff = (docW - totalWidth) / 2
        let yOff = (docH - spreadHeight) / 2

        let leftRect = CGRect(x: xOff, y: yOff, width: pageWidth, height: leftH)
        pagePositions[leftPage.id] = leftRect
        pageYOffsets.append(0)

        if let rp = rightPage {
            let rightRect = CGRect(x: xOff + pageWidth + gutter, y: yOff, width: pageWidth, height: rightH)
            pagePositions[rp.id] = rightRect
            pageYOffsets.append(0)
        }

        metalView.frame = CGRect(x: 0, y: 0, width: docW, height: docH)
    }

    func scrollToPage(_ page: Int) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        guard page >= 0 && page < pageYOffsets.count else { return }
        let targetY = pageYOffsets[page]
        doc.scroll(CGPoint(x: 0, y: targetY))
        sv.reflectScrolledClipView(sv.contentView)
        updateVisibleRange()
    }

    func scrollToFraction(_ fraction: Double) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let maxY = doc.bounds.height - sv.contentView.bounds.height
        guard maxY > 0 else { return }
        let targetY = CGFloat(fraction) * maxY
        doc.scroll(CGPoint(x: 0, y: targetY))
        sv.reflectScrolledClipView(sv.contentView)
        updateVisibleRange()
    }

    func updateVisibleRange() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let docH = doc.bounds.height
        let visH = sv.contentView.bounds.height
        let maxY = docH - visH
        let fraction = maxY > 0 ? Double(sv.contentView.bounds.origin.y / maxY) : 0
        onOffsetChanged(fraction)

        // Single/double-page layouts: the "visible" range is a direct
        // function of currentPage, not of pageYOffsets. The offsets array
        // only has one or two entries, so the binary-search path below
        // would always collapse to 0…0 and the renderer would look up the
        // wrong page.id in pagePositions — that's why only the title page
        // ever rendered after a page turn.
        switch layout {
        case .singlePage:
            guard !pages.isEmpty, currentPage >= 0, currentPage < pages.count else { return }
            let visibleRange = currentPage...currentPage
            onPageChanged(currentPage)
            lastVisibleRange = visibleRange
            triggerPrefetch(first: currentPage, last: currentPage)
            metalView?.updateMetalLayerFrame()
            DispatchQueue.main.async { [weak self] in
                self?.render(visibleRange: visibleRange)
            }
            return
        case .doubleSpread:
            guard !pages.isEmpty, currentPage >= 0, currentPage < pages.count else { return }
            let leftIsSpread = pages[currentPage].isSpread
            let last = leftIsSpread ? currentPage : min(currentPage + 1, pages.count - 1)
            let visibleRange = currentPage...last
            onPageChanged(currentPage)
            lastVisibleRange = visibleRange
            triggerPrefetch(first: currentPage, last: last)
            metalView?.updateMetalLayerFrame()
            DispatchQueue.main.async { [weak self] in
                self?.render(visibleRange: visibleRange)
            }
            return
        case .verticalStack:
            break
        }

        let currentY = sv.contentView.bounds.origin.y
        let bottomY = currentY + visH

        var lo = 0, hi = pageYOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pageYOffsets[mid] <= currentY { lo = mid } else { hi = mid - 1 }
        }
        // Walk left over duplicate Ys (vertical-double: left+right pages
        // share the same Y) so `firstVisible` is the leftmost page of its row.
        var firstVisible = lo
        while firstVisible > 0 && pageYOffsets[firstVisible - 1] == pageYOffsets[firstVisible] {
            firstVisible -= 1
        }

        var lo2 = firstVisible, hi2 = pageYOffsets.count - 1
        while lo2 < hi2 {
            let mid = (lo2 + hi2 + 1) / 2
            if pageYOffsets[mid] < bottomY { lo2 = mid } else { hi2 = mid - 1 }
        }
        // Walk right over duplicate Ys so `lastVisible` is the rightmost
        // page of its row. Without this, the right page of the last visible
        // row would be skipped in double-page mode.
        var lastVisible = lo2
        while lastVisible + 1 < pageYOffsets.count
            && pageYOffsets[lastVisible + 1] == pageYOffsets[lastVisible] {
            lastVisible += 1
        }

        let visibleRange = firstVisible...lastVisible

        Task { await DCLogger.shared.log("SWITCH: updateVisibleRange vertical visibleRange=\(visibleRange) pageYOffsets.count=\(pageYOffsets.count) pages.count=\(pages.count) currentY=\(currentY)") }

        onPageChanged(firstVisible)
        lastVisibleRange = visibleRange
        triggerPrefetch(first: firstVisible, last: lastVisible)

        // Reposition the CAMetalLayer sublayer to cover the visible clipView
        // area before rendering — the sublayer moves with scroll, so the
        // drawable always composites 1:1 against the visible viewport.
        metalView?.updateMetalLayerFrame()

        // Defer the render call by one runloop tick. This ensures the NSScrollView
        // layout pass has fully completed and committed the CAMetalLayer before we
        // call nextDrawable(). Without this defer, Metal can abort with "failed to
        // create drawable texture" because the layer hasn't been presented yet.
        DispatchQueue.main.async { [weak self] in
            self?.render(visibleRange: visibleRange)
        }
    }

    /// Body of the `scrollDidChange` notification handler. See
    /// `clipViewGeometryChangedImpl` for why @objc lives in the class body.
    func scrollDidChangeImpl() {
        Task { await DCLogger.shared.log("SWITCH: scrollDidChange layout=\(layout) currentY=\(scrollView?.contentView.bounds.origin.y ?? -999)") }
        updateVisibleRange()

        // If the loupe is active and the user scrolled without moving the
        // mouse, no leftMouseDragged event fires — so the page under the
        // (fixed-on-screen) cursor has changed but the loupe still shows
        // the old page. Refresh explicitly using the live cursor location.
        guard cursorHidden,
              let scrollView = scrollView,
              let window = scrollView.window else { return }
        let screenPt = NSEvent.mouseLocation
        let windowPt = window.convertPoint(fromScreen: screenPt)
        let svLocal = scrollView.convert(windowPt, from: nil)
        guard scrollView.bounds.contains(svLocal) else { return }
        // Reassert cursor hidden in case anything between events unhid it.
        hideCursorIfNeeded()
        updateLoupe(at: windowPt, in: window)
    }

    /// Body of the `magnificationDidChange` notification handler.
    func magnificationDidChangeImpl() {
        guard let sv = scrollView else { return }
        switch layout {
        case .verticalStack:
            lastScale = sv.magnification
            scale = sv.magnification
            onMagnificationChanged?(sv.magnification)
            recenterIfContentFits()
        case .singlePage, .doubleSpread:
            // We don't use magnification for these layouts; if a
            // notification ever arrives (e.g. magnification forced to 1
            // via range clamping), ignore it.
            break
        }
    }

    /// In single/double-page layouts, re-centre the documentView within
    /// the clipView's USABLE viewport (clip minus the top-bar inset band)
    /// whenever the doc is smaller than that usable area, and clamp
    /// otherwise. Vertical modes are skipped — they allow free scroll.
    func recenterIfContentFits() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        switch layout {
        case .verticalStack: return
        case .singlePage, .doubleSpread: break
        }
        let clip = sv.contentView
        let topInset = sv.contentInsets.top
        let docSize = doc.frame.size
        // Usable viewport: clip minus the non-scrollable top-bar band.
        // clipView.bounds.size itself still counts that band, so compare
        // and centre against the reduced height.
        let usableW = clip.bounds.size.width
        let usableH = max(0, clip.bounds.size.height - topInset)

        var newOrigin = clip.bounds.origin

        // Horizontal
        if docSize.width <= usableW {
            // Content fits — centre it by placing clipView's origin at
            // the negative half-difference so the doc sits in the middle.
            newOrigin.x = (docSize.width - usableW) / 2
        } else {
            newOrigin.x = max(0, min(newOrigin.x, docSize.width - usableW))
        }

        // Vertical — the "top" of the usable viewport in clipY is topInset,
        // so origin.y that places doc-top at clipY=topInset is origin.y =
        // -topInset. When centring, doc-centre should sit at
        // clipY = topInset + usableH/2, meaning
        //   origin.y = docH/2 - (topInset + usableH/2).
        if docSize.height <= usableH {
            newOrigin.y = docSize.height / 2 - (topInset + usableH / 2)
        } else {
            let minY: CGFloat = -topInset
            let maxY = docSize.height - clip.bounds.size.height
            newOrigin.y = min(max(newOrigin.y, minY), maxY)
        }

        if newOrigin != clip.bounds.origin {
            clip.scroll(to: newOrigin)
            sv.reflectScrolledClipView(clip)
        }
    }

    /// Resolves a doc-coord point to a sequential page index. Returns -1
    /// if the point is in margin / not over any laid-out page. Lives here
    /// (not in +Loupe) because it's a query over layout state, even
    /// though the loupe is its only current caller.
    func findSequentialIndex(at docPt: CGPoint) -> Int {
        // Single/double-page layouts only populate `pagePositions` for the
        // 1–2 visible pages, so iterating `pageYOffsets` indices breaks —
        // `sequentialToID[idx]` points at pages[0]/pages[1] in the full
        // comic, which won't be in `pagePositions` once `currentPage > 0`.
        // Hit-test the visible pages directly by their actual page index.
        switch layout {
        case .singlePage:
            guard currentPage >= 0, currentPage < pages.count,
                  let rect = pagePositions[pages[currentPage].id],
                  rect.contains(docPt) else { return -1 }
            return currentPage
        case .doubleSpread:
            if currentPage >= 0, currentPage < pages.count,
               let rect = pagePositions[pages[currentPage].id],
               rect.contains(docPt) {
                return currentPage
            }
            let rightIdx = currentPage + 1
            if rightIdx < pages.count,
               let rect = pagePositions[pages[rightIdx].id],
               rect.contains(docPt) {
                return rightIdx
            }
            return -1
        case .verticalStack:
            break
        }

        // Vertical stack: pageYOffsets is sorted ascending and indexes into
        // sequentialToID 1:1, so the binary search and row walk works.
        guard !pageYOffsets.isEmpty else { return -1 }

        var lo = 0, hi = pageYOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pageYOffsets[mid] <= docPt.y { lo = mid } else { hi = mid - 1 }
        }

        // Vertical-double: left and right pages of a row share the same Y
        // offset. Walk over all pages at this Y and return the one whose
        // horizontal bounds contain docPt.x.
        var idx = lo
        while idx > 0 && pageYOffsets[idx - 1] == pageYOffsets[idx] {
            idx -= 1
        }
        let rowY = pageYOffsets[idx]
        while idx < pageYOffsets.count && pageYOffsets[idx] == rowY {
            let pageID = sequentialToID[idx]
            if let rect = pagePositions[pageID],
               docPt.x >= rect.minX && docPt.x <= rect.maxX,
               docPt.y >= rect.minY && docPt.y <= rect.maxY {
                return idx
            }
            idx += 1
        }
        return -1
    }
}
