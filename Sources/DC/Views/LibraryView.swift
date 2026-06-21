import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LibraryView (NavigationSplitView shell)

struct LibraryView: View {
    @EnvironmentObject var library: LibraryViewModel
    @StateObject private var memoryMonitor = MemoryMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) {
            if let error = library.errorMessage {
                ErrorBanner(message: error) { library.errorMessage = nil }
                    .padding(.top, 12)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if library.isLoading {
                LoadingOverlay()
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: library.isLoading)
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
                    .transition(reduceMotion ? .identity : .opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDropTargeted)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: debugMode)
        .modifier(CompressionSheetsModifier(
            library: library,
            service: library.compressionService
        ))
    }

    private func handleLibraryDrop(providers: [NSItemProvider]) -> Bool {
        // Eagerly accept any drop that claims to be a file URL — the real
        // extension check happens in the async callback and imports the comic.
        // Returning the async result would always be `false` because this
        // method returns before the callback fires, which made SwiftUI show a
        // rejection cursor even though the load actually proceeded.
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else {
            return false
        }
        let count = providers.count
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let ext = url.pathExtension.lowercased()
                guard LibraryView.comicExtensions.contains(ext) else {
                    Task { @MainActor in
                        library.errorMessage = "\u{201C}\(url.lastPathComponent)\u{201D} isn\u{2019}t a supported comic format. Open Comic reads CBZ, CBR, CB7, CBT, and PDF."
                    }
                    return
                }
                Task { @MainActor in
                    library.importComics([url])
                    if count == 1 {
                        await library.load(url: url)
                    }
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
            Section("Library") {
                SidebarRow(section: .allComics, systemImage: "books.vertical",
                           title: "All Comics", count: library.totalComics)
                SidebarRow(section: .home, systemImage: "house",
                           title: "Home", count: nil)
                SidebarRow(section: .favorites, systemImage: "heart",
                           title: "Favorites", count: library.favoriteURLs.count)
                SidebarRow(section: .recents, systemImage: "clock",
                           title: "Recents", count: library.recentComics.count)
            }

            let importedGalleries = library.galleries.filter(\.isImported)
            let userGalleries = library.galleries.filter { !$0.isImported }

            if !importedGalleries.isEmpty {
                Section("Imported") {
                    ForEach(importedGalleries) { gallery in
                        SidebarRow(
                            section: .gallery(gallery.id),
                            systemImage: "tray.and.arrow.down",
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

            if !userGalleries.isEmpty {
                Section("Galleries") {
                    ForEach(userGalleries) { gallery in
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
        .disabled(gallery.isImported)
        Button("Add Folders…") {
            pickFolders { urls in library.addFolders(urls, to: gallery.id) }
        }
        if !gallery.sourceFolders.isEmpty {
            Button("Rescan Folders") {
                library.rescanGallery(id: gallery.id)
            }
        }
        Button("Reset to Alphabetical Order") {
            library.resetGalleryOrder(id: gallery.id)
        }
        Divider()
        Button("Compress Gallery…") {
            library.requestCompressGallery(gallery.id)
        }
        .disabled(gallery.comics.isEmpty)
        Divider()
        Button("Delete Gallery", role: .destructive) {
            library.deleteGallery(id: gallery.id)
        }
        .disabled(gallery.isImported)
    }

    private func handleDrop(providers: [NSItemProvider], galleryID: UUID) -> Bool {
        // Eagerly accept any drop that claims to be a file URL — the real
        // routing (import vs relocate) happens in the async callback.
        // Returning the async result sync always produced `false`, showing a
        // rejection cursor despite the operation succeeding.
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else {
            return false
        }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    // Guard: only accept recognised comic types.
                    let ext = url.pathExtension.lowercased()
                    guard LibraryViewModel.comicExtensions.contains(ext) else {
                        library.errorMessage = "\u{201C}\(url.lastPathComponent)\u{201D} isn\u{2019}t a supported comic format. Open Comic reads CBZ, CBR, CB7, CBT, and PDF."
                        return
                    }
                    // Route: already in the library → relocate; brand-new file → import.
                    if LibraryViewModel.isInLibrary(url, galleries: library.galleries) {
                        library.moveComic(url, toGallery: galleryID)
                    } else {
                        library.addComicFiles([url], to: galleryID)
                        library.generateThumbnails(for: [url])
                    }
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
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .tag(section)
        .accessibilityLabel(count != nil && count! > 0 ? "\(title), \(count!) items" : title)
    }
}

// MARK: - SearchScope

enum SearchScope: String, CaseIterable {
    case allLibrary = "All Library"
    case thisSection = "This Section"
}

// MARK: - LibraryDetail (router + single native toolbar)

struct LibraryDetail: View {
    @EnvironmentObject var library: LibraryViewModel
    @Binding var debugMode: Bool
    @State private var searchScope: SearchScope = .allLibrary

    init(debugMode: Binding<Bool>) {
        self._debugMode = debugMode
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.libraryFilter.isActive {
                filterChipRow
            }
            currentPane
                .overlay(alignment: .top) {
                    if !library.searchQuery.isEmpty {
                        SearchResultsOverlay(scope: $searchScope)
                    }
                }
            if library.selection.count >= 1 {
                BatchActionBar(section: currentSection, isSearching: isSearching)
            }
        }
        .onChange(of: library.searchQuery) { _, newValue in
            if newValue.isEmpty {
                library.clearSelection()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addComicsOrFolders()
                } label: {
                    Label("Add Comics or Folders", systemImage: "plus.circle")
                }
                .help("Add comics or folders")
                .accessibilityLabel("Add comics or folders")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.selectMode.toggle()
                } label: {
                    Label(library.selectMode ? "Done" : "Select",
                          systemImage: library.selectMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .labelStyle(.iconOnly)
                }
                .help(library.selectMode ? "Exit Select mode" : "Select comics")
                .accessibilityLabel(library.selectMode ? "Exit Select mode" : "Select comics")
                .accessibilityValue(library.selectMode ? "On" : "Off")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                sortMenu
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                cardSizeMenu
            }
            #if DEBUG
            ToolbarItem(placement: .automatic) {
                Button {
                    debugMode.toggle()
                } label: {
                    Image(systemName: debugMode ? "memorychip.fill" : "memorychip")
                        .foregroundStyle(debugMode ? .orange : .secondary)
                }
                .help(debugMode ? "Disable memory debug" : "Enable memory debug")
                .accessibilityLabel("Memory usage")
                .accessibilityValue(debugMode ? "On" : "Off")
            }
            #endif
        }
        .searchable(text: $library.searchQuery, placement: .toolbar, prompt: "Search")
        .toolbar(library.openComic == nil ? .automatic : .hidden, for: .windowToolbar)
        .background(
            Group {
                Button {
                    let urls = isSearching ? searchResultURLs(scope: searchScope) : visibleURLsForCurrentSection
                    library.selection = Set(urls)
                    if let first = urls.first { library.selectionAnchor = first }
                } label: { EmptyView() }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)

                Button {
                    deleteSelection()
                } label: { EmptyView() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(library.selection.isEmpty)
                .opacity(0)
                .accessibilityHidden(true)
            }
        )
        .onAppear { MouseModifierMonitor.shared.start() }
        .onDisappear { MouseModifierMonitor.shared.stop() }
    }

    @ViewBuilder private var currentPane: some View {
        switch library.selectedSection ?? .home {
        case .home:
            LibraryHome()
        case .favorites:
            LibraryGridPane(
                section: .favorites,
                title: "Favorites",
                emptyTitle: "No favorites yet",
                emptyHint: "Tap the heart on any comic to favorite it.",
                sourceURLs: library.favoriteURLs
            )
        case .recents:
            LibraryGridPane(
                section: .recents,
                title: "Recents",
                emptyTitle: "No recent comics",
                emptyHint: "Open a comic to start a recent list.",
                sourceURLs: library.recentComics.map { $0.url }
            )
        case .allComics:
            LibraryGridPane(
                section: .allComics,
                title: "All Comics",
                emptyTitle: "Your library is empty",
                emptyHint: "Open a comic or create a gallery from one or more folders.",
                sourceURLs: library.allComicURLs
            )
        case .gallery(let id):
            if let gallery = library.galleries.first(where: { $0.id == id }) {
                LibraryGalleryPane(gallery: gallery)
            } else {
                // The selected gallery was deleted or never existed. Snap the
                // sidebar back to Home so the user isn't stuck on a dead pane.
                Color.clear
                    .onAppear { library.selectedSection = .home }
            }
        }
    }

    private var isSearching: Bool {
        !library.searchQuery.isEmpty
    }

    private var currentSection: LibrarySection {
        library.selectedSection ?? .home
    }

    /// The ordered URL list that the search-results overlay shows for a given scope.
    /// Shared between the overlay's ForEach and the ⌘A handler so they always agree.
    private func searchResultURLs(scope: SearchScope) -> [URL] {
        let corpus: [URL]
        switch scope {
        case .allLibrary:
            corpus = library.allComicURLs
        case .thisSection:
            switch currentSection {
            case .home:        corpus = library.allComicURLs
            case .favorites:   corpus = library.favoriteURLs
            case .recents:     corpus = library.recentComics.map { $0.url }
            case .allComics:   corpus = library.allComicURLs
            case .gallery(let id):
                corpus = library.galleries.first(where: { $0.id == id })?.comics ?? []
            }
        }
        let isGlobal = scope == .allLibrary
        return library.displayURLs(corpus: corpus, section: currentSection, isGlobalSearch: isGlobal)
    }

    private var visibleURLsForCurrentSection: [URL] {
        switch currentSection {
        case .home:
            return library.allComicURLs
        case .favorites:
            return library.displayURLs(corpus: library.favoriteURLs, section: .favorites, isGlobalSearch: false)
        case .recents:
            return library.displayURLs(corpus: library.recentComics.map { $0.url }, section: .recents, isGlobalSearch: false)
        case .allComics:
            return library.displayURLs(corpus: library.allComicURLs, section: .allComics, isGlobalSearch: false)
        case .gallery(let id):
            let comics = library.galleries.first(where: { $0.id == id })?.comics ?? []
            return library.displayURLs(corpus: comics, section: currentSection, isGlobalSearch: false)
        }
    }

    private func deleteSelection() {
        let urls = library.selection
        guard !urls.isEmpty else { return }
        if isSearching {
            // While searching the selection can span multiple galleries — always
            // use the library-wide remove so nothing is left in a stale gallery.
            library.removeFromLibraryBatch(urls)
        } else {
            switch currentSection {
            case .favorites:
                for url in urls {
                    if library.isFavorite(url: url) { library.toggleFavorite(url: url) }
                }
            case .recents:
                for url in urls {
                    if let recent = library.recentComics.first(where: { $0.url == url }) {
                        library.removeRecent(recent)
                    }
                }
            case .allComics:
                for url in urls { library.removeFromLibrary(url: url) }
            case .gallery(let id):
                library.removeComics(urls, from: id)
            case .home:
                break
            }
        }
        library.clearSelection()
    }

    private var availableSorts: [LibrarySortOrder] {
        if case .gallery = currentSection {
            return LibrarySortOrder.allCases
        }
        return LibrarySortOrder.allCases.filter { $0 != .manual }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSorts, id: \.self) { order in
                Button {
                    library.setSortOrder(order, for: currentSection)
                } label: {
                    let current = library.sortOrder(for: currentSection)
                    Label(order.label, systemImage: order == current ? "checkmark" : "")
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .help("Sort: \(library.sortOrder(for: currentSection).label)")
        .accessibilityLabel("Sort")
    }

    private var cardSizeMenu: some View {
        Menu {
            ForEach(CardSize.allCases, id: \.self) { size in
                Button {
                    library.cardSize = size
                } label: {
                    Label(cardSizeLabel(size), systemImage: library.cardSize == size ? "checkmark" : "")
                }
            }
        } label: {
            Label("Card Size", systemImage: cardSizeIcon)
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .help("Card size: \(cardSizeLabel(library.cardSize))")
        .accessibilityLabel("Card size")
    }

    private var cardSizeIcon: String {
        switch library.cardSize {
        case .small:      return "square.grid.4x3.fill"
        case .medium:     return "square.grid.3x3.fill"
        case .large:      return "square.grid.2x2.fill"
        case .extraLarge: return "square.fill"
        }
    }

    private func cardSizeLabel(_ s: CardSize) -> String {
        switch s {
        case .small:      return "Small"
        case .medium:     return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    private func addComicsOrFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add to Library"
        panel.message = "Choose comic files and/or folders."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.pdf]
            + ["cbz", "cbr", "cb7", "cbt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            let galleryID: UUID? = {
                if case .gallery(let id) = library.selectedSection { return id }
                return nil
            }()
            library.addComicsOrFolders(panel.urls, toGallery: galleryID)
        }
    }

    // MARK: - Filter menu + chip row

    private var filterMenu: some View {
        Menu {
            Section("Status") {
                ForEach(StatusFilter.allCases, id: \.self) { sf in
                    Button {
                        library.libraryFilter.status = sf
                    } label: {
                        Label(statusLabel(sf),
                              systemImage: library.libraryFilter.status == sf ? "checkmark" : "")
                    }
                }
            }
            Section {
                Button {
                    library.libraryFilter.favoritedOnly.toggle()
                } label: {
                    Label("Favorited Only",
                          systemImage: library.libraryFilter.favoritedOnly ? "checkmark" : "")
                }
            }
            Section("Format") {
                ForEach(["cbz", "cbr", "cb7", "cbt", "pdf"], id: \.self) { fmt in
                    Button {
                        if library.libraryFilter.formats.contains(fmt) {
                            library.libraryFilter.formats.remove(fmt)
                        } else {
                            library.libraryFilter.formats.insert(fmt)
                        }
                    } label: {
                        Label(fmt.uppercased(),
                              systemImage: library.libraryFilter.formats.contains(fmt) ? "checkmark" : "")
                    }
                }
            }
            if library.libraryFilter.isActive {
                Divider()
                Button("Clear Filters", role: .destructive) {
                    library.libraryFilter = LibraryFilter()
                }
            }
        } label: {
            Label("Filter", systemImage: library.libraryFilter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(library.libraryFilter.isActive ? Color.accentColor : Color.primary)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .help(library.libraryFilter.isActive ? "Filters active" : "Filter")
        .accessibilityLabel("Filter")
    }

    private var filterChipRow: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if library.libraryFilter.status != .all {
                        FilterChip(label: statusLabel(library.libraryFilter.status)) {
                            library.libraryFilter.status = .all
                        }
                    }
                    if library.libraryFilter.favoritedOnly {
                        FilterChip(label: "Favorited") {
                            library.libraryFilter.favoritedOnly = false
                        }
                    }
                    ForEach(Array(library.libraryFilter.formats).sorted(), id: \.self) { fmt in
                        FilterChip(label: fmt.uppercased()) {
                            library.libraryFilter.formats.remove(fmt)
                        }
                    }
                    Button("Clear All") {
                        library.libraryFilter = LibraryFilter()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider()
        }
        .background(.bar)
    }

    private func statusLabel(_ sf: StatusFilter) -> String {
        switch sf {
        case .all:        return "All"
        case .unread:     return "Unread"
        case .inProgress: return "In Progress"
        case .finished:   return "Finished"
        }
    }
}

// MARK: - BatchActionBar

private struct BatchActionBar: View {
    @EnvironmentObject var library: LibraryViewModel
    let section: LibrarySection
    let isSearching: Bool

    @State private var showRemoveConfirm = false

    private var count: Int { library.selection.count }
    private var urls: Set<URL> { library.selection }

    private var allCBZ: Bool {
        urls.allSatisfy { $0.pathExtension.lowercased() == "cbz" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("\(count) selected")
                        .font(.subheadline.weight(.medium))
                        .accessibilityLabel("\(count) comic\(count == 1 ? "" : "s") selected")
                    Button {
                        library.clearSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear selection")
                }

                Divider().frame(height: 18)

                Button {
                    library.favorite(urls)
                    library.clearSelection()
                } label: {
                    Label("Favorite", systemImage: "heart")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Toggle favorite for selected comics")

                Menu {
                    Button("Mark as Finished") {
                        for url in urls {
                            ReadingPositionStore.setReadStatusOverride(.finished, for: url)
                            library.statusUpdates.send(url)
                        }
                        library.clearSelection()
                    }
                    Button("Mark as Unread") {
                        for url in urls {
                            ReadingPositionStore.setReadStatusOverride(.unread, for: url)
                            library.statusUpdates.send(url)
                        }
                        library.clearSelection()
                    }
                    Button("Mark as Auto") {
                        for url in urls {
                            ReadingPositionStore.setReadStatusOverride(nil, for: url)
                            library.statusUpdates.send(url)
                        }
                        library.clearSelection()
                    }
                } label: {
                    Label("Mark as", systemImage: "bookmark")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .controlSize(.small)
                .help("Change read status of selected comics")

                if !library.galleries.isEmpty {
                    Menu {
                        ForEach(library.galleries) { gallery in
                            Button(gallery.name) {
                                library.move(urls, toGallery: gallery.id)
                                library.clearSelection()
                            }
                        }
                    } label: {
                        Label("Move to Gallery", systemImage: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .controlSize(.small)
                    .help("Move selected comics to a gallery")
                }

                if !library.galleries.isEmpty {
                    Menu {
                        ForEach(library.galleries) { gallery in
                            Button(gallery.name) {
                                library.addToGallery(urls, gallery.id)
                                library.clearSelection()
                            }
                        }
                    } label: {
                        Label("Add to Gallery", systemImage: "plus.rectangle.on.folder")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .controlSize(.small)
                    .help("Add selected comics to a gallery (without moving)")
                }

                Menu {
                    removeMenuItems
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .controlSize(.small)
                .help("Remove selected comics")

                Button {
                    library.requestCompressSelection(urls)
                } label: {
                    Label("Compress", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!allCBZ)
                .help(allCBZ
                      ? "Compress selected CBZ files"
                      : "Compress is only available when all selected comics are CBZ")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .accessibilityLabel("Batch actions for \(count) selected comic\(count == 1 ? "" : "s")")
        .alert("Remove from Library?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                library.removeFromLibraryBatch(urls)
                library.clearSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected \(count) comic\(count == 1 ? "" : "s") from your library. The files on disk are not deleted.")
        }
    }

    @ViewBuilder
    private var removeMenuItems: some View {
        if isSearching {
            // While searching the selection can span multiple galleries — only
            // offer the library-wide remove to prevent acting on the wrong scope.
            Button("Remove from Library", role: .destructive) {
                showRemoveConfirm = true
            }
        } else {
            switch section {
            case .gallery(let id):
                if let gallery = library.galleries.first(where: { $0.id == id }) {
                    Button("Remove from '\(gallery.name)'", role: .destructive) {
                        library.removeComics(urls, from: id)
                        library.clearSelection()
                    }
                }
            case .favorites:
                Button("Remove from Favorites", role: .destructive) {
                    for url in urls {
                        if library.isFavorite(url: url) { library.toggleFavorite(url: url) }
                    }
                    library.clearSelection()
                }
            case .recents:
                Button("Remove from Recents", role: .destructive) {
                    for url in urls {
                        if let recent = library.recentComics.first(where: { $0.url == url }) {
                            library.removeRecent(recent)
                        }
                    }
                    library.clearSelection()
                }
            case .allComics, .home:
                Button("Remove from Library", role: .destructive) {
                    showRemoveConfirm = true
                }
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

    init(section: LibrarySection, title: String, emptyTitle: String, emptyHint: String,
         sourceURLs: [URL]) {
        self.section = section
        self.title = title
        self.emptyTitle = emptyTitle
        self.emptyHint = emptyHint
        self.sourceURLs = sourceURLs
    }

    var body: some View {
        Group {
            if filteredURLs.isEmpty {
                EmptyPane(
                    title: emptyTitle,
                    hint: emptyHint,
                    actionLabel: "Add Comics…",
                    action: { library.openFilePicker() }
                )
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
                                isSelected: library.selection.contains(url)
                            )
                            .onTapGesture(count: 2) { Task { await library.load(url: url) } }
                            .simultaneousGesture(TapGesture().onEnded {
                                let mods = ClickModifiers(
                                    command: MouseModifierMonitor.shared.command,
                                    shift:   MouseModifierMonitor.shared.shift,
                                    selectMode: library.selectMode
                                )
                                let (newSel, newAnchor) = selectionAfterClick(
                                    current:   library.selection,
                                    anchor:    library.selectionAnchor,
                                    clicked:   url,
                                    ordered:   filteredURLs,
                                    modifiers: mods
                                )
                                library.selection       = newSel
                                library.selectionAnchor = newAnchor
                            })
                            .contextMenu {
                                Button("Open") { Task { await library.load(url: url) } }
                                Divider()
                                Button("Mark as Finished") {
                                    ReadingPositionStore.setReadStatusOverride(.finished, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Button("Mark as Unread") {
                                    ReadingPositionStore.setReadStatusOverride(.unread, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Button("Mark as Auto") {
                                    ReadingPositionStore.setReadStatusOverride(nil, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Divider()
                                Button(removeLabel, role: .destructive) {
                                    remove(url)
                                }
                                Divider()
                                Button("Compress Comic…") {
                                    library.requestCompressComic(at: url)
                                }
                                .disabled(url.pathExtension.lowercased() != "cbz")
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { library.clearSelection() }
                )
            }
        }
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
        if library.selection.contains(url) { library.clearSelection() }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: library.cardSize.minimum,
                            maximum: library.cardSize.maximum), spacing: 16)]
    }

    private func progress(for url: URL) -> Double? {
        library.recentComics.first(where: { $0.url == url })?.readingProgress
    }

    private var filteredURLs: [URL] {
        library.displayURLs(corpus: sourceURLs, section: section, isGlobalSearch: false)
    }
}

// MARK: - LibraryGalleryPane (gallery-specific grid with drag-reorder)

struct LibraryGalleryPane: View {
    @EnvironmentObject var library: LibraryViewModel
    let gallery: Gallery

    init(gallery: Gallery) {
        self.gallery = gallery
    }

    var body: some View {
        VStack(spacing: 0) {
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
                        columns: columns
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .background(
                    Color.clear.contentShape(Rectangle()).onTapGesture { library.clearSelection() }
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
                                isSelected: library.selection.contains(url)
                            )
                            .onTapGesture(count: 2) { Task { await library.load(url: url) } }
                            .simultaneousGesture(TapGesture().onEnded {
                                let mods = ClickModifiers(
                                    command: MouseModifierMonitor.shared.command,
                                    shift:   MouseModifierMonitor.shared.shift,
                                    selectMode: library.selectMode
                                )
                                let (newSel, newAnchor) = selectionAfterClick(
                                    current:   library.selection,
                                    anchor:    library.selectionAnchor,
                                    clicked:   url,
                                    ordered:   sortedFilteredURLs,
                                    modifiers: mods
                                )
                                library.selection       = newSel
                                library.selectionAnchor = newAnchor
                            })
                            .contextMenu {
                                Button("Open") { Task { await library.load(url: url) } }
                                Divider()
                                Button("Mark as Finished") {
                                    ReadingPositionStore.setReadStatusOverride(.finished, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Button("Mark as Unread") {
                                    ReadingPositionStore.setReadStatusOverride(.unread, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Button("Mark as Auto") {
                                    ReadingPositionStore.setReadStatusOverride(nil, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Divider()
                                Button("Remove from Gallery", role: .destructive) {
                                    remove(url)
                                }
                                Divider()
                                Button("Compress Comic…") {
                                    library.requestCompressComic(at: url)
                                }
                                .disabled(url.pathExtension.lowercased() != "cbz")
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .background(
                    Color.clear.contentShape(Rectangle()).onTapGesture { library.clearSelection() }
                )
            }
        }
    }

    private func remove(_ url: URL) {
        library.removeComics([url], from: gallery.id)
        if library.selection.contains(url) { library.clearSelection() }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: library.cardSize.minimum,
                            maximum: library.cardSize.maximum), spacing: 16)]
    }

    private var sortedFilteredURLs: [URL] {
        library.displayURLs(corpus: gallery.comics, section: .gallery(gallery.id), isGlobalSearch: false)
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
                .accessibilityHidden(true)
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

// MARK: - FilterChip

private struct FilterChip: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityLabel("\(label), remove filter")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - SearchResultsOverlay

struct SearchResultsOverlay: View {
    @EnvironmentObject var library: LibraryViewModel
    @Binding var scope: SearchScope

    private var currentSection: LibrarySection { library.selectedSection ?? .home }

    private var corpus: [URL] {
        switch scope {
        case .allLibrary: return library.allComicURLs
        case .thisSection:
            switch currentSection {
            case .home:        return library.allComicURLs
            case .favorites:   return library.favoriteURLs
            case .recents:     return library.recentComics.map { $0.url }
            case .allComics:   return library.allComicURLs
            case .gallery(let id):
                return library.galleries.first(where: { $0.id == id })?.comics ?? []
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: library.cardSize.minimum,
                            maximum: library.cardSize.maximum), spacing: 16)]
    }

    var body: some View {
        // M4: hoist results to a single let so the search→filter→sort pipeline
        // runs once per render (header count, empty check, and ForEach all share it).
        let results: [URL] = {
            let isGlobal = scope == .allLibrary
            return library.displayURLs(corpus: corpus, section: currentSection, isGlobalSearch: isGlobal)
        }()

        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                Text(results.isEmpty
                     ? "No results for \"\(library.searchQuery)\""
                     : "\(results.count) result\(results.count == 1 ? "" : "s") for \"\(library.searchQuery)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Picker("Scope", selection: $scope) {
                    ForEach(SearchScope.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Button {
                    library.searchQuery = ""
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if results.isEmpty {
                Spacer()
                Text("Try a different search or change the scope.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(results, id: \.self) { url in
                            ComicCard(
                                url: url,
                                title: url.deletingPathExtension().lastPathComponent,
                                readingProgress: library.recentComics.first(where: { $0.url == url })?.readingProgress,
                                cardSize: library.cardSize,
                                isSelected: library.selection.contains(url)
                            )
                            .onTapGesture(count: 2) { Task { await library.load(url: url) } }
                            .simultaneousGesture(TapGesture().onEnded {
                                let mods = ClickModifiers(
                                    command: MouseModifierMonitor.shared.command,
                                    shift:   MouseModifierMonitor.shared.shift,
                                    selectMode: library.selectMode
                                )
                                let (newSel, newAnchor) = selectionAfterClick(
                                    current:   library.selection,
                                    anchor:    library.selectionAnchor,
                                    clicked:   url,
                                    ordered:   results,
                                    modifiers: mods
                                )
                                library.selection       = newSel
                                library.selectionAnchor = newAnchor
                            })
                            // M1: full context menu on result cards, matching the panes.
                            // Remove uses the library-wide path (consistent with C1 —
                            // results can span multiple galleries).
                            .contextMenu {
                                Button("Open") { Task { await library.load(url: url) } }
                                Divider()
                                Button("Mark as Finished") {
                                    ReadingPositionStore.setReadStatusOverride(.finished, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Button("Mark as Unread") {
                                    ReadingPositionStore.setReadStatusOverride(.unread, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Button("Mark as Auto") {
                                    ReadingPositionStore.setReadStatusOverride(nil, for: url)
                                    library.statusUpdates.send(url)
                                }
                                Divider()
                                Button {
                                    library.toggleFavorite(url: url)
                                } label: {
                                    Label(library.isFavorite(url: url) ? "Remove from Favorites" : "Add to Favorites",
                                          systemImage: library.isFavorite(url: url) ? "heart.slash" : "heart")
                                }
                                Divider()
                                Button("Remove from Library", role: .destructive) {
                                    library.removeFromLibrary(url: url)
                                    if library.selection.contains(url) { library.clearSelection() }
                                }
                                Divider()
                                Button("Compress Comic…") {
                                    library.requestCompressComic(at: url)
                                }
                                .disabled(url.pathExtension.lowercased() != "cbz")
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .background(
                    Color.clear.contentShape(Rectangle()).onTapGesture { library.clearSelection() }
                )
            }
        }
        .background(.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        content
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
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "book.pages")
                        .font(.system(size: 52))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
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
                            .accessibilityLabel("Reading progress")
                            .accessibilityValue("\(Int(progress * 100)) percent")
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
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
                    .accessibilityLabel("Favorite")
                    .accessibilityValue(library.isFavorite(url: url) ? "On" : "Off")
                    .accessibilityAddTraits(library.isFavorite(url: url) ? [.isSelected] : [])
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
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to open")
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
                .accessibilityHidden(true)
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
                .accessibilityHidden(true)
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
            .accessibilityLabel("Dismiss")
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
            Divider().frame(height: 14).accessibilityHidden(true)
            Label("\(monitor.cacheCount) cached", systemImage: "photo.stack")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider().frame(height: 14).accessibilityHidden(true)
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
                    isSelected: library.selection.contains(url)
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
                .simultaneousGesture(TapGesture().onEnded {
                    let mods = ClickModifiers(
                        command: MouseModifierMonitor.shared.command,
                        shift:   MouseModifierMonitor.shared.shift,
                        selectMode: library.selectMode
                    )
                    let (newSel, newAnchor) = selectionAfterClick(
                        current:   library.selection,
                        anchor:    library.selectionAnchor,
                        clicked:   url,
                        ordered:   gallery.comics,
                        modifiers: mods
                    )
                    library.selection       = newSel
                    library.selectionAnchor = newAnchor
                })
                .contextMenu {
                    Button("Open") { Task { await library.load(url: url) } }
                    Divider()
                    Button("Mark as Finished") {
                        ReadingPositionStore.setReadStatusOverride(.finished, for: url)
                        library.statusUpdates.send(url)
                    }
                    Button("Mark as Unread") {
                        ReadingPositionStore.setReadStatusOverride(.unread, for: url)
                        library.statusUpdates.send(url)
                    }
                    Button("Mark as Auto") {
                        ReadingPositionStore.setReadStatusOverride(nil, for: url)
                        library.statusUpdates.send(url)
                    }
                    Divider()
                    Button("Remove from Gallery", role: .destructive) {
                        library.removeComics([url], from: gallery.id)
                        if library.selection.contains(url) { library.clearSelection() }
                    }
                    Divider()
                    Button("Compress Comic…") {
                        library.requestCompressComic(at: url)
                    }
                    .disabled(url.pathExtension.lowercased() != "cbz")
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

// MARK: - Mouse modifier monitor (library multi-select)

/// Captures ⌘/⇧ modifier flags at the precise mouse-DOWN moment so the card's
/// TapGesture.onEnded (which fires on mouse-UP, async) can read them reliably.
/// Reading NSEvent.modifierFlags statically in the tap handler is racy because
/// the user may have released the modifier between mouse-down and mouse-up.
/// Mirrors the KeyMonitor pattern from ReaderView.swift.
final class MouseModifierMonitor {
    static let shared = MouseModifierMonitor()
    private var monitor: Any?
    private(set) var command: Bool = false
    private(set) var shift: Bool = false
    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.command = event.modifierFlags.contains(.command)
            self?.shift   = event.modifierFlags.contains(.shift)
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        command = false
        shift   = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var titleScale: CGFloat = 1
    @State private var renderToken: UUID = UUID()
    @State private var statusToken: UUID = UUID()
    @State private var isHovering = false

    /// Effective read status, derived directly from ReadingPositionStore so
    /// gallery cards and never-opened comics report the correct state (the
    /// pane-supplied `readingProgress` is nil for those cases).
    private var cardStatus: ReadingStatus {
        let _ = statusToken   // subscribe to status-update invalidations
        return effectiveStatus(
            override: ReadingPositionStore.readStatusOverride(for: url),
            page:     ReadingPositionStore.page(for: url),
            total:    ReadingPositionStore.pageCount(for: url)
        )
    }

    var body: some View {
        let _ = renderToken
        let thumbnail = library.cachedThumbnail(for: url)
        let scaledSize = cardSize.titleFontSize * titleScale

        VStack(alignment: .leading, spacing: 6) {
            coverImage(thumbnail)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(isHovering ? 0.45 : 0.25),
                        radius: isHovering ? 8 : 4, x: 0, y: isHovering ? 4 : 2)
                .scaleEffect(reduceMotion ? 1.0 : (isHovering ? 1.03 : 1.0))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottom) {
                    statusBar(cardStatus)
                }
                .overlay(alignment: .topLeading) {
                    if library.selectMode || isSelected {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                            .padding(6)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    let fav = library.isFavorite(url: url)
                    if isHovering || fav || isSelected {
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
                        .accessibilityLabel("Favorite")
                        .accessibilityValue(fav ? "On" : "Off")
                        .accessibilityAddTraits(fav ? [.isSelected] : [])
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: library.selectMode)

            Text(title)
                .font(.system(size: scaledSize))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(height: scaledSize * 2.6, alignment: .topLeading)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel({
            var parts = [title]
            switch cardStatus {
            case .unread:
                parts.append("unread")
            case .inProgress(let f):
                parts.append("\(Int(f * 100)) percent read")
            case .finished:
                parts.append("finished")
            }
            if library.isFavorite(url: url) { parts.append("Favorited") }
            if isSelected { parts.append("selected") }
            return parts.joined(separator: ", ")
        }())
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Double-tap to open")
        .accessibilityAction { Task { await library.load(url: url) } }
        .accessibilityAction(named: "Favorite") { library.toggleFavorite(url: url) }
        .accessibilityAction(named: isSelected ? "Deselect" : "Select") { /* tap gesture handles this */ }
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear { library.requestThumbnail(for: url) }
        .onReceive(library.thumbnailUpdates) { updatedURL in
            if updatedURL == url { renderToken = UUID() }
        }
        .onReceive(library.statusUpdates) { updatedURL in
            if updatedURL == url { statusToken = UUID() }
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

    /// One-channel status indicator along the cover's bottom edge.
    /// - `.unread` → nothing (clean cover).
    /// - `.inProgress(f)` → thin accent fill bar at fraction `f`.
    /// - `.finished` → full muted bar + trailing checkmark glyph.
    @ViewBuilder
    private func statusBar(_ status: ReadingStatus) -> some View {
        switch status {
        case .unread:
            EmptyView()

        case .inProgress(let fraction):
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // track
                    Capsule()
                        .fill(Color.primary.opacity(0.18))
                        .frame(height: 4)
                    // fill
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction), height: 4)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .accessibilityHidden(true)

        case .finished:
            HStack(spacing: 4) {
                // Full muted bar
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(height: 4)
                // Checkmark glyph
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
        }
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
                                .accessibilityLabel("Remove folder")
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

// MARK: - Compression sheets

/// Wraps the two compression-related .sheet modifiers in a ViewModifier so
/// SwiftUI subscribes to the nested `CompressionService` via `@ObservedObject`.
/// Without this, `library.compressionService.state` transitions don't propagate
/// to the .sheet binding (environment-object observation doesn't chain into
/// nested observables) and the progress sheet would stick on "Idle." after the
/// Done button reset state to `.idle`.
private struct CompressionSheetsModifier: ViewModifier {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var service: CompressionService

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { library.pendingCompressionURLs != nil },
                set: { if !$0 { library.cancelPendingCompression() } }
            )) {
                CompressionPromptSheet(
                    title: library.pendingCompressionTitle,
                    detailLine: library.pendingCompressionDetail,
                    onConfirm: { delete, convertPNGs, remember in
                        library.confirmPendingCompression(
                            deleteOriginals: delete,
                            convertPNGs: convertPNGs,
                            remember: remember
                        )
                    },
                    onCancel: { library.cancelPendingCompression() }
                )
            }
            .sheet(isPresented: Binding(
                get: {
                    switch service.state {
                    case .idle: return false
                    default: return true
                    }
                },
                set: { _ in /* dismissed via the sheet's Done button */ }
            )) {
                CompressionProgressSheet(
                    service: service,
                    onDismiss: { /* state already reset by service.acknowledge() */ }
                )
            }
    }
}
