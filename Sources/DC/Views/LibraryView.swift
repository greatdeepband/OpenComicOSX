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
                            .contextMenu {
                                Button("Open") {
                                    Task { await library.load(url: recent.url) }
                                }
                                Divider()
                                Button("Remove from Recents", role: .destructive) {
                                    library.removeRecent(recent)
                                }
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
    /// Observed so the card reloads when a background thumbnail is saved.
    @EnvironmentObject var library: LibraryViewModel
    @State private var thumbnail: NSImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverImage
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if let progress = comic.readingProgress, progress > 0.02 {
                        progressBadge(progress)
                    }
                }

            Text(comic.title)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onAppear { loadThumb() }
        .onChange(of: library.thumbnailGeneration) { _ in loadThumb() }
    }

    private func loadThumb() {
        if let img = LibraryViewModel.loadThumbnail(for: comic.url) {
            thumbnail = img
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let img = thumbnail {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .overlay {
                    Image(systemName: "book.pages")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func progressBadge(_ progress: Double) -> some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.6))
                .frame(width: 44, height: 18)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(6)
    }
}
