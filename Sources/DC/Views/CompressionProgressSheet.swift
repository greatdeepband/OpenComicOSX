import SwiftUI

/// Modal sheet rendered while a `CompressionService` is `.running`,
/// `.finished`, `.cancelled`, or `.failed`. Binds to the service for
/// live progress and shows a per-file error list at the end.
struct CompressionProgressSheet: View {
    @ObservedObject var service: CompressionService
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private var header: some View {
        switch service.state {
        case .idle:
            Text("Compression").font(.title3).bold()
        case .running:
            Text("Compressing comics…").font(.title3).bold()
        case .finished:
            Text("Compression complete").font(.title3).bold()
        case .cancelled:
            Text("Compression cancelled").font(.title3).bold()
        case .failed:
            Text("Compression failed").font(.title3).bold()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            Text("Idle.")
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(service.filesCompleted),
                             total: Double(max(service.filesTotal, 1)))
                Text("\(service.filesCompleted) of \(service.filesTotal)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let url = service.currentFileURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .finished(let summary), .cancelled(let summary):
            summaryView(summary)
        case .failed(let error):
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func summaryView(_ summary: CompressionService.BatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow("Compressed:",    "\(summary.succeeded) of \(summary.attempted)")
            statRow("Skipped (non-CBZ):", "\(summary.skippedNonCBZ)")
            statRow("Failed:",        "\(summary.failed)")
            let saved = summary.totalInputBytes - summary.totalOutputBytes
            if summary.totalInputBytes > 0 {
                statRow(
                    "Total bytes:",
                    "\(byteString(summary.totalInputBytes)) → \(byteString(summary.totalOutputBytes)) (saved \(byteString(max(0, saved))))"
                )
            }
            if !summary.errors.isEmpty {
                Divider()
                Text("Errors:").font(.callout).bold()
                ScrollView { VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.errors.enumerated()), id: \.offset) { _, e in
                        Text("• \(e.url.lastPathComponent): \(e.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } }.frame(maxHeight: 120)
            }
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch service.state {
            case .running:
                Button("Cancel", role: .cancel) { service.cancel() }
            case .idle, .finished, .cancelled, .failed:
                Button("Done") {
                    service.acknowledge()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
