import SwiftUI
import AppKit

/// A high-quality zoomable and pannable image view.
/// Supports:
///   - Scroll wheel / trackpad pinch to zoom
///   - Drag to pan when zoomed in
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

    var body: some View {
        GeometryReader { geo in
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
                            let newScale = (scale * value.magnification)
                                .clamped(to: minScale...maxScale)
                            scale = newScale
                        }
                )
                // Drag to pan (only when zoomed in)
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
                // Scroll wheel zoom (mouse or trackpad two-finger scroll)
                .onScrollWheel { event in
                    let delta = event.deltaY
                    let factor: CGFloat = delta > 0 ? 0.95 : 1.05
                    scale = (scale * factor).clamped(to: minScale...maxScale)
                }
        }
    }
}

// MARK: - Scroll Wheel modifier

struct ScrollWheelModifier: ViewModifier {
    let action: (NSEvent) -> Void

    func body(content: Content) -> some View {
        content.background(
            ScrollWheelView(action: action)
        )
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let action: (NSEvent) -> Void

    func makeNSView(context: Context) -> _ScrollWheelNSView {
        let v = _ScrollWheelNSView()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: _ScrollWheelNSView, context: Context) {
        nsView.action = action
    }
}

final class _ScrollWheelNSView: NSView {
    var action: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        // Only intercept if modifier key (⌘ or ⌥) is held, or it's a pinch gesture
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
