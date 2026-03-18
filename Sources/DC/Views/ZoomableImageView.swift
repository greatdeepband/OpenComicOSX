import SwiftUI
import AppKit

/// A high-quality zoomable and pannable image view.
/// - Trackpad pinch / scroll-wheel to zoom
/// - Left-click drag to pan when zoomed in
/// - Right-click hold → circular magnifier loupe centred exactly on cursor
struct ZoomableImageView: View {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    let minScale: CGFloat
    let maxScale: CGFloat

    @GestureState private var gestureScale: CGFloat = 1.0

    @State private var showLoupe: Bool = false
    @State private var loupePosition: CGPoint = .zero   // container coords

    private let loupeRadius: CGFloat = 180

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Main image ──────────────────────────────────────────────
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .offset(x: offset.width, y: offset.height)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnifyGesture()
                            .updating($gestureScale) { v, s, _ in s = v.magnification }
                            .onEnded { v in
                                scale = (scale * v.magnification).clamped(to: minScale...maxScale)
                                offset = clampedOffset(offset, containerSize: geo.size, scale: scale)
                            }
                    )
                    .onScrollWheel { event in
                        let factor: CGFloat = event.deltaY > 0 ? 0.95 : 1.05
                        let newScale = (scale * factor).clamped(to: minScale...maxScale)
                        scale = newScale
                        offset = clampedOffset(offset, containerSize: geo.size, scale: newScale)
                    }

                // ── Loupe overlay ────────────────────────────────────────────
                if showLoupe {
                    MagnifierView(
                        image: image,
                        cursorInImageView: containerToImageCoords(loupePosition, containerSize: geo.size),
                        imageViewSize: computeImageViewSize(containerSize: geo.size)
                    )
                    .position(x: loupePosition.x, y: loupePosition.y)
                    .allowsHitTesting(false)
                }

                // ── Unified mouse catcher (pan + loupe) ──────────────────────
                MouseCatcher(
                    onLeftDragBegan: { _ in },
                    onLeftDragMoved: { delta in
                        let newOffset = CGSize(
                            width:  offset.width  + delta.width,
                            height: offset.height + delta.height
                        )
                        offset = clampedOffset(newOffset, containerSize: geo.size, scale: scale)
                    },
                    onLeftDragEnded: { _ in },
                    onRightBegan:  { pos in loupePosition = pos; showLoupe = true },
                    onRightMoved:  { pos in loupePosition = pos },
                    onRightEnded:  { showLoupe = false }
                )
                .allowsHitTesting(true)
            }
        }
    }

    // MARK: - Coordinate helpers

    private func computeImageViewSize(containerSize: CGSize) -> CGSize {
        let img = image.size
        guard img.width > 0, img.height > 0 else { return containerSize }
        let imgAR = img.width / img.height
        let conAR = containerSize.width / containerSize.height
        let fit: CGSize = imgAR > conAR
            ? CGSize(width: containerSize.width, height: containerSize.width / imgAR)
            : CGSize(width: containerSize.height * imgAR, height: containerSize.height)
        return CGSize(width: fit.width * scale, height: fit.height * scale)
    }

    private func containerToImageCoords(_ point: CGPoint, containerSize: CGSize) -> CGPoint {
        let ivSize = computeImageViewSize(containerSize: containerSize)
        let ox = (containerSize.width  - ivSize.width)  / 2 + offset.width
        let oy = (containerSize.height - ivSize.height) / 2 + offset.height
        return CGPoint(x: point.x - ox, y: point.y - oy)
    }

    /// Clamp offset so the image never leaves the container entirely.
    private func clampedOffset(_ proposed: CGSize, containerSize: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.0 else { return .zero }
        let ivSize = computeImageViewSize(containerSize: containerSize)
        // Maximum pan in each axis = half the overhang
        let maxX = max(0, (ivSize.width  - containerSize.width)  / 2)
        let maxY = max(0, (ivSize.height - containerSize.height) / 2)
        return CGSize(
            width:  proposed.width.clamped(to: -maxX...maxX),
            height: proposed.height.clamped(to: -maxY...maxY)
        )
    }
}

// MARK: - Unified mouse catcher (left drag + right click)

struct MouseCatcher: NSViewRepresentable {
    var onLeftDragBegan: (CGPoint) -> Void
    var onLeftDragMoved: (CGSize) -> Void
    var onLeftDragEnded: (CGPoint) -> Void
    var onRightBegan:   (CGPoint) -> Void
    var onRightMoved:   (CGPoint) -> Void
    var onRightEnded:   () -> Void

    func makeNSView(context: Context) -> _MouseCatcherView {
        let v = _MouseCatcherView()
        v.onLeftDragBegan = onLeftDragBegan
        v.onLeftDragMoved = onLeftDragMoved
        v.onLeftDragEnded = onLeftDragEnded
        v.onRightBegan    = onRightBegan
        v.onRightMoved    = onRightMoved
        v.onRightEnded    = onRightEnded
        return v
    }

    func updateNSView(_ v: _MouseCatcherView, context: Context) {
        v.onLeftDragBegan = onLeftDragBegan
        v.onLeftDragMoved = onLeftDragMoved
        v.onLeftDragEnded = onLeftDragEnded
        v.onRightBegan    = onRightBegan
        v.onRightMoved    = onRightMoved
        v.onRightEnded    = onRightEnded
    }
}

final class _MouseCatcherView: NSView {
    var onLeftDragBegan: ((CGPoint) -> Void)?
    var onLeftDragMoved: ((CGSize) -> Void)?
    var onLeftDragEnded: ((CGPoint) -> Void)?
    var onRightBegan:    ((CGPoint) -> Void)?
    var onRightMoved:    ((CGPoint) -> Void)?
    var onRightEnded:    (() -> Void)?

    private var lastDragLocation: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    // Left drag — pan
    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        onLeftDragBegan?(swiftPt(event))
    }
    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        let delta = CGSize(
            width:  current.x - lastDragLocation.x,
            height: -(current.y - lastDragLocation.y)   // flip Y for SwiftUI coords
        )
        lastDragLocation = current
        onLeftDragMoved?(delta)
    }
    override func mouseUp(with event: NSEvent) {
        onLeftDragEnded?(swiftPt(event))
    }

    // Right click — loupe
    override func rightMouseDown(with event: NSEvent)    { onRightBegan?(swiftPt(event)) }
    override func rightMouseDragged(with event: NSEvent) { onRightMoved?(swiftPt(event)) }
    override func rightMouseUp(with event: NSEvent)      { onRightEnded?() }

    /// Convert NSEvent window coords → SwiftUI view coords (Y flipped).
    private func swiftPt(_ event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }
}

// MARK: - Scroll-wheel zoom modifier

struct ScrollWheelModifier: ViewModifier {
    let action: (NSEvent) -> Void
    func body(content: Content) -> some View {
        content.background(ScrollWheelView(action: action))
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let action: (NSEvent) -> Void
    func makeNSView(context: Context) -> _SWView {
        let v = _SWView(); v.action = action; return v
    }
    func updateNSView(_ v: _SWView, context: Context) { v.action = action }
}

final class _SWView: NSView {
    var action: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .changed || event.phase == .began || event.momentumPhase == .changed {
            action?(event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

extension View {
    func onScrollWheel(_ action: @escaping (NSEvent) -> Void) -> some View {
        modifier(ScrollWheelModifier(action: action))
    }
}


