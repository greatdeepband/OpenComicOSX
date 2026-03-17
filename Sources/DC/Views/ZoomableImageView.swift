import SwiftUI
import AppKit

/// A high-quality zoomable and pannable image view.
/// - Trackpad pinch / scroll-wheel to zoom
/// - Drag to pan when zoomed in
/// - Right-click hold → circular magnifier loupe centred exactly on cursor
struct ZoomableImageView: View {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    let minScale: CGFloat
    let maxScale: CGFloat

    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureDrag: CGSize = .zero

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
                    .offset(
                        x: offset.width + gestureDrag.width,
                        y: offset.height + gestureDrag.height
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnifyGesture()
                            .updating($gestureScale) { v, s, _ in s = v.magnification }
                            .onEnded { v in
                                scale = (scale * v.magnification).clamped(to: minScale...maxScale)
                            }
                    )
                    .gesture(
                        DragGesture()
                            .updating($gestureDrag) { v, s, _ in
                                guard scale > 1.05 else { return }
                                s = v.translation
                            }
                            .onEnded { v in
                                guard scale > 1.05 else { return }
                                offset = CGSize(
                                    width: offset.width + v.translation.width,
                                    height: offset.height + v.translation.height
                                )
                            }
                    )
                    .onScrollWheel { event in
                        let factor: CGFloat = event.deltaY > 0 ? 0.95 : 1.05
                        scale = (scale * factor).clamped(to: minScale...maxScale)
                    }

                // ── Loupe overlay — centred exactly on cursor ────────────────
                if showLoupe {
                    MagnifierView(
                        image: image,
                        cursorInImageView: containerToImageCoords(loupePosition, containerSize: geo.size),
                        imageViewSize: computeImageViewSize(containerSize: geo.size)
                    )
                    // .position centres the view's frame on the given point —
                    // so the loupe circle centre is exactly at loupePosition.
                    .position(x: loupePosition.x, y: loupePosition.y)
                    .allowsHitTesting(false)
                }

                // ── Right-click event catcher (on top, full frame) ───────────
                RightClickCatcher(
                    onBegan: { pos in loupePosition = pos; showLoupe = true },
                    onMoved: { pos in loupePosition = pos },
                    onEnded: { showLoupe = false }
                )
                .allowsHitTesting(true)
            }
        }
    }

    // MARK: - Coordinate helpers

    /// Size the image actually occupies on screen after scaledToFit + reader scale.
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

    /// Map a container-space point to image-view space (origin = top-left of the fitted image).
    private func containerToImageCoords(_ point: CGPoint, containerSize: CGSize) -> CGPoint {
        let ivSize = computeImageViewSize(containerSize: containerSize)
        let ox = (containerSize.width  - ivSize.width)  / 2 + offset.width
        let oy = (containerSize.height - ivSize.height) / 2 + offset.height
        return CGPoint(x: point.x - ox, y: point.y - oy)
    }
}

// MARK: - Right-click catcher

struct RightClickCatcher: NSViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> _RCatcherView {
        let v = _RCatcherView()
        v.onBegan = onBegan; v.onMoved = onMoved; v.onEnded = onEnded
        return v
    }

    func updateNSView(_ v: _RCatcherView, context: Context) {
        v.onBegan = onBegan; v.onMoved = onMoved; v.onEnded = onEnded
    }
}

final class _RCatcherView: NSView {
    var onBegan: ((CGPoint) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func rightMouseDown(with event: NSEvent)    { onBegan?(pt(event)) }
    override func rightMouseDragged(with event: NSEvent) { onMoved?(pt(event)) }
    override func rightMouseUp(with event: NSEvent)      { onEnded?() }

    private func pt(_ event: NSEvent) -> CGPoint {
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
