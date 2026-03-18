import SwiftUI
import AppKit

// MARK: - LibraryView

struct LibraryView: View {
    @EnvironmentObject var library: LibraryViewModel

    /// Which sections are collapsed (by their string key).
    @State private var collapsed: Set<String> = []
    /// Controls the Create Gallery sheet.
    @State private var showCreateGallery = false
    /// Controls the Rename sheet — holds the gallery being renamed.
    @State private var renamingGallery: Gallery? = nil
    @State private var renameText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if library.isLoading {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if let error = library.errorMessage {
                errorView(error)
            } else {
                mainContent
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(isPresented: $showCreateGallery) {
            CreateGallerySheet()
                .environmentObject(library)
        }
        .sheet(item: $renamingGallery) { gallery in
            RenameGallerySheet(gallery: gallery, text: $renameText) {
                library.renameGallery(id: gallery.id, newName: renameText)
                renamingGallery = nil
            } onCancel: {
                renamingGallery = nil
            }
            .environmentObject(library)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Open Comic")
                .font(.largeTitle.bold())
            Spacer()
            Button(action: { showCreateGallery = true }) {
                Text("Create Gallery")
            }
            .buttonStyle(.bordered)

            Button(action: { library.openFilePicker() }) {
                Label("Open Comic", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding()
    }

    // MARK: - Main content

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Recent section
                if !library.recentComics.isEmpty {
                    SectionHeader(
                        title: "Recent",
                        key: "recent",
                        collapsed: $collapsed
                    )
                    if !collapsed.contains("recent") {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(library.recentComics) { recent in
                                ComicCard(url: recent.url, title: recent.title, readingProgress: recent.readingProgress)
                                    .onTapGesture { Task { await library.load(url: recent.url) } }
                                    .contextMenu {
                                        Button("Open") { Task { await library.load(url: recent.url) } }
                                        Divider()
                                        Button("Remove from Recents", role: .destructive) {
                                            library.removeRecent(recent)
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                    }
                }

                // Gallery sections
                ForEach(library.galleries) { gallery in
                    SectionHeader(
                        title: gallery.name,
                        key: gallery.id.uuidString,
                        collapsed: $collapsed,
                        trailingMenu: {
                            AnyView(galleryMenu(for: gallery))
                        }
                    )
                    if !collapsed.contains(gallery.id.uuidString) {
                        if gallery.comics.isEmpty {
                            emptyGalleryPlaceholder(for: gallery)
                        } else {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(gallery.comics, id: \.self) { url in
                                    ComicCard(url: url, title: url.deletingPathExtension().lastPathComponent, readingProgress: nil)
                                        .onTapGesture { Task { await library.load(url: url) } }
                                        .contextMenu {
                                            Button("Open") { Task { await library.load(url: url) } }
                                        }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 20)
                        }
                    }
                }

                // Empty state when no recents and no galleries
                if library.recentComics.isEmpty && library.galleries.isEmpty {
                    emptyState
                }
            }
        }
    }

    // MARK: - Gallery context menu

    private func galleryMenu(for gallery: Gallery) -> some View {
        Group {
            Button("Add Folders…") {
                pickFolders { urls in
                    library.addFolders(urls, to: gallery.id)
                }
            }
            Button("Rename…") {
                renameText = gallery.name
                renamingGallery = gallery
            }
            Divider()
            Button("Delete Gallery", role: .destructive) {
                library.deleteGallery(id: gallery.id)
            }
        }
    }

    // MARK: - Empty gallery placeholder

    private func emptyGalleryPlaceholder(for gallery: Gallery) -> some View {
        HStack {
            Button("Add Folders…") {
                pickFolders { urls in
                    library.addFolders(urls, to: gallery.id)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.bottom, 16)
            Spacer()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 60)
            Image(systemName: "book.closed")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No comics yet")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open a CBZ, PDF, CBR, CB7, or CBT file to get started, or create a Gallery.")
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Open Comic…") { library.openFilePicker() }
                    .buttonStyle(.borderedProminent)
                Button("Create Gallery") { showCreateGallery = true }
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 60)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error view

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(error)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Dismiss") { library.errorMessage = nil }
            Spacer()
        }
        .padding()
    }

    // MARK: - Folder picker helper

    private func pickFolders(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders"
        panel.message = "Select one or more folders containing comic files"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            completion(panel.urls)
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let key: String
    @Binding var collapsed: Set<String>
    var trailingMenu: (() -> AnyView)? = nil

    private var isCollapsed: Bool { collapsed.contains(key) }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            // Context menu for galleries (three-dot button)
            if let menu = trailingMenu {
                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Collapse chevron
            Button(action: {
                if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
            }) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
        }
    }
}

// MARK: - Comic Card (generic, works for recents and galleries)

struct ComicCard: View {
    let url: URL
    let title: String
    let readingProgress: Double?

    @EnvironmentObject var library: LibraryViewModel
    @State private var thumbnail: NSImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverImage
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if let progress = readingProgress, progress > 0.02 {
                        progressBadge(progress)
                    }
                }

            Text(title)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onAppear { loadThumb() }
        .onChange(of: library.thumbnailGeneration) { loadThumb() }
    }

    private func loadThumb() {
        if let img = LibraryViewModel.loadThumbnail(for: url) {
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

// MARK: - Create Gallery Sheet

struct CreateGallerySheet: View {
    @EnvironmentObject var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedFolders: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create Gallery")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.headline)
                TextField("e.g. Batman, Marvel 90s…", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Source Folders").font(.headline)

                if selectedFolders.isEmpty {
                    Text("No folders selected yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(selectedFolders, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(url.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(action: { selectedFolders.removeAll { $0 == url } }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button("Add Folders…") { pickFolders() }
                    .buttonStyle(.bordered)
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Create") {
                    library.createGallery(name: name.isEmpty ? "Gallery" : name, folders: selectedFolders)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty && selectedFolders.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 380)
    }

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders"
        panel.message = "Select one or more folders containing comic files"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let existing = Set(selectedFolders.map { $0.path })
            let newOnes = panel.urls.filter { !existing.contains($0.path) }
            selectedFolders.append(contentsOf: newOnes)
        }
    }
}

// MARK: - Rename Gallery Sheet

struct RenameGallerySheet: View {
    let gallery: Gallery
    @Binding var text: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Gallery")
                .font(.title2.bold())
            TextField("Gallery name", text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Rename", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
