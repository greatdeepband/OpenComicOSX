import SwiftUI
import AppKit
import Metal

// Render and prefetch methods for the MetalPageView Coordinator.
// `render` issues a draw against the current visible range; `triggerPrefetch`
// fans page decodes around the visible range and uploads textures into the
// renderer's ring. `onTextureReady` re-renders if a freshly-uploaded page
// is still on screen.

extension MetalPageView.Coordinator {

    func triggerPrefetch(first: Int, last: Int) {
        guard let manager = pageManager, !pages.isEmpty else { return }
        let lookahead = ReaderConstants.prefetchLookahead
        let firstIdx = max(0, first - lookahead)
        let lastIdx = min(pages.count - 1, last + lookahead)

        // Visible pages first, then lookahead fanning outward. This way the
        // actually on-screen pages decode before any prefetch neighbour,
        // and stale lookahead work from a prior scroll can't delay them.
        var order: [Int] = []
        for i in first...last where i >= 0 && i < pages.count { order.append(i) }
        var offset = 1
        while order.count < (lastIdx - firstIdx + 1) {
            let after = last + offset
            let before = first - offset
            if after <= lastIdx { order.append(after) }
            if before >= firstIdx { order.append(before) }
            offset += 1
        }

        // Dedupe: if the in-flight prefetch task is for the same visible
        // range, leave it alone. updateVisibleRange fires repeatedly during
        // initial layout (multiple bounds-change notifications, layout-
        // completed retries) — without this dedupe each call cancels the
        // previous task, killing decode mid-flight, and the texture never
        // lands in the ring. Symptom: page stays black on mode switch.
        let newRange = first...last
        if prefetchInFlightRange == newRange, prefetchTask != nil {
            return
        }

        // Different range (real scroll/page-turn). Cancel old, start new.
        prefetchTask?.cancel()
        prefetchInFlightRange = newRange

        prefetchTask = Task { [weak self] in
            for seqIdx in order {
                if Task.isCancelled { return }

                // Snapshot main-actor state and bail-early under one hop.
                // Reading pages/renderer off-main violates the Coordinator's
                // @MainActor isolation and races with the renderer's own
                // documented "main-actor only" contract (textureRing.touch
                // mutates lastAccess on every texture(for:) call).
                let pageToDecode: ComicPage? = await MainActor.run { [weak self] in
                    guard let self = self,
                          seqIdx < self.pages.count,
                          self.renderer?.texture(for: seqIdx) == nil
                    else { return nil }
                    return self.pages[seqIdx]
                }
                guard let pageToDecode = pageToDecode else { continue }

                // Off-main decode — heavy CPU work, intentionally off the main
                // thread so scrolling stays smooth during prefetch.
                guard let buffer = await manager.decodePage(pageIndex: seqIdx, from: pageToDecode.source) else {
                    continue
                }
                if Task.isCancelled { return }

                // Upload + readiness notification on the main actor. The
                // renderer's textureRing mutation and MTLDevice resource
                // creation are documented as main-actor-only; previously this
                // ran on the Task's nonisolated continuation after `await
                // decodePage`, which races with main-actor render() /
                // texture(for:) calls. Same threading-invariant family as the
                // project's known "nextDrawable() off main thread → SIGABRT"
                // landmine.
                await MainActor.run { [weak self] in
                    guard !Task.isCancelled,
                          let self = self,
                          let renderer = self.renderer,
                          renderer.texture(for: seqIdx) == nil,
                          renderer.upload(pixelBuffer: buffer, for: seqIdx) != nil
                    else { return }
                    self.onTextureReady(seqIdx)
                }
            }
            await MainActor.run { [weak self] in
                self?.prefetchInFlightRange = nil
            }
        }
    }

    /// Called on the main actor when a prefetch upload completes. If the
    /// uploaded page is still within the most-recent visible range, we
    /// trigger a render so the user sees the page without needing to
    /// scroll again.
    func onTextureReady(_ seqIdx: Int) {
        guard lastVisibleRange.contains(seqIdx) else { return }
        render(visibleRange: lastVisibleRange)
    }

    @MainActor
    func render(visibleRange: ClosedRange<Int>) {
        guard let metalView = metalView,
              let renderer = renderer else { return }

        metalView.updateMetalLayerFrame()

        guard let drawable = metalView.metalLayer.nextDrawable() else {
            Task { await DCLogger.shared.log("SWITCH: render NIL-DRAWABLE layout=\(layout) visibleRange=\(visibleRange) layerFrame=\(metalView.metalLayer.frame) drawableSize=\(metalView.metalLayer.drawableSize)") }
            return
        }
        let renderPosCount = visibleRange.compactMap { idx -> Int? in
            guard idx >= 0 && idx < pages.count else { return nil }
            return pagePositions[pages[idx].id] != nil ? 1 : nil
        }.count
        Task { await DCLogger.shared.log("SWITCH: render layout=\(layout) visibleRange=\(visibleRange) layerFrame=\(metalView.metalLayer.frame) drawableSize=\(metalView.metalLayer.drawableSize) renderPosCount=\(renderPosCount)") }

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        var renderPositions: [Int: CGRect] = [:]
        for seqIdx in visibleRange {
            guard seqIdx < pages.count else { continue }
            let pageID = pages[seqIdx].id
            if let rect = pagePositions[pageID] {
                renderPositions[seqIdx] = rect
            }
        }

        // The shader's viewport MUST be the CAMetalLayer's frame in doc
        // coordinates — the drawable maps 1:1 onto that rect. Using
        // clipView.bounds here causes a squish when the drawable is
        // smaller than the clip (zoomed-out / recentred states), because
        // page-rect doc coords get normalised against a larger denominator
        // than the actual drawable can contain.
        let viewportRect = metalView.metalLayer.frame

        renderer.render(
            viewport: viewportRect,
            visibleRange: visibleRange,
            pagePositions: renderPositions,
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer
        )

        // Stale-size guard. If the layer's drawableSize changed between
        // nextDrawable() above and now (rare under main-actor flow, but
        // possible if a re-entrant updateMetalLayerFrame fired), the
        // drawable's texture is for the wrong viewport. Presenting it
        // would put a wrong-size image into the new bounds — exactly the
        // "stretched previous frame" symptom that contentsGravity =
        // topLeft is meant to mask. Skip the present in that case; the
        // next render with a correctly-sized drawable will catch up.
        // (Pattern adapted from Ghostty's IOSurfaceLayer.setSurfaceCallback.)
        let target = metalView.metalLayer.drawableSize
        if drawable.texture.width != Int(target.width) ||
           drawable.texture.height != Int(target.height) {
            commandBuffer.commit()
            return
        }

        // Hume canonical resize triplet (matched with
        // `metalLayer.presentsWithTransaction = true` in
        // MetalCanvasView.makeBackingLayer):
        //   1. commit the encoded work
        //   2. block until the command buffer is scheduled
        //      (microseconds-to-millisecond on Apple Silicon)
        //   3. present the drawable SYNCHRONOUSLY inside the running
        //      CATransaction so its appearance is atomic with the
        //      layer's bounds change.
        // Without this triplet, AppKit holds the previous-size drawable
        // across the resize gap and stretches it via the layer's
        // contentsGravity for one frame on every resize tick.
        //
        // Step 3 requires a CATransaction to be open. AppKit-driven
        // renders (scroll, resize) run inside one of AppKit's own
        // transactions, so `drawable.present()` commits in-frame there.
        // But renders fired from `DispatchQueue.main.async`, `asyncAfter`,
        // or a Task's `MainActor.run` continuation (notably the
        // `onTextureReady` path on cold open) have NO enclosing
        // transaction — `presentsWithTransaction = true` then queues
        // the drawable for "next CATransaction commit", which may not
        // fire until some other AppKit event wakes the runloop. The
        // user-visible symptom: a freshly-decoded page sits invisible
        // until the user scrolls or moves the mouse. Wrap the present
        // in an explicit CATransaction so the drawable always commits
        // immediately, regardless of who triggered the render. Inside
        // an already-open AppKit transaction this nests harmlessly.
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        CATransaction.begin()
        drawable.present()
        CATransaction.commit()
    }
}
