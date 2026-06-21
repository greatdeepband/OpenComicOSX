import SwiftUI

private let coachmarkKey = "hasSeenReaderCoachmark"

struct ReaderCoachmark: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 16) {
                Text("Reading Controls")
                    .font(.headline)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 10) {
                    hint("Tap the page edges to turn")
                    hint("Hold to magnify")
                    hint("Controls hide while you read — move to the top or bottom edge to bring them back")
                    hint("Press ? for all shortcuts")
                }

                Button("Got it") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .frame(maxWidth: 380)
            .padding(40)
        }
        .onExitCommand { dismiss() }
        .accessibilityAddTraits(.isModal)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "circle.fill")
            .font(.body)
            .foregroundStyle(.white)
            .labelStyle(CoachmarkLabelStyle())
    }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: coachmarkKey)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            isPresented = false
        }
    }
}

private struct CoachmarkLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .padding(.top, 7)
                .foregroundStyle(.white.opacity(0.7))
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension UserDefaults {
    static var hasSeenReaderCoachmark: Bool {
        standard.bool(forKey: coachmarkKey)
    }
}
