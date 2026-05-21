import SwiftUI

/// Modal sheet shown before any compression batch. Lets the user choose
/// whether to delete originals (replace in place) or keep both files,
/// with a "Remember my choice" toggle that suppresses the sheet on
/// future runs (read from UserDefaults by the caller via
/// `CompressionPreferences.shouldShowPrompt`).
struct CompressionPromptSheet: View {

    /// Title shown at the top — varies by scope ("Compress 247 comics?",
    /// "Compress this comic?", "Compress 'Manga' gallery?", etc.)
    let title: String

    /// Sub-line that explains what compression does. Kept short — the
    /// prompt is for the binary decision, not the algorithm.
    let detailLine: String

    /// User-confirmed: (deleteOriginals, rememberChoice)
    let onConfirm: (_ deleteOriginals: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var deleteOriginals: Bool = true
    @State private var rememberChoice: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3).bold()
            Text(detailLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker(selection: $deleteOriginals) {
                    Text("Delete originals (replace in place)").tag(true)
                    Text("Keep originals (save next to them as '…-original.cbz')").tag(false)
                } label: {
                    Text("After compression:")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Toggle("Remember my choice", isOn: $rememberChoice)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Compress") {
                    onConfirm(deleteOriginals, rememberChoice)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Wrapper around UserDefaults keys, so callers don't sprinkle string
/// constants. Used by LibraryViewModel before deciding whether to
/// present the sheet.
enum CompressionPreferences {
    static let deleteOriginalsKey   = "cbz.compression.deleteOriginals.choice"
    static let promptRememberedKey  = "cbz.compression.deleteOriginals.remembered"

    static var hasRememberedChoice: Bool {
        UserDefaults.standard.bool(forKey: promptRememberedKey)
    }
    static var rememberedDeleteOriginals: Bool {
        UserDefaults.standard.bool(forKey: deleteOriginalsKey)
    }
    static func remember(deleteOriginals: Bool) {
        UserDefaults.standard.set(true, forKey: promptRememberedKey)
        UserDefaults.standard.set(deleteOriginals, forKey: deleteOriginalsKey)
    }
    static func reset() {
        UserDefaults.standard.removeObject(forKey: promptRememberedKey)
        UserDefaults.standard.removeObject(forKey: deleteOriginalsKey)
    }
}
