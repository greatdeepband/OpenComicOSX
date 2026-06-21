import SwiftUI

/// A dismissible overlay that lists every keyboard shortcut available in the
/// reader. Triggered by pressing `?`; dismissed via click or Escape.
///
/// Reduce-motion is respected: when `UIAccessibility.isReduceMotionEnabled`
/// (`accessibilityReduceMotion`) is true the overlay appears/disappears
/// instantly instead of fading.
struct ReaderShortcutsOverlay: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Shortcut rows: (keys label, description)
    private let shortcuts: [(String, String)] = [
        ("1",         "Single Page mode"),
        ("2",         "Double Page mode"),
        ("3",         "Vertical Scroll mode"),
        ("4",         "Vertical Double mode"),
        ("← / →",    "Previous / Next page"),
        ("A / D",     "Previous / Next page"),
        ("↑ / ↓",    "Zoom in / out"),
        ("Q / E",     "Previous / Next comic"),
        ("⌫ / Z",    "Back to Library"),
        ("⌘ D",       "Bookmark current page"),
        ("R",         "Toggle reading direction (LTR ↔ RTL)"),
        ("?",         "Show / hide this overlay"),
    ]

    var body: some View {
        ZStack {
            // Scrim — tap anywhere to dismiss
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)

            // Card
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.headline)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close shortcuts overlay")
                }
                .padding(.bottom, 12)

                Divider()
                    .padding(.bottom, 10)

                // Shortcut rows
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(row.0)
                            .font(.system(.body, design: .monospaced).bold())
                            .frame(minWidth: 64, alignment: .leading)
                        Text(row.1)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .frame(maxWidth: 360)
            .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
            .accessibilityAddTraits(.isModal)
        }
        .onExitCommand { dismiss() }   // Escape key dismissal
        // Animation — skip if reduce-motion is on
        .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.95)))
    }

    private func dismiss() {
        if reduceMotion {
            isPresented = false
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                isPresented = false
            }
        }
    }
}
