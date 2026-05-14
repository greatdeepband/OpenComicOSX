import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LibraryView (NavigationSplitView shell)

struct LibraryView: View {
    @EnvironmentObject var library: LibraryViewModel
    @StateObject private var memoryMonitor = MemoryMonitor.shared

    @State private var showCreateGallery = false
    @State private var renamingGallery: Gallery? = nil
    @State private var renameText = ""
    @State private var debugMode = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDropTargeted = false

    private static let comicExtensions: Set<String> = [
        "cbz", "cbr", "cb7", "cbt", "pdf"
    ]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(
                renamingGallery: $renamingGallery,
                renameText: $renameText,
                showCreateGallery: $showCreateGallery
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            LibraryDetail(debugMode: $debugMode)
                .navigationSplitViewColumnWidth(min: 500, ideal: 900)
                .frame(minWidth: 500, minHeight: 400)
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $showCreateGallery) {
            CreateGallerySheet().environmentObject(library)
        }
        .sheet(item: $renamingGallery) { gallery in
            RenameGallerySheet(gallery: gallery, text: $renameText) {
                library.renameGallery(id: gallery.id, newName: renameText)
                renamingGallery = nil
            } onCancel: { renamingGallery = nil }
        }
        .overlay(alignment: .bottom) {
            if debugMode {
                DebugMemoryBar(monitor: memoryMonitor)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let error = library.errorMessage {
                ErrorBanner(message: error) { library.errorMessage = nil }
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if library.isLoading {
                LoadingOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: library.isLoading)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("Drop comics to add to your library", systemImage: "tray.and.arrow.down")
                            .font(.title2.bold())
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleLibraryDrop(providers: providers)
        }
        .onChange(of: debugMode) {
            if debugMode {
                MemoryMonitor.shared.start(library: library, interval: 5)
            } else {
                MemoryMonitor.shared.stop()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: debugMode)
    }

    private func handleLibraryDrop(providers: [NSItemProvider]) -> Bool {
        // Eagerly accept any drop that claims to be a file URL — the real
        // extension check happens in the async callback and opens the comic.
        // Returning the async result would always be `false` because this
        // method returns before the callback fires, which made SwiftUI show a
        // rejection cursor even though the load actually proceeded.
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else {
            return false
        }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let ext = url.pathExtension.lowercased()
                guard Self.comicExtensions.contains(ext) else { return }
                Task { @MainActor in
                    await library.load(url: url)
                }
            }
        }
        return true
    }
}

// MARK: - LibrarySidebar

struct LibrarySidebar: View {
    @EnvironmentObject var library: LibraryViewModel
    @Binding var renamingGallery: Gallery?
    @Binding var renameText: String
    @Binding var showCreateGallery: Bool

    var body: some View {
        List(selection: $library.selectedSection) {
            Section {
                SidebarRow(section: .home, systemImage: "house",
                           title: "Home", count: nil)
                SidebarRow(section: .favorites, systemImage: "heart",
                           title: "Favorites", count: library.favoriteURLs.count)
                SidebarRow(section: .recents, systemImage: "clock",
                           title: "Recents", count: library.recentComics.count)
                SidebarRow(section: .allComics, systemImage: "books.vertical",
                           title: "All Comics", count: library.totalComics)
            }

            if !library.galleries.isEmpty {
                Section("Galleries") {
                    ForEach(library.galleries) { gallery in
                        SidebarRow(
                            section: .gallery(gallery.id),
                            systemImage: "folder",
                            title: gallery.name,
                            count: gallery.comics.count
                        )
                        .contextMenu {
                            galleryMenu(for: gallery)
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleDrop(providers: providers, galleryID: gallery.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                showCreateGallery = true
            } label: {
                Label("New Gallery", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(10)
        }
    }

    @ViewBuilder
    private func galleryMenu(for gallery: Gallery) -> some View {
        Button("Rename…") {
            renameText = gallery.name
            renamingGallery = gallery
        }
        Button("Add Folders…") {
            pickFolders { urls in library.addFolders(urls, to: gallery.id) }
        }
        Button("Reset to Alphabetical Order") {
            library.resetGalleryOrder(id: gallery.id)
        }
        Divider()
        Button("Delete Gallery", role: .destructive) {
            library.deleteGallery(id: gallery.id)
        }
    }

    private func handleDrop(providers: [NSItemProvider], galleryID: UUID) -> Bool {
        // Eagerly accept — async callback moves the comic onto the receiving
        // gallery. Returning the async result sync always produced `false`,
        // showing a rejection cursor despite the move succeeding.
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else {
            return false
        }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    library.moveComic(url, toGallery: galleryID)
                }
            }
        }
        return true
    }

    private func pickFolders(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { completion(panel.urls) }
    }
}

private struct SidebarRow: View {
    let section: LibrarySection
    let systemImage: String
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .tag(section)
    }
}

// MARK: - LibraryDetail (router)

struct LibraryDetail: View {
    @EnvironmentObject var library: LibraryViewModel
    @Binding var debugMode: Bool

    var body: some View {
        switch library.selectedSection ?? .home {
        case .home:
            LibraryHome(debugMode: $debugMode)
        case .favorites:
            LibraryGridPane(
                section: .favorites,
                title: "Favorites",
                emptyTitle: "No favorites yet",
                emptyHint: "Tap the heart on any comic to favorite it.",
                sourceURLs: library.favoriteURLs,
                debugMode: $debugMode
            )
        case .recents:
            LibraryGridPane(
                section: .recents,
                title: "Recents",
                emptyTitle: "No recent comics",
                emptyHint: "Open a comic to start a recent list.",
                sourceURLs: library.recentComics.map { $0.url },
                debugMode: $debugMode
            )
        case .allComics:
            LibraryGridPane(
                section: .allComics,
                title: "All Comics",
                emptyTitle: "Your library is empty",
                emptyHint: "Open a comic or create a gallery from one or more folders.",
                sourceURLs: library.allComicURLs,
                debugMode: $debugMode
            )
        case .gallery(let id):
            if let gallery = library.galleries.first(where: { $0.id == id }) {
                LibraryGalleryPane(gallery: gallery, debugMode: $debugMode)
            } else {
                // The selected gallery was deleted or never existed. Snap the
                // sidebar back to Home so the user isn't stuck on a dead pane.
                Color.clear
                    .onAppear { library.selectedSection = .home }
            }
        }
    }
}

// MARK: - LibraryGridPane (generic grid for Favorites/Recents/All)

struct LibraryGridPane: View {
    @EnvironmentObject var library: LibraryViewModel

    let section: LibrarySection
    let title: String
    let emptyTitle: String
    let emptyHint: String
    let sourceURLs: [URL]
    @Binding var debugMode: Bool

    @State private var selectedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(section: section, title: title, debugMode: $debugMode)
            Divider()
            if filteredURLs.isEmpty {
                EmptyPane(title: emptyTitle, hint: emptyHint)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredURLs, id: \.self) { url in
                            let titleStr = url.deletingPathExtension().lastPathComponent
                            ComicCard(
                                url: url,
                                title: titleStr,
                                readingProgress: progress(for: url),
                                cardSize: library.cardSize,
                                isSelected: selectedURL == url
                            )
                            .onTapGesture(count: 2) { Task { await library.load(url: url) } }
                            .onTapGesture { selectedURL = url }
                            .contextMenu {
                                Button("Open") { Task { await library.load(url: url) } }
                                Divider()
                                Button(removeLabel, role: .destructive) {
                                    remove(url)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                // Background click clears selection so users can escape without pressing escape.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedURL = nil }
                )
            }
        }
        // Invisible button binds the Delete key. Disabled when nothing is selected.
        .background(deleteShortcutButton)
    }

    private var deleteShortcutButton: some View {
        Button {
            if let url = selectedURL { remove(url) }
        } label: { EmptyView() }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(selectedURL == nil)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var removeLabel: String {
        switch section {
        case .favorites: return "Remove from Favorites"
        case .recents:   return "Remove from Recents"
        case .allComics: return "Remove from Library"
        default:         return "Remove"
        }
    }

    private func remove(_ url: URL) {
        switch section {
        case .favorites:
            library.toggleFavorite(url: url)
        case .recents:
            if let recent = library.recentComics.first(where: { $0.url == url }) {
                library.removeRecent(recent)
            }
        case .allComics:
            library.removeFromLibrary(url: url)
        default:
            break
        }
        if selectedURL == url { selectedURL = nil }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: library.cardSize.minimum,
                            maximum: library.cardSize.maximum), spacing: 16)]
    }

    private func progress(for url: URL) -> Double? {
        library.recentComics.first(where: { $0.url == url })?.readingProgress
    }

    private var filteredURLs: [URL] {
        let order = library.sortOrder(for: section)
        let filtered: [URL]
        if library.searchQuery.isEmpty {
            filtered = sourceURLs
        } else {
            let q = library.searchQuery
            filtered = sourceURLs.filter {
                $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveContains(q)
            }
        }
        return LibrarySort.apply(order, to: filtered, library: library)
    }
}

// MARK: - LibraryGalleryPane (gallery-specific grid with drag-reorder)

struct LibraryGalleryPane: View {
    @EnvironmentObject var library: LibraryViewModel
    let gallery: Gallery
    @Binding var debugMode: Bool

    @State private var selectedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(
                section: .gallery(gallery.id),
                title: gallery.name,
                debugMode: $debugMode,
                trailing: {
                    Button {
                        pickComicsOrFolders { urls in addToGallery(urls) }
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                    }
                    .help("Add comics or folders to this gallery")
                }
            )
            Divider()

            if gallery.comics.isEmpty {
                EmptyPane(
                    title: "Empty Gallery",
                    hint: "Add comic files or folders to populate this gallery.",
                    actionLabel: "Add Comics or Folders…",
                    action: { pickComicsOrFolders { urls in addToGallery(urls) } }
                )
            } else if library.sortOrder(for: .gallery(gallery.id)) == .manual
                      && library.searchQuery.isEmpty {
                ScrollView {
                    DraggableComicGrid(
                        gallery: gallery,
                        columns: columns,
                        selectedURL: $selectedURL
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .background(
                    Color.clear.contentShape(Rectangle()).onTapGesture { selectedURL = nil }
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(sortedFilteredURLs, id: \.self) { url in
                            let title = url.deletingPathExtension().lastPathComponent
                            ComicCard(
                                url: url,
                                title: title,
                                readingProgress: nil,
                                cardSize: library.cardSize,
                                isSelected: selectedURL == url
                            )
                            .onTapGesture(count: 2) { Task { await library.load(url: url) } }
                            .onTapGesture { selectedURL = url }
                            .contextMenu {
                                Button("Open") { Task { await library.load(url: url) } }
                                Divider()
                                Button("Remove from Gallery", role: .destructive) {
                                    remove(url)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .background(
                    Color.clear.contentShape(Rectangle()).onTapGesture { selectedURL = nil }
                )
            }
        }
        .background(deleteShortcutButton)
    }

    private var deleteShortcutButton: some View {
        Button {
            if let url = selectedURL { remove(url) }
        } label: { EmptyView() }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(selectedURL == nil)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func remove(_ url: URL) {
        library.removeComics([url], from: gallery.id)
        if selectedURL == url { selectedURL = nil }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: library.cardSize.minimum,
                            maximum: library.cardSize.maximum), spacing: 16)]
    }

    private var sortedFilteredURLs: [URL] {
        let q = library.searchQuery
        let filtered: [URL] = q.isEmpty
            ? gallery.comics
            : gallery.comics.filter {
                $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveContains(q)
            }
        let order = library.sortOrder(for: .gallery(gallery.id))
        return LibrarySort.apply(order, to: filtered, library: library)
    }

    /// Unified picker: files + folders + multi-select. Returns the raw URL
    /// list; `addToGallery` is responsible for splitting files vs folders.
    private func pickComicsOrFolders(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Add to Gallery"
        panel.message = "Choose comic files and/or folders."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.pdf]
            + ["cbz", "cbr", "cb7", "cbt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { completion(panel.urls) }
    }

    /// Splits a raw URL list from the unified picker into files vs folders
    /// and routes each through the appropriate LibraryViewModel method.
    private func addToGallery(_ urls: [URL]) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        if !folders.isEmpty { library.addFolders(folders, to: gallery.id) }
        if !files.isEmpty   { library.addComicFiles(files, to: gallery.id) }
    }
}

// MARK: - PaneToolbar (per-pane toolbar: title, search, zoom, sort)

struct PaneToolbar<Trailing: View>: View {
    @EnvironmentObject var library: LibraryViewModel
    let section: LibrarySection
    let title: String
    @Binding var debugMode: Bool
    @ViewBuilder let trailing: () -> Trailing

    init(section: LibrarySection, title: String,
         debugMode: Binding<Bool>,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.section = section
        self.title = title
        self._debugMode = debugMode
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title2.bold())
            Text("\(countForSection)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            Spacer(minLength: 12)

            searchField
            sortMenu
            zoomStepper
            trailing()

            Divider().frame(height: 18)

            Button {
                debugMode.toggle()
            } label: {
                Image(systemName: debugMode ? "memorychip.fill" : "memorychip")
                    .foregroundStyle(debugMode ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(debugMode ? "Disable memory debug" : "Enable memory debug")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var countForSection: Int {
        switch section {
        case .home:        return library.totalComics
        case .favorites:   return library.favoriteURLs.count
        case .recents:     return library.recentComics.count
        case .allComics:   return library.allComicURLs.count
        case .gallery(let id):
            return library.galleries.first(where: { $0.id == id })?.comics.count ?? 0
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search", text: $library.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
            if !library.searchQuery.isEmpty {
                Button {
                    library.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSorts, id: \.self) { order in
                Button {
                    library.setSortOrder(order, for: section)
                } label: {
                    let current = library.sortOrder(for: section)
                    Label(order.label,
                          systemImage: order == current ? "checkmark" : "")
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("Sort: \(library.sortOrder(for: section).label)")
    }

    private var availableSorts: [LibrarySortOrder] {
        // "Custom Order" only meaningful for galleries.
        if case .gallery = section {
            return LibrarySortOrder.allCases
        }
        return LibrarySortOrder.allCases.filter { $0 != .manual }
    }

    private var zoomStepper: some View {
        Menu {
            ForEach(CardSize.allCases, id: \.self) { size in
                Button {
                    library.cardSize = size
                } label: {
                    Label(sizeLabel(size),
                          systemImage: library.cardSize == size ? "checkmark" : "")
                }
            }
        } label: {
            Label("Size", systemImage: zoomIcon)
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("Card size: \(sizeLabel(library.cardSize))")
    }

    private var zoomIcon: String {
        switch library.cardSize {
        case .small:      return "square.grid.4x3.fill"
        case .medium:     return "square.grid.3x3.fill"
        case .large:      return "square.grid.2x2.fill"
        case .extraLarge: return "square.fill"
        }
    }

    private func sizeLabel(_ s: CardSize) -> String {
        switch s {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
}

// MARK: - EmptyPane

struct EmptyPane: View {
    let title: String
    let hint: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            Image(systemName: "book.closed")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(hint)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Sorting

enum LibrarySort {
    /// Main-actor-confined mtime cache. Avoids thousands of synchronous
    /// `FileManager.attributesOfItem` stats on every re-render when sorting
    /// by Recently Added. Values persist for the lifetime of the process;
    /// file modification time is effectively static for the comic library
    /// during a session, so a process-lifetime cache is safe.
    @MainActor private static var mtimeCache: [URL: Date] = [:]

    @MainActor
    static func apply(_ order: LibrarySortOrder,
                      to urls: [URL],
                      library: LibraryViewModel) -> [URL] {
        switch order {
        case .manual:
            return urls
        case .alphabetical:
            return urls.sorted {
                $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveCompare(
                        $1.deletingPathExtension().lastPathComponent
                    ) == .orderedAscending
            }
        case .recentlyAdded:
            return urls.sorted { lhs, rhs in
                (mtime(lhs) ?? .distantPast) > (mtime(rhs) ?? .distantPast)
            }
        case .recentlyRead:
            let recentOrder = Dictionary(
                uniqueKeysWithValues: library.recentComics.enumerated()
                    .map { ($0.element.url, $0.offset) }
            )
            return urls.sorted {
                (recentOrder[$0] ?? .max) < (recentOrder[$1] ?? .max)
            }
        case .progress:
            let progressByURL: [URL: Double] = Dictionary(
                uniqueKeysWithValues: library.recentComics.compactMap { recent in
                    recent.readingProgress.map { (recent.url, $0) }
                }
            )
            return urls.sorted {
                (progressByURL[$0] ?? -1) < (progressByURL[$1] ?? -1)
            }
        case .format:
            return urls.sorted {
                $0.pathExtension.lowercased() < $1.pathExtension.lowercased()
            }
        }
    }

    @MainActor
    private static func mtime(_ url: URL) -> Date? {
        if let cached = mtimeCache[url] { return cached }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let date { mtimeCache[url] = date }
        return date
    }
}

// MARK: - Home view (hero + rails)

struct LibraryHome: View {
    @EnvironmentObject var library: LibraryViewModel
    @Binding var debugMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(section: .home, title: "Home", debugMode: $debugMode)
            Divider()
            content
        }
    }

    private var content: some View {
        // Hoisted out of the `if let` below so the Continue Reading rail
        // can filter the same URL out of its list — it would otherwise
        // duplicate the comic shown in the Hero card directly above it.
        let resumeURL = library.continueReadingURL()
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let resumeURL {
                    ContinueReadingHero(url: resumeURL)
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                } else {
                    WelcomeHero()
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                }

                let continueReadingURLs = library.recentComics
                    .filter { $0.url != resumeURL }
                    .prefix(12)
                    .map { $0.url }
                if !continueReadingURLs.isEmpty {
                    Rail(
                        title: "Continue Reading",
                        urls: Array(continueReadingURLs),
                        progressLookup: { url in
                            library.recentComics.first(where: { $0.url == url })?.readingProgress
                        },
                        seeAllSection: .recents
                    )
                }

                if !recentlyAdded.isEmpty {
                    Rail(
                        title: "Recently Added",
                        urls: recentlyAdded,
                        progressLookup: { _ in nil },
                        seeAllSection: .allComics
                    )
                }

                if !library.favoriteURLs.isEmpty {
                    Rail(
                        title: "Favorites",
                        urls: Array(library.favoriteURLs.prefix(12)),
                        progressLookup: { _ in nil },
                        seeAllSection: .favorites
                    )
                }

                Spacer(minLength: 40)
            }
        }
    }

    private var recentlyAdded: [URL] {
        // Take all comic URLs and sort by file mtime, top 12.
        let sorted = LibrarySort.apply(.recentlyAdded, to: library.allComicURLs, library: library)
        return Array(sorted.prefix(12))
    }
}

// MARK: - ContinueReadingHero

struct ContinueReadingHero: View {
    @EnvironmentObject var library: LibraryViewModel
    let url: URL

    @State private var renderToken = UUID()

    var body: some View {
        let _ = renderToken
        let thumb = library.cachedThumbnail(for: url)
        let title = url.deletingPathExtension().lastPathComponent
        let progress = library.recentComics.first(where: { $0.url == url })?.readingProgress

        HStack(alignment: .center, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    Image(systemName: "book.pages")
                        .font(.system(size: 52))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 180, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 10) {
                Text("Continue Reading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(title)
                    .font(.title.bold())
                    .lineLimit(2)
                    .truncationMode(.tail)

                if let progress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 240)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await library.load(url: url) }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        library.toggleFavorite(url: url)
                    } label: {
                        Image(systemName: library.isFavorite(url: url) ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(library.isFavorite(url: url) ? "Remove from Favorites" : "Add to Favorites")
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        // contentShape so clicks on the transparent areas of the HStack
        // (between thumbnail and text, around the Spacer) hit-test as
        // part of the gesture target rather than passing through to the
        // ScrollView underneath. The Resume / Favorite buttons inside
        // the HStack still own their own tap — SwiftUI dispatches button
        // taps before parent .onTapGesture, so single-clicking Resume
        // still loads, single-clicking the heart still toggles favourite.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { await library.load(url: url) }
        }
        .onAppear { library.requestThumbnail(for: url) }
        .onReceive(library.thumbnailUpdates) { updatedURL in
            if updatedURL == url { renderToken = UUID() }
        }
    }
}

struct WelcomeHero: View {
    @EnvironmentObject var library: LibraryViewModel

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 68))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Open Comic")
                    .font(.title.bold())
                Text("Open a CBZ, CBR, CB7, CBT, or PDF — or create a gallery to organise a folder of comics.")
                    .foregroundStyle(.secondary)
                    .font(.body)
                HStack(spacing: 8) {
                    Button("Open Comic…") { library.openFilePicker() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Rail (horizontal card strip)

struct Rail: View {
    @EnvironmentObject var library: LibraryViewModel
    let title: String
    let urls: [URL]
    let progressLookup: (URL) -> Double?
    let seeAllSection: LibrarySection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.title3.bold())
                Spacer()
                Button("See All") { library.selectedSection = seeAllSection }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(urls, id: \.self) { url in
                        let cardTitle = url.deletingPathExtension().lastPathComponent
                        ComicCard(
                            url: url,
                            title: cardTitle,
                            readingProgress: progressLookup(url),
                            cardSize: .medium
                        )
                        .frame(width: CardSize.medium.minimum)
                        .onTapGesture { Task { await library.load(url: url) } }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - LoadingOverlay

struct LoadingOverlay: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Opening comic…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
    }
}

// MARK: - ErrorBanner

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 20)
    }
}

// MARK: - DebugMemoryBar

struct DebugMemoryBar: View {
    @ObservedObject var monitor: MemoryMonitor

    var body: some View {
        HStack(spacing: 16) {
            Label(monitor.residentFormatted, systemImage: "memorychip")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
            Divider().frame(height: 14)
            Label("\(monitor.cacheCount) cached", systemImage: "photo.stack")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Label("\(monitor.diskCount) on disk", systemImage: "internaldrive")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(monitor.lastSampleTime.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var color: Color {
        let mb = Double(monitor.residentBytes) / (1024 * 1024)
        if mb < 300 { return .green }
        if mb < 700 { return .yellow }
        return .red
    }
}

// MARK: - Draggable Comic Grid (preserved from previous library)

/// A grid of comic cards for a single gallery that supports drag-to-reorder.
struct DraggableComicGrid: View {
    let gallery: Gallery
    let columns: [GridItem]
    @Binding var selectedURL: URL?

    @EnvironmentObject var library: LibraryViewModel
    @State private var draggingURL: URL? = nil

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(gallery.comics, id: \.self) { url in
                let title = url.deletingPathExtension().lastPathComponent
                ComicCard(
                    url: url,
                    title: title,
                    readingProgress: nil,
                    cardSize: library.cardSize,
                    isSelected: selectedURL == url
                )
                .id(url)
                .opacity(draggingURL == url ? 0.4 : 1.0)
                .onDrag {
                    draggingURL = url
                    return NSItemProvider(object: url as NSURL)
                }
                .onDrop(
                    of: [.fileURL],
                    delegate: ComicDropDelegate(
                        target: url,
                        gallery: gallery,
                        library: library,
                        draggingURL: $draggingURL
                    )
                )
                .onTapGesture(count: 2) { Task { await library.load(url: url) } }
                .onTapGesture { selectedURL = url }
                .contextMenu {
                    Button("Open") { Task { await library.load(url: url) } }
                    Divider()
                    Button("Remove from Gallery", role: .destructive) {
                        library.removeComics([url], from: gallery.id)
                        if selectedURL == url { selectedURL = nil }
                    }
                    Divider()
                    Button("Reset to Alphabetical Order") {
                        library.resetGalleryOrder(id: gallery.id)
                    }
                }
            }
        }
    }
}

private struct ComicDropDelegate: DropDelegate {
    let target: URL
    let gallery: Gallery
    let library: LibraryViewModel
    @Binding var draggingURL: URL?

    func dropEntered(info: DropInfo) {
        guard let src = draggingURL, src != target else { return }
        guard let fromIdx = gallery.comics.firstIndex(of: src),
              let toIdx   = gallery.comics.firstIndex(of: target) else { return }
        let destIdx = fromIdx < toIdx ? toIdx + 1 : toIdx
        library.moveComics(in: gallery.id, from: IndexSet(integer: fromIdx), to: destIdx)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingURL = nil
        return true
    }
}

// MARK: - ComicCard

struct ComicCard: View {
    let url: URL
    let title: String
    let readingProgress: Double?
    let cardSize: CardSize
    var isSelected: Bool = false

    @EnvironmentObject var library: LibraryViewModel
    @State private var renderToken: UUID = UUID()
    @State private var isHovering = false

    var body: some View {
        let _ = renderToken
        let thumbnail = library.cachedThumbnail(for: url)

        VStack(alignment: .leading, spacing: 6) {
            coverImage(thumbnail)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(isHovering ? 0.45 : 0.25),
                        radius: isHovering ? 8 : 4, x: 0, y: isHovering ? 4 : 2)
                .scaleEffect(isHovering ? 1.03 : 1.0)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let progress = readingProgress, progress > 0.02 {
                        progressBadge(progress)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    let fav = library.isFavorite(url: url)
                    if isHovering || fav {
                        Button {
                            library.toggleFavorite(url: url)
                        } label: {
                            Image(systemName: fav ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(fav ? Color.red : Color.white)
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                                .padding(7)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.12), value: isSelected)

            Text(title)
                .font(.system(size: cardSize.titleFontSize))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: cardSize.titleFontSize * 2.6, alignment: .topLeading)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear { library.requestThumbnail(for: url) }
        .onReceive(library.thumbnailUpdates) { updatedURL in
            if updatedURL == url { renderToken = UUID() }
        }
    }

    @ViewBuilder
    private func coverImage(_ img: NSImage?) -> some View {
        if let img {
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
                .fill(.black.opacity(0.65))
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

    @State private var galleryName: String = ""
    @State private var selectedFolders: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Gallery")
                .font(.title2.bold())

            Form {
                TextField("Gallery Name", text: $galleryName)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Source Folders")
                        Spacer()
                        Button("Add Folder…") { pickFolders() }
                            .buttonStyle(.bordered)
                    }
                    if selectedFolders.isEmpty {
                        Text("No folders selected")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(selectedFolders, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(url.path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    selectedFolders.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    library.createGallery(name: galleryName.trimmingCharacters(in: .whitespaces),
                                          folders: selectedFolders)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(galleryName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for u in panel.urls where !selectedFolders.contains(u) {
                selectedFolders.append(u)
            }
        }
    }
}

// MARK: - Rename Gallery Sheet

struct RenameGallerySheet: View {
    let gallery: Gallery
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Gallery")
                .font(.title2.bold())
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCommit() }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Rename") { onCommit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
