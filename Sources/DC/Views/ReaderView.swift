import SwiftUI
import AppKit

struct ReaderView: View {
    @EnvironmentObject var library: LibraryViewModel
    @StateObject private var vm: ReaderViewModel

    init(comic: Comic) {
        _vm = StateObject(wrappedValue: ReaderViewModel(comic: comic))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                pageContent(containerSize: geo.size)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(vm.comic.title)
        .onKeyPress(.leftArrow)  { vm.previousPage(); return .handled }
        .onKeyPress(.rightArrow) { vm.nextPage();     return .handled }
        .onKeyPress(.upArrow)    { vm.zoomIn();       return .handled }
        .onKeyPress(.downArrow)  { vm.zoomOut();      return .handled }
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageContent(containerSize: CGSize) -> some View {
        if let image = vm.currentImage {
            ZoomableImageView(
                image: image,
                scale: $vm.scale,
                offset: $vm.offset,
                minScale: vm.minScale,
                maxScale: vm.maxScale
            )
            .gesture(
                TapGesture(count: 2).onEnded {
                    if vm.scale > 1.05 {
                        vm.resetZoom()
                    } else {
                        vm.fitToWidth(containerWidth: containerSize.width)
                    }
                }
            )
        } else {
            Text("No pages found")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Left: close
        ToolbarItem(placement: .navigation) {
            Button(action: { library.closeComic() }) {
                Label("Library", systemImage: "chevron.left")
            }
        }

        // Center: page indicator + navigation
        ToolbarItemGroup(placement: .principal) {
            Button(action: { vm.previousPage() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(vm.currentPage == 0)

            Text("\(vm.currentPage + 1) / \(vm.pageCount)")
                .monospacedDigit()
                .frame(minWidth: 80)

            Button(action: { vm.nextPage() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(vm.currentPage >= vm.pageCount - 1)
        }

        // Right: zoom controls
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { vm.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
            }

            Text(String(format: "%.0f%%", vm.scale * 100))
                .monospacedDigit()
                .frame(minWidth: 48)

            Button(action: { vm.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
            }

            Button(action: { vm.resetZoom() }) {
                Image(systemName: "1.magnifyingglass")
            }

            Menu {
                Button("Fit to Width") {
                    // width approximation — will be refined with GeometryReader
                    vm.fitToWidth(containerWidth: 900)
                }
                Button("Actual Size (100%)") { vm.zoomToActualSize() }
                Divider()
                ForEach(ReadingMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { vm.readingMode = mode }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
