import SwiftUI

/// Reader's top-bar chrome: a transparent strip carrying three floating
/// Liquid-Glass capsules — leading (Library / prev-comic / next-comic),
/// centred transport (prev-page / page-count / next-page), and trailing
/// (favorite + ellipsis menu). On macOS 26+ the capsules use
/// real Liquid Glass via `.glassEffect(.regular.interactive(true), in:
/// .capsule)` inside one `GlassEffectContainer`; on macOS 14–25 the
/// fallback is `.ultraThinMaterial` clipped to a `Capsule()` with a
/// hairline rim. Geometry, hit targets, and behaviour are identical
/// across both paths.
struct ReaderToolbar: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel
    var onToggleFullScreen: () -> Void
    /// Bound to ReaderView's @State so it can stop/start the KeyMonitor
    /// while the Go-to-page popover is open (see Area-5 MED-2).
    @Binding var goToPageOpen: Bool

    var body: some View {
        glassContainer {
            ZStack {
                HStack(spacing: 0) {
                    // Traffic-lights gutter — 8pt more than the bare 72pt
                    // close-button origin so the leading capsule's glass
                    // rim doesn't kiss the close button's hit area.
                    Spacer().frame(width: 80)
                    LeadingCapsule(vm: vm, library: library)
                    Spacer()
                    TrailingCapsule(vm: vm,
                                    library: library,
                                    onToggleFullScreen: onToggleFullScreen)
                }
                .padding(.horizontal, 8)

                TransportCapsule(vm: vm, goToPageOpen: $goToPageOpen)
            }
            .frame(height: ReaderConstants.topBarHeight)
        }
    }

    /// Wraps the strip in a `GlassEffectContainer` on macOS 26+ so the
    /// three capsules share Liquid-Glass refraction sampling (and would
    /// morph correctly if a future revision animates `glassEffectID`
    /// between them). On older macOS this collapses to a plain `Group`
    /// — there's nothing to coordinate when the material is just
    /// `.ultraThinMaterial`.
    @ViewBuilder
    private func glassContainer<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            Group { content() }
        }
    }
}

// MARK: - Capsule wrapper

/// Material wrapper for a single toolbar capsule. Keeps the
/// availability gate in one place so the three capsules don't each
/// re-implement the macOS 26 / fallback split.
private struct ToolbarCapsule<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            // `.regular` (no `.interactive(true)`) — the buttons inside the
            // capsule have their own `.buttonStyle(.plain)` interaction, so
            // capsule-level hover/press reactivity is duplicative. It also
            // leaks hover state across `.id(comic.url)`-driven view-tree
            // rebuilds on comic switch: cursor stays in place while the
            // tree tears down + remounts, the new capsule instantly enters
            // hover, and sometimes the exit event for the now-gone old
            // capsule never fires — leaving the new capsule visually
            // stuck "highlighted" until the next mouse move.
            content
                .glassEffect(.regular, in: .capsule)
                .overlay(
                    // Defining rim — over pure black, glass has nothing to refract
                    // so the pill collapses to its contents. A white hairline rim
                    // makes the capsule self-bounding on any background.
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(0.10),
                        lineWidth: 0.5
                    )
                )
        }
    }
}

// MARK: - Hairline divider

/// 1pt vertical hairline separating segments inside a multi-button
/// capsule (transport + trailing). Sized slightly shorter than the
/// capsule so it doesn't run into the rim.
private struct SegmentDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ReaderConstants.toolbarSegmentDividerOpacity))
            .frame(width: 1, height: ReaderConstants.toolbarCapsuleHeight - 8)
            .accessibilityHidden(true)
    }
}

// MARK: - Leading capsule

private struct LeadingCapsule: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel

    var body: some View {
        ToolbarCapsule {
            HStack(spacing: 0) {
                Button {
                    vm.persistCurrentPosition()
                    library.closeComic()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Library")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: ReaderConstants.toolbarCapsuleHeight)
                }
                .buttonStyle(.plain)
                .help("Back to Library")

                SegmentDivider()

                segmentButton(
                    systemImage: "chevron.left.2",
                    disabled: library.adjacentComicURL(offset: -1) == nil,
                    help: "Previous comic (Q)",
                    accessibilityLabel: "Previous comic"
                ) {
                    vm.persistCurrentPosition()
                    library.openAdjacentComic(offset: -1,
                                              currentMode: vm.readingMode.rawValue)
                }

                SegmentDivider()

                segmentButton(
                    systemImage: "chevron.right.2",
                    disabled: library.adjacentComicURL(offset: 1) == nil,
                    help: "Next comic (E)",
                    accessibilityLabel: "Next comic"
                ) {
                    vm.persistCurrentPosition()
                    library.openAdjacentComic(offset: 1,
                                              currentMode: vm.readingMode.rawValue)
                }
            }
            .frame(height: ReaderConstants.toolbarCapsuleHeight)
            .contentShape(Rectangle())
            // Subtle glyph shadow so SF Symbols read over both black and bright art
            // (Books/TV pattern: barely perceptible but prevents washout).
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
    }

    private func segmentButton(systemImage: String,
                               disabled: Bool,
                               help: String,
                               accessibilityLabel: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 32, height: ReaderConstants.toolbarCapsuleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Transport capsule (centred)

private struct TransportCapsule: View {
    @ObservedObject var vm: ReaderViewModel
    /// Two-way binding to ReaderView's goToPageOpen state so the KeyMonitor
    /// can be stopped while the page-entry field is active.
    @Binding var goToPageOpen: Bool

    /// Raw text typed in the Go-to-page field.
    @State private var goToText: String = ""

    var body: some View {
        let isVertical = vm.readingMode == .verticalScroll
                       || vm.readingMode == .verticalDouble
        ToolbarCapsule {
            HStack(spacing: 0) {
                // Page chevron — de-emphasised (secondary tint + lower opacity)
                // now that the count button is the primary navigation affordance.
                segmentButton(
                    systemImage: vm.isRTL ? "chevron.right" : "chevron.left",
                    disabled: vm.isRTL ? (vm.currentPage >= vm.pageCount - 1 || isVertical) : (vm.currentPage == 0 || isVertical),
                    help: vm.isRTL ? "Next page (←/A)" : "Previous page (←/A)",
                    accessibilityLabel: vm.isRTL ? "Next page" : "Previous page",
                    deemphasised: true
                ) {
                    vm.isRTL ? vm.nextPage() : vm.previousPage()
                }
                SegmentDivider()
                // Tappable page count — opens the Go-to-page popover.
                Button {
                    goToText = ""
                    goToPageOpen = true
                } label: {
                    Text("\(vm.currentPage + 1) / \(vm.pageCount)")
                        .monospacedDigit()
                        .font(.callout)
                        .frame(minWidth: 72)
                        .padding(.horizontal, 8)
                        .frame(height: ReaderConstants.toolbarCapsuleHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(vm.currentPage + 1) of \(vm.pageCount)")
                .help("Go to page…")
                .popover(isPresented: $goToPageOpen, arrowEdge: .bottom) {
                    GoToPageView(vm: vm, isPresented: $goToPageOpen, text: $goToText)
                }
                SegmentDivider()
                // Page chevron — de-emphasised (matches left chevron).
                segmentButton(
                    systemImage: vm.isRTL ? "chevron.left" : "chevron.right",
                    disabled: vm.isRTL ? (vm.currentPage == 0 || isVertical) : (vm.currentPage >= vm.pageCount - 1 || isVertical),
                    help: vm.isRTL ? "Previous page (→/D)" : "Next page (→/D)",
                    accessibilityLabel: vm.isRTL ? "Previous page" : "Next page",
                    deemphasised: true
                ) {
                    vm.isRTL ? vm.previousPage() : vm.nextPage()
                }
            }
            .frame(height: ReaderConstants.toolbarCapsuleHeight)
            // Subtle glyph shadow so SF Symbols read over both black and bright art.
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
    }

    private func segmentButton(systemImage: String,
                               disabled: Bool,
                               help: String,
                               accessibilityLabel: String,
                               deemphasised: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 32, height: ReaderConstants.toolbarCapsuleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .foregroundStyle(deemphasised ? Color.secondary : Color.primary)
        .opacity(deemphasised ? 0.6 : 1.0)
    }
}

// MARK: - Trailing capsule

private struct TrailingCapsule: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel
    var onToggleFullScreen: () -> Void
    @State private var showBookmarks: Bool = false

    var body: some View {
        ToolbarCapsule {
            HStack(spacing: 0) {
                if let url = library.lastOpenedURL {
                    let fav = library.isFavorite(url: url)
                    Button {
                        library.toggleFavorite(url: url)
                    } label: {
                        Image(systemName: fav ? "heart.fill" : "heart")
                            .foregroundStyle(fav ? Color.red : Color.primary)
                            .frame(width: 32,
                                   height: ReaderConstants.toolbarCapsuleHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(fav ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel("Favorite")
                    .accessibilityValue(fav ? "On" : "Off")
                    .accessibilityAddTraits(fav ? [.isSelected] : [])
                    SegmentDivider()
                }

                // Bookmark toggle — fills when the current page is bookmarked.
                Button {
                    vm.toggleBookmarkCurrentPage()
                } label: {
                    Image(systemName: vm.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                        .frame(width: 32,
                               height: ReaderConstants.toolbarCapsuleHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("d", modifiers: .command)
                .help("Bookmark this page")
                .accessibilityLabel("Bookmark this page")
                .accessibilityValue(vm.isCurrentPageBookmarked ? "On" : "Off")
                .accessibilityAddTraits(vm.isCurrentPageBookmarked ? [.isSelected] : [])

                SegmentDivider()

                // Bookmarks list — opens a non-modal popover.
                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark.circle")
                        .frame(width: 32,
                               height: ReaderConstants.toolbarCapsuleHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show bookmarks")
                .accessibilityLabel("Show bookmarks")
                .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                    BookmarksListView(vm: vm, isPresented: $showBookmarks)
                }

                SegmentDivider()

                // Reading Mode — compact Menu: icon + abbreviated label.
                // Kept icon-only width (32pt) to avoid crowding the bar at
                // 900pt min window width (MED-4 layout risk).
                Menu {
                    ForEach(ReadingMode.allCases, id: \.self) { mode in
                        Button {
                            vm.readingMode = mode
                            vm.saveMode()
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                if vm.readingMode == mode {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityValue(vm.readingMode == mode ? "Active" : "")
                        .accessibilityAddTraits(vm.readingMode == mode ? [.isSelected] : [])
                    }
                } label: {
                    Image(systemName: readingModeIcon(vm.readingMode))
                        .frame(width: 32,
                               height: ReaderConstants.toolbarCapsuleHeight)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Reading Mode: \(vm.readingMode.rawValue)")
                .accessibilityLabel("Reading Mode")
                .accessibilityValue(vm.readingMode.rawValue)

                SegmentDivider()

                // RTL toggle — drives vm.toggleReadingDirection() so all
                // downstream consumers (page chevrons, scrubber mirroring)
                // stay consistent via vm.isRTL.
                Button {
                    vm.toggleReadingDirection()
                } label: {
                    Image(systemName: vm.isRTL ? "text.book.closed.rtl" : "text.book.closed")
                        .frame(width: 32,
                               height: ReaderConstants.toolbarCapsuleHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vm.isRTL ? "Reading Direction: Right-to-Left" : "Reading Direction: Left-to-Right")
                .accessibilityLabel("Reading Direction")
                .accessibilityValue(vm.isRTL ? "Right-to-Left" : "Left-to-Right")

                SegmentDivider()

                Menu {
                    Section("Zoom") {
                        Button("Zoom In")  { vm.zoomIn() }
                            .keyboardShortcut("=", modifiers: [.command])
                        Button("Zoom Out") { vm.zoomOut() }
                            .keyboardShortcut("-", modifiers: [.command])
                        Divider()
                        Button("Actual Size (100%)") { vm.zoomToActualSize() }
                        Button("Fit to Width") {
                            vm.fitToWidth(containerWidth: vm.containerSize.width)
                        }
                        Button("Reset Zoom") { vm.resetZoom() }
                    }
                    Section {
                        Button("Toggle Full Screen") { onToggleFullScreen() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 32,
                               height: ReaderConstants.toolbarCapsuleHeight)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("More options")
                .accessibilityLabel("More options")
            }
            // Subtle glyph shadow so SF Symbols read over both black and bright art.
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
    }
}

// MARK: - Reading mode icon helper

private func readingModeIcon(_ mode: ReadingMode) -> String {
    switch mode {
    case .singlePage:     return "doc"
    case .doublePage:     return "book"
    case .verticalScroll: return "scroll"
    case .verticalDouble: return "book.pages"
    }
}

// MARK: - Bookmarks list popover

private struct BookmarksListView: View {
    @ObservedObject var vm: ReaderViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("Bookmarks")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Close bookmarks")
                .accessibilityLabel("Close bookmarks")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            if vm.bookmarkedPages.isEmpty {
                Text("No bookmarks.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .accessibilityLabel("No bookmarks")
            } else {
                List {
                    ForEach(vm.bookmarkedPages, id: \.self) { page in
                        let isCurrent = page == vm.currentPage
                        Button {
                            vm.goTo(page: page)
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isCurrent ? "bookmark.fill" : "bookmark")
                                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                                    .frame(width: 16)
                                Text("Page \(page + 1)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if isCurrent {
                                    Text("Current")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Go to page \(page + 1)\(isCurrent ? ", current page" : "")")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                ReadingPositionStore.toggleBookmark(page: page, for: vm.comic.url)
                                vm.bookmarkedPages = ReadingPositionStore.bookmarks(for: vm.comic.url)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                ReadingPositionStore.toggleBookmark(page: page, for: vm.comic.url)
                                vm.bookmarkedPages = ReadingPositionStore.bookmarks(for: vm.comic.url)
                            } label: {
                                Label("Remove Bookmark", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 280, minHeight: vm.bookmarkedPages.isEmpty ? 100 : 240)
        .onExitCommand { isPresented = false }
    }
}

// MARK: - Go-to-page popover

/// Small popover presented when the user taps the "N / M" count in the
/// transport capsule.  Accepts a 1-based page number, clamps it to the
/// comic's range, and calls `vm.goTo(page:)` (which is 0-based) on submit.
///
/// KeyMonitor is stopped by ReaderView while this popover is open
/// (via the goToPageOpen binding + .onChange), so digits 1–4 reach the
/// field instead of triggering reading-mode switches.
private struct GoToPageView: View {
    @ObservedObject var vm: ReaderViewModel
    @Binding var isPresented: Bool
    @Binding var text: String

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                TextField("Page", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .accessibilityLabel("Page number (1 to \(vm.pageCount))")

                Button("Go") { commit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedPage == nil)
                    .keyboardShortcut(.defaultAction)
            }

            Text("1 – \(vm.pageCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 180)
        .onAppear { fieldFocused = true }
        .onExitCommand { isPresented = false }
    }

    /// Parses the current text as a 1-based page number clamped to the
    /// comic's range, or nil if the text is not a valid integer.
    private var parsedPage: Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)),
              n >= 1, n <= vm.pageCount else { return nil }
        return n
    }

    private func commit() {
        if let n = parsedPage {
            vm.goTo(page: n - 1)   // convert 1-based user input to 0-based index
        }
        isPresented = false
    }
}
