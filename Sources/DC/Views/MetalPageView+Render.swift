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
                guard let self = self, seqIdx < self.pages.count else { continue }
                let page = self.pages[seqIdx]
                if self.renderer?.texture(for: seqIdx) != nil { continue }
                guard let buffer = await manager.decodePage(pageIndex: seqIdx, from: page.source) else {
                    continue
                }
                if Task.isCancelled { return }
                if self.renderer?.texture(for: seqIdx) == nil {
                    _ = self.renderer?.upload(pixelBuffer: buffer, for: seqIdx)
                }
                await MainActor.run {
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

        guard let drawable = metalView.metalLayer.nextDrawable() else { return }

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

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
