import SwiftUI

/// Modal sheet shown before any compression batch. Lets the user choose
/// whether to delete originals (replace in place) or keep both files,
/// whether to convert PNG entries to JPEG (gives substantial shrinkage
/// on PNG-heavy CBZs at the cost of breaking "format preservation"), and
/// a "Remember my choice" toggle that suppresses the sheet on future runs.
struct CompressionPromptSheet: View {

    /// Title shown at the top — varies by scope ("Compress 247 comics?",
    /// "Compress this comic?", "Compress 'Manga' gallery?", etc.)
    let title: String

    /// Sub-line that explains what compression does. Kept short — the
    /// prompt is for the binary decision, not the algorithm.
    let detailLine: String

    /// User-confirmed: (deleteOriginals, convertPNGs, rememberChoice)
    let onConfirm: (_ deleteOriginals: Bool, _ convertPNGs: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var deleteOriginals: Bool = false
    @State private var convertPNGs: Bool = false
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

            Toggle(isOn: $convertPNGs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convert PNG pages to JPEG")
                    Text("Best for PNG-heavy archives — typically 5–10× smaller. Slight quality loss; transparency is flattened on white.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Toggle("Remember my choice", isOn: $rememberChoice)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Compress") {
                    onConfirm(deleteOriginals, convertPNGs, rememberChoice)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // If the user previously ticked Remember, seed the toggles from
            // their saved choice so the prompt (when it does appear) shows
            // the same defaults they'd otherwise auto-skip with.
            if CompressionPreferences.hasRememberedChoice() {
                deleteOriginals = CompressionPreferences.rememberedDeleteOriginals()
                convertPNGs = CompressionPreferences.rememberedConvertPNGs()
                rememberChoice = true
            }
        }
    }
}

/// Wrapper around UserDefaults keys, so callers don't sprinkle string
/// constants. Used by LibraryViewModel before deciding whether to
/// present the sheet.
enum CompressionPreferences {
    static let deleteOriginalsKey   = "cbz.compression.deleteOriginals.choice"
    static let convertPNGsKey       = "cbz.compression.convertPNGs.choice"
    static let promptRememberedKey  = "cbz.compression.deleteOriginals.remembered"

    static func hasRememberedChoice(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: promptRememberedKey)
    }
    static func rememberedDeleteOriginals(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: deleteOriginalsKey)
    }
    static func rememberedConvertPNGs(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: convertPNGsKey)
    }
    static func remember(deleteOriginals: Bool, convertPNGs: Bool, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: promptRememberedKey)
        defaults.set(deleteOriginals, forKey: deleteOriginalsKey)
        defaults.set(convertPNGs, forKey: convertPNGsKey)
    }
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: promptRememberedKey)
        defaults.removeObject(forKey: deleteOriginalsKey)
        defaults.removeObject(forKey: convertPNGsKey)
    }
}
