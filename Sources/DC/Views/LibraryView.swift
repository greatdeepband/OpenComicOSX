import SwiftUI
import AppKit

// MARK: - LibraryView

struct LibraryView: View {
    @EnvironmentObject var library: LibraryViewModel

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
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(library.totalComics)")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pages Read")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(library.totalPages)")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                }
            }

            Spacer()

            // Centered search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField("Search comics", text: $library.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 220)
                if !library.searchQuery.isEmpty {
                    Button(action: { library.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Flat search results — shown instead of gallery sections when a query is active
                    if !library.searchQuery.isEmpty {
                        if library.searchResults.isEmpty {
                            Text("No results for \"\(library.searchQuery)\"")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 60)
                        } else {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(library.searchResults, id: \.self) { url in
                                    let title = url.deletingPathExtension().lastPathComponent
                                    ComicCard(url: url, title: title, readingProgress: nil)
                                        .id(url)
                                        .onTapGesture { Task { await library.load(url: url) } }
                                        .contextMenu {
                                            Button("Open") { Task { await library.load(url: url) } }
                                        }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 16)
                        }
                    } else {

                    // Recent section
                    if !library.filteredRecentComics.isEmpty {
                        GallerySectionHeader(
                            title: "Recent",
                            key: "recent",
                            collapsed: $library.collapsedSections
                        )
                        .id("header:recent")
                        if !library.collapsedSections.contains("recent") {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(library.filteredRecentComics) { recent in
                                    ComicCard(url: recent.url, title: recent.title, readingProgress: recent.readingProgress)
                                        .id(recent.url)
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
                    ForEach(library.filteredGalleries) { gallery in
                        GallerySectionHeader(
                            title: gallery.name,
                            key: gallery.id.uuidString,
                            collapsed: $library.collapsedSections,
                            menuContent: AnyView(galleryMenu(for: gallery))
                        )
                        .id("header:" + gallery.id.uuidString)
                        if !library.collapsedSections.contains(gallery.id.uuidString) {
                            if gallery.comics.isEmpty {
                                emptyGalleryPlaceholder(for: gallery)
                            } else {
                                DraggableComicGrid(
                                    gallery: gallery,
                                    columns: columns
                                )
                            }
                        }
                    }

                    // Empty state when no recents and no galleries
                    if library.recentComics.isEmpty && library.galleries.isEmpty {
                        emptyState
                    }

                    } // end else (no search query)
                }
            }
            .onAppear {
                if !library.hasLaunched {
                    // Cold launch: collapse all galleries, leave Recent open.
                    var keys: Set<String> = []
                    for g in library.galleries { keys.insert(g.id.uuidString) }
                    library.collapsedSections = keys
                    library.hasLaunched = true
                }
            }
            .onChange(of: library.openComic) { oldComic, newComic in
                // Only act when transitioning from reader back to library (non-nil → nil).
                guard oldComic != nil, newComic == nil, let url = library.lastOpenedURL else { return }
                // Expand the gallery that contains this comic so the card is in the view tree.
                let inGallery = library.galleries.contains(where: { $0.comics.contains(url) })
                if inGallery {
                    for g in library.galleries where g.comics.contains(url) {
                        library.collapsedSections.remove(g.id.uuidString)
                    }
                } else if library.recentComics.contains(where: { $0.url == url }) {
                    library.collapsedSections.remove("recent")
                }
                // Scroll to the section header (always rendered) so it's reliable.
                let scrollTarget: String
                if inGallery,
                   let g = library.galleries.first(where: { $0.comics.contains(url) }) {
                    scrollTarget = "header:" + g.id.uuidString
                } else {
                    scrollTarget = "header:recent"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scrollTarget, anchor: .top) }
                }
            }
            .onChange(of: library.galleries.count) {
                // Collapse any newly added gallery (only applies during the session).
                for g in library.galleries where !library.collapsedSections.contains(g.id.uuidString) {
                    library.collapsedSections.insert(g.id.uuidString)
                }
            }
        }
    }

    // MARK: - Gallery context menu

    private func galleryMenu(for gallery: Gallery) -> some View {
        Group {
            Button("Add Folders…") {
                pickFolders { urls in library.addFolders(urls, to: gallery.id) }
            }
            Button("Rename…") {
                renameText = gallery.name
                renamingGallery = gallery
            }
            Divider()
            Button("Reset to Alphabetical Order") {
                library.resetGalleryOrder(id: gallery.id)
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
                pickFolders { urls in library.addFolders(urls, to: gallery.id) }
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

// MARK: - Draggable Comic Grid

/// A grid of comic cards for a single gallery that supports drag-to-reorder.
struct DraggableComicGrid: View {
    let gallery: Gallery
    let columns: [GridItem]
    @EnvironmentObject var library: LibraryViewModel

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(gallery.comics.enumerated()), id: \.element) { index, url in
                ComicCard(
                    url: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    readingProgress: nil
                )
                .id(url)
                .onTapGesture { Task { await library.load(url: url) } }
                .contextMenu {
                    Button("Open") { Task { await library.load(url: url) } }
                    Divider()
                    Button("Remove from Gallery", role: .destructive) {
                        library.removeComics([url], from: gallery.id)
                    }
                }
                .onDrag {
                    NSItemProvider(object: url.path as NSString)
                }
                .onDrop(of: [.plainText], delegate: ComicDropDelegate(
                    targetIndex: index,
                    galleryID: gallery.id,
                    library: library
                ))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }
}

// MARK: - Drop Delegate for comic reordering

struct ComicDropDelegate: DropDelegate {
    let targetIndex: Int
    let galleryID: UUID
    let library: LibraryViewModel

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.plainText]).first else { return false }
        item.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { data, _ in
            guard let data = data as? Data,
                  let path = String(data: data, encoding: .utf8),
                  let gallery = library.galleries.first(where: { $0.id == galleryID }),
                  let sourceIndex = gallery.comics.firstIndex(where: { $0.path == path })
            else { return }
            DispatchQueue.main.async {
                library.moveComics(in: galleryID, from: IndexSet(integer: sourceIndex), to: targetIndex)
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Gallery Section Header
// Layout: [Title]  [▾/▸]  [⋯]

struct GallerySectionHeader: View {
    let title: String
    let key: String
    @Binding var collapsed: Set<String>
    var menuContent: AnyView? = nil

    private var isCollapsed: Bool { collapsed.contains(key) }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // Collapse chevron — first on the right
            Button(action: toggleCollapse) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)

            // Options menu — second on the right (only for galleries)
            if let menu = menuContent {
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapse() }
    }

    private func toggleCollapse() {
        if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
    }
}

// MARK: - Comic Card

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
        // Fast path: NSCache hit — no disk I/O.
        if let img = library.cachedThumbnail(for: url) {
            thumbnail = img
            return
        }
        // Slow path: NSCache miss (evicted or not yet loaded).
        // Load from disk on a background thread so the main thread isn't blocked,
        // then re-insert into NSCache so subsequent scrolls are instant.
        let comicURL = url
        Task.detached(priority: .utility) {
            guard let img = LibraryViewModel.loadThumbnail(for: comicURL) else { return }
            await MainActor.run { [weak library] in
                // Re-populate the cache so the next scroll past this card is free.
                library?.insertIntoCache(img, for: comicURL)
                self.thumbnail = img
            }
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

    private var nameIsValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
                    library.createGallery(
                        name: name.trimmingCharacters(in: .whitespaces),
                        folders: selectedFolders
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!nameIsValid)
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
