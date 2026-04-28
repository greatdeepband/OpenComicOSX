import SwiftUI

/// Reader's top-bar chrome: a transparent strip carrying three floating
/// Liquid-Glass capsules — leading (back/Library), centred transport
/// (prev-comic / prev-page / page-count / next-page / next-comic), and
/// trailing (favorite + ellipsis menu). On macOS 26+ the capsules use
/// real Liquid Glass via `.glassEffect(.regular.interactive(true), in:
/// .capsule)` inside one `GlassEffectContainer`; on macOS 14–25 the
/// fallback is `.ultraThinMaterial` clipped to a `Capsule()` with a
/// hairline rim. Geometry, hit targets, and behaviour are identical
/// across both paths.
struct ReaderToolbar: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel
    var onToggleFullScreen: () -> Void

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

                TransportCapsule(vm: vm, library: library)
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
            content.glassEffect(.regular.interactive(true), in: .capsule)
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
    }
}

// MARK: - Leading capsule

private struct LeadingCapsule: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel

    var body: some View {
        ToolbarCapsule {
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
        }
    }
}

// MARK: - Transport capsule (centred)

private struct TransportCapsule: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel

    var body: some View {
        let isVertical = vm.readingMode == .verticalScroll
                       || vm.readingMode == .verticalDouble
        ToolbarCapsule {
            HStack(spacing: 0) {
                segmentButton(
                    systemImage: "chevron.left.2",
                    disabled: library.adjacentComicURL(offset: -1) == nil,
                    help: "Previous comic (Q)"
                ) {
                    vm.persistCurrentPosition()
                    library.openAdjacentComic(offset: -1,
                                              currentMode: vm.readingMode.rawValue)
                }
                SegmentDivider()
                segmentButton(
                    systemImage: "chevron.left",
                    disabled: vm.currentPage == 0 || isVertical,
                    help: "Previous page (←/A)"
                ) {
                    vm.previousPage()
                }
                SegmentDivider()
                Text("\(vm.currentPage + 1) / \(vm.pageCount)")
                    .monospacedDigit()
                    .font(.callout)
                    .frame(minWidth: 72)
                    .padding(.horizontal, 8)
                SegmentDivider()
                segmentButton(
                    systemImage: "chevron.right",
                    disabled: vm.currentPage >= vm.pageCount - 1 || isVertical,
                    help: "Next page (→/D)"
                ) {
                    vm.nextPage()
                }
                SegmentDivider()
                segmentButton(
                    systemImage: "chevron.right.2",
                    disabled: library.adjacentComicURL(offset: 1) == nil,
                    help: "Next comic (E)"
                ) {
                    vm.persistCurrentPosition()
                    library.openAdjacentComic(offset: 1,
                                              currentMode: vm.readingMode.rawValue)
                }
            }
            .frame(height: ReaderConstants.toolbarCapsuleHeight)
        }
    }

    private func segmentButton(systemImage: String,
                               disabled: Bool,
                               help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 32, height: ReaderConstants.toolbarCapsuleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - Trailing capsule

private struct TrailingCapsule: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel
    var onToggleFullScreen: () -> Void

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
                    SegmentDivider()
                }

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
                    Section("Reading Mode") {
                        ForEach(ReadingMode.allCases, id: \.self) { mode in
                            Button {
                                vm.readingMode = mode
                                vm.saveMode()
                            } label: {
                                HStack {
                                    Text(mode.rawValue)
                                    if vm.readingMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Toggle Full Screen") { onToggleFullScreen() }
                            .keyboardShortcut("f", modifiers: [.command, .control])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 32,
                               height: ReaderConstants.toolbarCapsuleHeight)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("More options")
            }
        }
    }
}
