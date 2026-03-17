import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: LibraryViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("DC")
                    .font(.largeTitle.bold())
                Spacer()
                Button(action: { library.openFilePicker() }) {
                    Label("Open Comic", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            }
            .padding()

            Divider()

            if library.isLoading {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if let error = library.errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Dismiss") { library.errorMessage = nil }
                }
                .padding()
                Spacer()
            } else if library.recentComics.isEmpty {
                emptyState
            } else {
                recentGrid
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No comics yet")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open a CBZ, PDF, CBR, CB7, or CBT file to get started.")
                .foregroundStyle(.tertiary)
            Button("Open Comic…") { library.openFilePicker() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Recent Grid

    private var recentGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.recentComics) { recent in
                        RecentComicCard(comic: recent)
                            .onTapGesture {
                                Task { await library.load(url: recent.url) }
                            }
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Recent Comic Card

struct RecentComicCard: View {
    let comic: RecentComic

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(0.7, contentMode: .fit)
                .overlay {
                    Image(systemName: "book.pages")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                }

            Text(comic.title)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .hoverEffect()
    }
}

extension View {
    func hoverEffect() -> some View {
        self.onHover { _ in }  // placeholder — extend with hover state if needed
    }
}
