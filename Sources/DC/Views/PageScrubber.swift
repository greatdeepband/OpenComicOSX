import SwiftUI
import AppKit

// MARK: - Pure mapping helpers (also used by tests)

/// Maps an x position in the scrubber track to a page index.
/// Returns 0 for degenerate inputs (pageCount ≤ 1 or width ≤ 0).
func pageForScrubberPosition(x: CGFloat, width: CGFloat, pageCount: Int, isRTL: Bool) -> Int {
    guard pageCount > 1, width > 0 else { return 0 }
    let f = min(max(x / width, 0), 1)
    let p = Int((f * CGFloat(pageCount - 1)).rounded())
    return isRTL ? (pageCount - 1 - p) : p
}

/// Returns the fractional track position [0, 1] for the given page index.
/// 0 → leading edge, 1 → trailing edge.  In RTL, page 0 is at the trailing
/// edge (fraction 1.0) and the last page is at the leading edge (fraction 0.0).
func scrubberFraction(forPage page: Int, pageCount: Int, isRTL: Bool) -> CGFloat {
    guard pageCount > 1 else { return 0 }
    let p = min(max(page, 0), pageCount - 1)
    let f = CGFloat(p) / CGFloat(pageCount - 1)
    return isRTL ? (1 - f) : f
}

// MARK: - AcceptsFirstMouseView

/// Tiny NSViewRepresentable whose NSView returns `acceptsFirstMouse == true`
/// so that a first click on the scrubber strip while the window is inactive
/// is delivered as a real drag event rather than just activating the window.
private struct AcceptsFirstMouseView: NSViewRepresentable {
    func makeNSView(context: Context) -> _AFMView { _AFMView() }
    func updateNSView(_ nsView: _AFMView, context: Context) {}

    final class _AFMView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - PageScrubber

struct PageScrubber: View {
    @ObservedObject var vm: ReaderViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragPage: Int?

    private var displayPage: Int { dragPage ?? vm.currentPage }

    var body: some View {
        if vm.pageCount <= 1 {
            Color.clear.frame(height: ReaderConstants.scrubberStripHeight)
        } else {
            GeometryReader { geo in
                let W = geo.size.width
                let frac = scrubberFraction(forPage: displayPage,
                                            pageCount: vm.pageCount,
                                            isRTL: vm.isRTL)
                let isDragging = dragPage != nil
                // Track reacts ONLY while actively dragging — no hover/idle
                // highlight (the section must never light up on its own).
                let trackHeight: CGFloat = isDragging ? 6 : 4
                let thumbSize: CGFloat  = (!reduceMotion && isDragging) ? 16 : 13

                ZStack(alignment: .leading) {
                    // Background track — white@0.25 so it reads on both black
                    // and bright art (Color.primary flips to dark in light contexts
                    // and is too faint at 0.12 over bright page art).
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: trackHeight)

                    // Accent fill from leading edge to thumb position
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(frac * W, 0), height: trackHeight)

                    // Bookmark ticks — subtle thin marks at each bookmarked page position.
                    // Reuse scrubberFraction for RTL-correct positioning (same math as the thumb).
                    ForEach(vm.bookmarkedPages, id: \.self) { bm in
                        let bmFrac = scrubberFraction(forPage: bm,
                                                      pageCount: vm.pageCount,
                                                      isRTL: vm.isRTL)
                        Rectangle()
                            // white@0.5 so bookmark marks survive over bright art
                            // (Color.primary.opacity(0.35) fades on bright backgrounds).
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 2, height: trackHeight + 4)
                            .offset(x: max(bmFrac * W - 1, 0))
                    }

                    // Thumb
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                        .overlay(
                            Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                        .frame(width: thumbSize, height: thumbSize)
                        .offset(x: max(frac * W - thumbSize / 2, 0))

                    // Page-number bubble above thumb — shown only while dragging
                    if isDragging {
                        Text("Page \(displayPage + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .offset(
                                x: bubbleXOffset(frac: frac, thumbSize: thumbSize, trackWidth: W),
                                y: -22
                            )
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.1), value: isDragging)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: trackHeight)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: thumbSize)
                // Transparent hit area
                .contentShape(Rectangle())
                .background(AcceptsFirstMouseView())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let page = pageForScrubberPosition(
                                x: value.location.x,
                                width: W,
                                pageCount: vm.pageCount,
                                isRTL: vm.isRTL
                            )
                            dragPage = page
                            vm.previewPage(page)
                        }
                        .onEnded { _ in
                            vm.goTo(page: dragPage ?? vm.currentPage)
                            dragPage = nil
                        }
                )
            }
            .frame(height: ReaderConstants.scrubberStripHeight)
            // No `.focusable()`: it drew a macOS keyboard focus ring (the blue
            // outline that "lit up" on the strip) and the app-wide KeyMonitor
            // already handles ←/→ paging, so nothing functional is lost. The
            // strip now never highlights — on hover, focus, or idle.
            // VoiceOver / accessibility
            .accessibilityElement()
            // Note: AccessibilityTraits has no `.isAdjustable` / `.adjustable`
            // member on macOS (it exists only on iOS/tvOS). On macOS the
            // `.accessibilityAdjustableAction` modifier below is sufficient to
            // register the element with VoiceOver as an adjustable control.
            .accessibilityLabel("Page slider")
            .accessibilityValue("Page \(displayPage + 1) of \(vm.pageCount)")
            .accessibilityAdjustableAction { direction in
                direction == .increment ? vm.nextPage() : vm.previousPage()
            }
            // Glass pill container — matches the capsule treatment on the toolbar
            // so the scrubber is a self-bounding floating control rather than a
            // naked track line over black/art.
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .modifier(ScrubberGlassPill())
        }
    }

    /// Computes the X offset of the value bubble so it stays within track bounds.
    private func bubbleXOffset(frac: CGFloat, thumbSize: CGFloat, trackWidth: CGFloat) -> CGFloat {
        // Estimated bubble half-width; actual is dynamic but ~36pt covers "Page 999"
        let halfBubble: CGFloat = 30
        let thumbCenterX = max(frac * trackWidth - thumbSize / 2, 0) + thumbSize / 2
        let rawX = thumbCenterX - halfBubble
        let clampedX = min(max(rawX, 0), trackWidth - halfBubble * 2)
        return clampedX
    }
}

// MARK: - Scrubber glass pill

/// Applies the same self-bounding glass-pill treatment used by the toolbar
/// capsules so the scrubber floats as a single identifiable control rather
/// than a naked track over black/art. On macOS 26+ uses Liquid Glass + a
/// defining white rim; on macOS 14–25 falls back to `.ultraThinMaterial`.
private struct ScrubberGlassPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        }
    }
}
