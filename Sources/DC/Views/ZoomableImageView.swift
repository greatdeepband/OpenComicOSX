import SwiftUI
import AppKit

/// A high-quality zoomable and pannable image view.
/// Supports:
///   - Scroll wheel / trackpad pinch to zoom
///   - Drag to pan when zoomed in
///   - Right-click hold → circular magnifier loupe (1.3×)
///   - Programmatic scale + offset bindings
struct ZoomableImageView: View {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    let minScale: CGFloat
    let maxScale: CGFloat

    // Gesture state
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureDrag: CGSize = .zero

    // Loupe state
    @State private var showLoupe: Bool = false
    @State private var loupePosition: CGPoint = .zero   // in view coordinates
    @State private var imageViewSize: CGSize = .zero    // rendered image frame size

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
                    // Pinch to zoom
                    .gesture(
                        MagnifyGesture()
                            .updating($gestureScale) { value, state, _ in
                                state = value.magnification
                            }
                            .onEnded { value in
                                scale = (scale * value.magnification)
                                    .clamped(to: minScale...maxScale)
                            }
                    )
                    // Drag to pan
                    .gesture(
                        DragGesture()
                            .updating($gestureDrag) { value, state, _ in
                                guard scale > 1.05 else { return }
                                state = value.translation
                            }
                            .onEnded { value in
                                guard scale > 1.05 else { return }
                                offset = CGSize(
                                    width: offset.width + value.translation.width,
                                    height: offset.height + value.translation.height
                                )
                            }
                    )
                    // Scroll-wheel zoom
                    .onScrollWheel { event in
                        let delta = event.deltaY
                        let factor: CGFloat = delta > 0 ? 0.95 : 1.05
                        scale = (scale * factor).clamped(to: minScale...maxScale)
                    }
                    // Right-click loupe via NSView overlay
                    .background(
                        RightClickTracker(
                            onRightClickBegan: { pos in
                                loupePosition = pos
                                imageViewSize = computeImageViewSize(containerSize: geo.size)
                                showLoupe = true
                            },
                            onRightClickMoved: { pos in
                                loupePosition = pos
                            },
                            onRightClickEnded: {
                                showLoupe = false
                            }
                        )
                    )

                // ── Loupe overlay ────────────────────────────────────────────
                if showLoupe {
                    loupeOverlay(containerSize: geo.size)
                }
            }
        }
    }

    // MARK: - Loupe overlay

    @ViewBuilder
    private func loupeOverlay(containerSize: CGSize) -> some View {
        let loupeRadius: CGFloat = 90
        let offsetX: CGFloat = 20  // nudge right of cursor
        let offsetY: CGFloat = -loupeRadius - 20  // above cursor

        // Map loupePosition (in container coords) to image coords
        let imgPos = containerToImageCoords(
            point: loupePosition,
            containerSize: containerSize
        )

        MagnifierView(
            image: image,
            cursorPosition: imgPos,
            imageViewSize: imageViewSize,
            readerScale: scale
        )
        .position(
            x: (loupePosition.x + offsetX + loupeRadius)
                .clamped(to: loupeRadius...(containerSize.width - loupeRadius)),
            y: (loupePosition.y + offsetY)
                .clamped(to: loupeRadius...(containerSize.height - loupeRadius))
        )
        .allowsHitTesting(false)
    }

    // MARK: - Coordinate helpers

    /// Returns the size the image actually occupies on screen (scaledToFit + scale).
    private func computeImageViewSize(containerSize: CGSize) -> CGSize {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return containerSize }
        let aspectRatio = imgSize.width / imgSize.height
        let containerAspect = containerSize.width / containerSize.height
        var fitSize: CGSize
        if aspectRatio > containerAspect {
            fitSize = CGSize(width: containerSize.width, height: containerSize.width / aspectRatio)
        } else {
            fitSize = CGSize(width: containerSize.height * aspectRatio, height: containerSize.height)
        }
        return CGSize(width: fitSize.width * scale, height: fitSize.height * scale)
    }

    /// Maps a point in container coordinates to image-view coordinates (accounting for centering).
    private func containerToImageCoords(point: CGPoint, containerSize: CGSize) -> CGPoint {
        let ivSize = computeImageViewSize(containerSize: containerSize)
        let originX = (containerSize.width  - ivSize.width)  / 2 + offset.width
        let originY = (containerSize.height - ivSize.height) / 2 + offset.height
        return CGPoint(
            x: point.x - originX,
            y: point.y - originY
        )
    }
}

// MARK: - Right-click tracker (NSView)

struct RightClickTracker: NSViewRepresentable {
    var onRightClickBegan: (CGPoint) -> Void
    var onRightClickMoved: (CGPoint) -> Void
    var onRightClickEnded: () -> Void

    func makeNSView(context: Context) -> _RightClickNSView {
        let v = _RightClickNSView()
        v.onRightClickBegan = onRightClickBegan
        v.onRightClickMoved = onRightClickMoved
        v.onRightClickEnded = onRightClickEnded
        return v
    }

    func updateNSView(_ nsView: _RightClickNSView, context: Context) {
        nsView.onRightClickBegan = onRightClickBegan
        nsView.onRightClickMoved = onRightClickMoved
        nsView.onRightClickEnded = onRightClickEnded
    }
}

final class _RightClickNSView: NSView {
    var onRightClickBegan: ((CGPoint) -> Void)?
    var onRightClickMoved: ((CGPoint) -> Void)?
    var onRightClickEnded: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        let pos = swiftUIPoint(from: event)
        onRightClickBegan?(pos)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let pos = swiftUIPoint(from: event)
        onRightClickMoved?(pos)
    }

    override func rightMouseUp(with event: NSEvent) {
        onRightClickEnded?()
    }

    // Also intercept scroll-wheel for zoom (previously in ScrollWheelModifier)
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    /// Convert NSEvent location (bottom-left origin) to SwiftUI coords (top-left origin).
    private func swiftUIPoint(from event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }
}

// MARK: - Scroll Wheel modifier (unchanged)

struct ScrollWheelModifier: ViewModifier {
    let action: (NSEvent) -> Void
    func body(content: Content) -> some View {
        content.background(ScrollWheelView(action: action))
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let action: (NSEvent) -> Void
    func makeNSView(context: Context) -> _ScrollWheelNSView { 
        let v = _ScrollWheelNSView()
        v.action = action
        return v
    }
    func updateNSView(_ nsView: _ScrollWheelNSView, context: Context) { nsView.action = action }
}

final class _ScrollWheelNSView: NSView {
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
