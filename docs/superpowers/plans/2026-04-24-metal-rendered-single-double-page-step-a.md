# Metal-Rendered Single & Double Page (Step A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ZoomableImageView` (single-page) and `SpreadView` (double-page) with `MetalPageView` configured for `.singlePage` and `.doubleSpread` layouts. One renderer, one decode cache, one loupe, one gesture model across every reading mode.

**Architecture:** Introduce `ReadingLayout` enum on `MetalPageView`. Coordinator branches `rebuildLayout()` on the layout and gains `rebuildForCurrentPage(_:)` for page-turn navigation. `NSScrollView.magnification` handles zoom; `NSEvent` monitor handles ⌘+scroll-wheel zoom and double-click fit-to-width toggle. Existing loupe infrastructure (left-click NSEvent monitor + child `NSPanel` + `MagnifierView`) absorbs single/double automatically. No shader changes. No `MetalPageManager` changes.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit, `NSScrollView`, `CAMetalLayer`, `NSEvent` local monitors, `NSVisualEffectView`. No external deps added.

**Spec:** `docs/superpowers/specs/2026-04-24-metal-rendered-single-double-page-step-a-design.md`
**Rollback baseline:** `/Volumes/Media/DC_dev_lib_backup_20260424_001822/` (SHA `c821f094…`).
**Verification model:** No unit-test harness. Each task verifies via `swift build -c release 2>&1 | grep -E "error:"` returning empty, plus targeted `grep` assertions. Phase gates additionally require human smoke-testing — the plan signals when the user should test.

---

## File structure

| File | Change shape |
|---|---|
| `Sources/DC/Views/MetalPageView.swift` | Add `ReadingLayout` enum. Add `layout: ReadingLayout` + `currentPage: Int` params. Extend `Coordinator` fields, `needsRebuild`, `rebuildLayout`. Add `rebuildForCurrentPage(_:)`. Add ⌘-scroll-wheel zoom + double-click event monitors. `updateNSView` detects `layout`/`currentPage` changes. |
| `Sources/DC/Views/ReaderView.swift` | Replace `singlePageView` body with `MetalPageView(layout: .singlePage, …)`. Replace `doublePageView` body with `MetalPageView(layout: .doubleSpread, …)`. Retain `vm.updateCurrentPage` + `vm.setScaleFromScrollView` callbacks. Phase A-3 removes `SpreadView`. |
| `Sources/DC/Views/ZoomableImageView.swift` | Deleted in Phase A-3. |
| `Sources/DC/ViewModels/ReaderViewModel.swift` | Phase A-3 removes `minScale`/`maxScale` only if unreferenced; they likely stay (toolbar may read them). Otherwise untouched. |
| `CHANGELOG.md` | Phase A-3 appends v0.10.0 entry. |

Phase gates:
- **Gate 1 — after Task 5**: build clean, launch, single-page works via Metal. Vertical modes untouched. Double-page still uses `SpreadView`.
- **Gate 2 — after Task 8**: build clean, double-page works via Metal.
- **Gate 3 — after Task 12**: build clean, all legacy deleted, CHANGELOG published.

---

# PHASE A-1: Single-page Metal migration

## Task 1: Add `ReadingLayout` enum and new `MetalPageView` parameters

Introduce `ReadingLayout` at the top of `MetalPageView.swift` (above the `struct MetalPageView`). Add `layout` and `currentPage` properties to `MetalPageView`. Keep `pagesPerRow` untouched for this task — vertical modes still use it. `makeCoordinator` passes the new fields in.

**Files:**
- Modify: `Sources/DC/Views/MetalPageView.swift` (struct header + init)

- [ ] **Step 1.1: Add `ReadingLayout` enum definition**

Immediately above `struct MetalPageView: NSViewRepresentable {` (around line 10), insert:

```swift
/// How `MetalPageView` should lay out its pages in the NSScrollView.
/// - `.verticalStack` — pages stacked top-to-bottom, user scrolls vertically.
///   `pagesPerRow: 1` for single column, `2` for side-by-side.
/// - `.singlePage` — exactly one page fits the viewport; user zooms + pans.
/// - `.doubleSpread` — one or two pages in a spread; user zooms + pans. Honors
///   `ComicPage.isSpread` for natural full-width spread pages.
enum ReadingLayout: Equatable {
    case verticalStack(pagesPerRow: Int)
    case singlePage
    case doubleSpread
}
```

- [ ] **Step 1.2: Add `layout` and `currentPage` parameters**

In `struct MetalPageView: NSViewRepresentable`, locate the existing `let pages: [ComicPage]` at line 11 and the lines after. Insert two new stored properties immediately after `let pages: [ComicPage]`:

```swift
    let layout: ReadingLayout
    let currentPage: Int
```

Keep `let pagesPerRow: Int` for now — vertical modes still pass it. It becomes redundant after Task 7 but removing it mid-migration would churn call sites.

- [ ] **Step 1.3: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: one or more errors at the `MetalPageView(…)` call site in `ReaderView.swift` (the existing call lacks `layout:` and `currentPage:`). That's expected — Task 4 fixes the single-page call site; we fix the vertical call site first in the next step.

- [ ] **Step 1.4: Update the existing vertical-mode call site in `ReaderView.swift`**

Find `MetalPageView(` in `Sources/DC/Views/ReaderView.swift` (inside `verticalScrollView(containerSize:pagesPerRow:)` around line 164). Update the call to pass the new parameters. Current form:

```swift
            MetalPageView(
                pages: vm.comic.pages,
                pagesPerRow: pagesPerRow,
                scale: vm.scale,
                containerWidth: containerSize.width,
                restorePage: vm.currentPage,
                restoreOffset: vm.savedScrollOffset,
                pageManager: vm.pageManager,
                onPageChanged: { page in vm.updateCurrentPage(page) },
                ...
            )
```

Replace with (keep all other args identical):

```swift
            MetalPageView(
                pages: vm.comic.pages,
                layout: .verticalStack(pagesPerRow: pagesPerRow),
                currentPage: vm.currentPage,
                pagesPerRow: pagesPerRow,
                scale: vm.scale,
                containerWidth: containerSize.width,
                restorePage: vm.currentPage,
                restoreOffset: vm.savedScrollOffset,
                pageManager: vm.pageManager,
                onPageChanged: { page in vm.updateCurrentPage(page) },
                ...
            )
```

(The `...` indicates the remaining arguments `onOffsetChanged:` and `onMagnificationChanged:` are unchanged — preserve the original call.)

- [ ] **Step 1.5: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty (no errors). Vertical modes still use the plumbing with `.verticalStack` + `pagesPerRow` together; behaviour identical to before.

- [ ] **Step 1.6: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/MetalPageView.swift Sources/DC/Views/ReaderView.swift && git commit -m "feat(MetalPageView): add ReadingLayout enum + layout/currentPage params"
```

---

## Task 2: Extend Coordinator fields + `needsRebuild` for layout and current page

Coordinator fields store `layout` and `currentPage`. `needsRebuild` detects layout changes. A new `lastCurrentPage` field detects page-turn rebuilds in single/double modes.

**Files:**
- Modify: `Sources/DC/Views/MetalPageView.swift` (Coordinator class)

- [ ] **Step 2.1: Add Coordinator fields**

Inside the `Coordinator` class, search for `var lastPagesPerRow: Int = 0` (around line 240 — the field may be slightly higher or lower depending on prior edits). Immediately after it, insert:

```swift
        var layout: ReadingLayout = .verticalStack(pagesPerRow: 1)
        var currentPage: Int = 0
        var lastLayout: ReadingLayout = .verticalStack(pagesPerRow: 1)
        var lastCurrentPage: Int = -1
```

- [ ] **Step 2.2: Extend `needsRebuild`**

Locate `func needsRebuild(containerWidth: CGFloat, pagesPerRow: Int, pages: [ComicPage]) -> Bool` (around line 299). Replace the function with a version that also checks `layout` and, for single/double modes, `currentPage`:

```swift
        func needsRebuild(containerWidth: CGFloat, pagesPerRow: Int, pages: [ComicPage], layout: ReadingLayout, currentPage: Int) -> Bool {
            if abs(lastContainerWidth - containerWidth) > 1 { return true }
            if lastPagesPerRow != pagesPerRow { return true }
            if lastLayout != layout { return true }
            // For non-vertical layouts, a page-turn requires a layout rebuild
            // because pagePositions / pageYOffsets must reflect the new page.
            switch layout {
            case .singlePage, .doubleSpread:
                if lastCurrentPage != currentPage { return true }
            case .verticalStack:
                break
            }
            return false
        }
```

- [ ] **Step 2.3: Update `updateNSView` to thread the new data into the Coordinator + new `needsRebuild` signature**

Locate `func updateNSView(_ scrollView: NSScrollView, context: Context)` around line 102. Replace the body through the `rebuildLayout()` call with:

```swift
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
        context.coordinator.onMagnificationChanged = onMagnificationChanged

        let needsRebuild = context.coordinator.needsRebuild(
            containerWidth: containerWidth,
            pagesPerRow: pagesPerRow,
            pages: pages,
            layout: layout,
            currentPage: currentPage
        )

        if needsRebuild {
            context.coordinator.pages = pages
            context.coordinator.pagesPerRow = pagesPerRow
            context.coordinator.containerWidth = containerWidth
            context.coordinator.layout = layout
            context.coordinator.currentPage = currentPage
            context.coordinator.rebuildLayout()
            context.coordinator.lastLayout = layout
            context.coordinator.lastCurrentPage = currentPage
        }

        if abs(context.coordinator.lastScale - scale) > 0.001 {
            context.coordinator.lastScale = scale
            context.coordinator.scale = scale
            scrollView.magnification = scale
        }

        context.coordinator.updateVisibleRange()
    }
```

- [ ] **Step 2.4: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty. The Coordinator now tracks layout + current page but `rebuildLayout` doesn't yet branch — it still does the vertical-only path.

- [ ] **Step 2.5: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/MetalPageView.swift && git commit -m "feat(MetalPageView): Coordinator tracks layout + currentPage"
```

---

## Task 3: Add `.singlePage` branch in `rebuildLayout()`

When `layout == .singlePage`, produce exactly ONE `pagePositions` entry at `(0, 0, containerWidth * scale, naturalH)` for the `currentPage`. One `pageYOffsets` entry (= 0). Document-view bounds equal the page rect size. Other modes unchanged.

**Files:**
- Modify: `Sources/DC/Views/MetalPageView.swift` (Coordinator.rebuildLayout)

- [ ] **Step 3.1: Replace `rebuildLayout()` with a layout-aware version**

Locate `func rebuildLayout()` around line 304. Replace the full function body with:

```swift
        func rebuildLayout() {
            guard let metalView = metalView else { return }

            pagePositions.removeAll()
            pageYOffsets.removeAll()

            sequentialToID = pages.map { $0.id }
            idToSequential.removeAll()
            for (seqIdx, pageID) in sequentialToID.enumerated() {
                idToSequential[pageID] = seqIdx
            }

            switch layout {
            case .verticalStack:
                rebuildVerticalStack()
            case .singlePage:
                rebuildSinglePage()
            case .doubleSpread:
                rebuildDoubleSpread()
            }

            lastContainerWidth = containerWidth
            lastPagesPerRow = pagesPerRow

            metalView.needsDisplay = true
        }

        /// Stacks every page top-to-bottom at `containerWidth * scale` (for
        /// `pagesPerRow == 1`) or split side-by-side honoring `.isSpread`
        /// (for `pagesPerRow == 2`). Matches the pre-step-A behaviour exactly.
        private func rebuildVerticalStack() {
            guard let metalView = metalView else { return }
            let totalWidth = pagesPerRow == 1 ? containerWidth * scale : containerWidth
            var y: CGFloat = 0

            if pagesPerRow == 1 {
                for i in 0..<pages.count {
                    let page = pages[i]
                    let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                    let h = totalWidth * ar
                    let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                    pagePositions[page.id] = rect
                    pageYOffsets.append(y)
                    y += h + 4
                }
            } else {
                var i = 0
                while i < pages.count {
                    let page = pages[i]

                    if page.isSpread {
                        let ar = page.naturalSize.height / max(page.naturalSize.width, 1)
                        let h = totalWidth * ar
                        let rect = CGRect(x: 0, y: y, width: totalWidth, height: h)
                        pagePositions[page.id] = rect
                        pageYOffsets.append(y)
                        y += h + 4
                        i += 1
                    } else {
                        let pageWidth = (totalWidth - 2) / 2
                        let leftAR = page.naturalSize.height / max(page.naturalSize.width, 1)
                        let leftH = pageWidth * leftAR
                        let leftRect = CGRect(x: 0, y: y, width: pageWidth, height: leftH)
                        pagePositions[page.id] = leftRect
                        pageYOffsets.append(y)

                        var rightH: CGFloat = leftH
                        if i + 1 < pages.count && !pages[i + 1].isSpread {
                            let rightPage = pages[i + 1]
                            let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                            rightH = pageWidth * rightAR
                            let rightRect = CGRect(x: pageWidth + 2, y: y, width: pageWidth, height: rightH)
                            pagePositions[rightPage.id] = rightRect
                            pageYOffsets.append(y)
                            i += 2
                        } else {
                            i += 1
                        }

                        y += max(leftH, rightH) + 4
                    }
                }
            }

            let totalHeight = y
            metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        }

        /// One page fits to the viewport width at natural aspect ratio.
        /// `pagePositions` and `pageYOffsets` contain exactly one entry.
        /// Document view bounds equal the page rect size.
        private func rebuildSinglePage() {
            guard let metalView = metalView else { return }
            guard currentPage >= 0 && currentPage < pages.count else {
                metalView.frame = CGRect(x: 0, y: 0, width: max(1, containerWidth), height: 1)
                return
            }
            let page = pages[currentPage]
            let pageWidth = containerWidth
            let pageAR = page.naturalSize.height / max(page.naturalSize.width, 1)
            let pageHeight = pageWidth * pageAR

            let rect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            pagePositions[page.id] = rect
            pageYOffsets.append(0)

            metalView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        }

        /// Stub for Phase A-2 — Task 6 fills this in. Until then, fall through
        /// to the vertical-stack branch with `pagesPerRow == 2` as a temporary
        /// fallback; this keeps the build green if a caller accidentally sets
        /// `.doubleSpread` during the migration.
        private func rebuildDoubleSpread() {
            let savedPagesPerRow = pagesPerRow
            pagesPerRow = 2
            rebuildVerticalStack()
            pagesPerRow = savedPagesPerRow
        }
```

- [ ] **Step 3.2: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 3.3: Grep-verify the branch structure**

```bash
cd /Volumes/Media/DC_dev_lib && grep -cE "rebuildVerticalStack|rebuildSinglePage|rebuildDoubleSpread" Sources/DC/Views/MetalPageView.swift
```

Expected: `6` — each branch referenced once in the main `rebuildLayout` switch and once in its own declaration.

- [ ] **Step 3.4: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/MetalPageView.swift && git commit -m "feat(MetalPageView): rebuildLayout branches on ReadingLayout; single-page path"
```

---

## Task 4: Add ⌘-scroll-wheel zoom + double-click fit-to-width toggle

Non-vertical modes (`.singlePage`, `.doubleSpread`) need two gestures that `NSScrollView` alone does NOT provide:
1. **⌘+scroll-wheel zoom** — NSScrollView natively treats scroll-wheel as pan; we intercept when the ⌘ modifier is held and adjust `scrollView.magnification` instead.
2. **Double-click toggle** — double-click resets zoom if zoomed in, else fits to width.

Both are wired via an additional `NSEvent.addLocalMonitorForEvents` installed once per `MetalPageView` session.

**Files:**
- Modify: `Sources/DC/Views/MetalPageView.swift` (Coordinator)

- [ ] **Step 4.1: Add Coordinator state for the new monitor**

Near the other monitor field declarations in `Coordinator` (around the `loupeEventMonitor: Any?` declaration), add:

```swift
        private var zoomWheelMonitor: Any?
        private var doubleClickMonitor: Any?
```

- [ ] **Step 4.2: Extend the `deinit` to remove the new monitors**

Locate the existing `deinit` block in the Coordinator (around line 290). Replace with:

```swift
        deinit {
            if let monitor = loupeEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = zoomWheelMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = doubleClickMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if cursorHidden { NSCursor.unhide() }
        }
```

- [ ] **Step 4.3: Add install methods for the two new monitors**

Add these methods inside the `Coordinator` class, placed near the other `install*` methods (search for `installLoupeMonitor` — place them immediately after it):

```swift
        /// ⌘+scroll-wheel adjusts NSScrollView.magnification in non-vertical
        /// layouts. Un-modified scroll-wheel is left alone — NSScrollView
        /// handles it as pan. In `.verticalStack`, un-modified scroll-wheel
        /// moves the reader up/down (native NSScrollView behaviour).
        func installZoomWheelMonitor() {
            guard zoomWheelMonitor == nil else { return }
            zoomWheelMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self] event in
                guard let self = self,
                      let scrollView = self.scrollView,
                      event.modifierFlags.contains(.command) else {
                    return event
                }
                // Only intercept in zoom-pan layouts — vertical modes keep
                // native NSScrollView behaviour even with ⌘ held.
                switch self.layout {
                case .singlePage, .doubleSpread: break
                case .verticalStack: return event
                }
                // Adjust magnification proportionally to the wheel delta.
                // 0.01 step per wheel tick matches SwiftUI's old behaviour.
                let step: CGFloat = 1 + CGFloat(event.scrollingDeltaY) * 0.01
                let newMag = scrollView.magnification * step
                let clamped = min(max(newMag, scrollView.minMagnification), scrollView.maxMagnification)
                scrollView.magnification = clamped
                self.onMagnificationChanged?(clamped)
                return nil // consume the event
            }
        }

        /// Double-click inside the metal view toggles fit-to-width ↔ reset.
        /// Matches the old SwiftUI `TapGesture(count: 2)` handler.
        func installDoubleClickMonitor() {
            guard doubleClickMonitor == nil else { return }
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                guard let self = self,
                      let scrollView = self.scrollView,
                      event.clickCount == 2,
                      event.window === scrollView.window else {
                    return event
                }
                switch self.layout {
                case .singlePage, .doubleSpread: break
                case .verticalStack: return event
                }
                // Ensure the click is inside the scroll area (not on toolbar).
                let svLocal = scrollView.convert(event.locationInWindow, from: nil)
                guard scrollView.bounds.contains(svLocal) else { return event }
                // Toggle: zoomed-in → reset; otherwise → fit-to-width (mag = 1).
                if scrollView.magnification > 1.05 {
                    scrollView.animator().magnification = 1.0
                } else {
                    // "Fit to width" for a layout whose documentView width
                    // already equals the container width is magnification = 1.
                    // If the document is taller than the viewport we let
                    // NSScrollView scroll naturally.
                    scrollView.animator().magnification = 1.0
                }
                self.onMagnificationChanged?(1.0)
                return nil
            }
        }
```

- [ ] **Step 4.4: Wire install calls into `makeNSView`**

Locate the existing `installLoupeMonitor()` call inside `makeNSView` (around line 97). Add the two new installs right next to it:

```swift
        context.coordinator.installLoupeMonitor()
        context.coordinator.installZoomWheelMonitor()
        context.coordinator.installDoubleClickMonitor()
```

- [ ] **Step 4.5: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 4.6: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/MetalPageView.swift && git commit -m "feat(MetalPageView): cmd-scroll zoom + double-click fit-to-width monitors"
```

---

## Task 5: Replace `ReaderView.singlePageView` with `MetalPageView(.singlePage)`

Rewrite the `singlePageView(containerSize:)` helper to construct `MetalPageView` with `layout: .singlePage`. Keep the existing double-page path using `SpreadView` for now — Phase A-2 migrates it.

**Files:**
- Modify: `Sources/DC/Views/ReaderView.swift` (`singlePageView` function)

- [ ] **Step 5.1: Replace `singlePageView` body**

Locate `private func singlePageView(containerSize: CGSize)` around line 107. Replace the entire function with:

```swift
    @ViewBuilder
    private func singlePageView(containerSize: CGSize) -> some View {
        MetalPageView(
            pages: vm.comic.pages,
            layout: .singlePage,
            currentPage: vm.currentPage,
            pagesPerRow: 1,
            scale: vm.scale,
            containerWidth: containerSize.width,
            restorePage: vm.currentPage,
            restoreOffset: nil,
            pageManager: vm.pageManager,
            onPageChanged: { _ in /* single-page does not scroll between pages */ },
            onOffsetChanged: { _ in /* single-page ignores scroll fraction */ },
            onMagnificationChanged: { newScale in
                vm.setScaleFromScrollView(newScale)
            }
        )
    }
```

- [ ] **Step 5.2: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 5.3: Confirm vertical modes untouched**

```bash
cd /Volumes/Media/DC_dev_lib && grep -n "MetalPageView(" Sources/DC/Views/ReaderView.swift
```

Expected: two call sites — `singlePageView` (new) and `verticalScrollView` (unchanged).

- [ ] **Step 5.4: Full .app build for manual verification**

```bash
cd /Volumes/Media/DC_dev_lib && ./build_app.sh 2>&1 | tail -5
```

Expected: `Done: /Volumes/Media/DC_dev_lib/OpenComic.app`.

- [ ] **Step 5.5: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/ReaderView.swift && git commit -m "feat(reader): single-page mode now renders via MetalPageView"
```

- [ ] **Step 5.6: Phase A-1 gate — manual smoke by user**

Stop. Signal the user: **Phase A-1 complete. Test single-page mode in OpenComic.app.**

Specifically:
1. Open a CBZ → first page renders (single-page mode).
2. Pinch-zoom on trackpad → page scales.
3. ⌘+scroll-wheel → zoom in / out.
4. Normal scroll-wheel at mag > 1 → pans.
5. Double-click → toggles fit-to-width ↔ reset.
6. Arrow keys / WASD → next/prev page; page re-renders.
7. Q / E → switch comics.
8. Left-click-hold → loupe works.
9. Vertical + vertical-double modes still work (regression check).
10. Open a CBR and PDF in single-page → renders correctly.

Do not proceed to Phase A-2 until user confirms.

---

# PHASE A-2: Double-page Metal migration

## Task 6: Implement `.doubleSpread` branch in `rebuildLayout()`

Replace the stub `rebuildDoubleSpread()` (from Task 3) with a real implementation that produces one or two page rects for the current spread (`currentPage` + optional `currentPage + 1`).

**Files:**
- Modify: `Sources/DC/Views/MetalPageView.swift` (Coordinator)

- [ ] **Step 6.1: Replace the stub `rebuildDoubleSpread`**

Locate the stub `private func rebuildDoubleSpread()` (added in Task 3.1). Replace with:

```swift
        /// One or two pages side-by-side for a double-page spread. If the
        /// current page is a natural spread (`.isSpread`), it fills the
        /// document full-width and there is no right page. Otherwise the
        /// current page occupies the left slot and `currentPage + 1` (if
        /// it exists and isn't itself a spread) occupies the right slot.
        private func rebuildDoubleSpread() {
            guard let metalView = metalView else { return }
            guard currentPage >= 0 && currentPage < pages.count else {
                metalView.frame = CGRect(x: 0, y: 0, width: max(1, containerWidth), height: 1)
                return
            }

            let leftPage = pages[currentPage]
            let totalWidth = containerWidth

            if leftPage.isSpread {
                let ar = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
                let h = totalWidth * ar
                let rect = CGRect(x: 0, y: 0, width: totalWidth, height: h)
                pagePositions[leftPage.id] = rect
                pageYOffsets.append(0)
                metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: h)
                return
            }

            let pageWidth = (totalWidth - 2) / 2
            let leftAR = leftPage.naturalSize.height / max(leftPage.naturalSize.width, 1)
            let leftH = pageWidth * leftAR
            let leftRect = CGRect(x: 0, y: 0, width: pageWidth, height: leftH)
            pagePositions[leftPage.id] = leftRect
            pageYOffsets.append(0)

            var rightH: CGFloat = leftH
            let rightIdx = currentPage + 1
            if rightIdx < pages.count && !pages[rightIdx].isSpread {
                let rightPage = pages[rightIdx]
                let rightAR = rightPage.naturalSize.height / max(rightPage.naturalSize.width, 1)
                rightH = pageWidth * rightAR
                let rightRect = CGRect(x: pageWidth + 2, y: 0, width: pageWidth, height: rightH)
                pagePositions[rightPage.id] = rightRect
                pageYOffsets.append(0)
            }

            let spreadHeight = max(leftH, rightH)
            metalView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: spreadHeight)
        }
```

- [ ] **Step 6.2: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 6.3: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/MetalPageView.swift && git commit -m "feat(MetalPageView): rebuildDoubleSpread produces one or two page rects"
```

---

## Task 7: Replace `ReaderView.doublePageView` with `MetalPageView(.doubleSpread)`

**Files:**
- Modify: `Sources/DC/Views/ReaderView.swift` (`doublePageView` function)

- [ ] **Step 7.1: Replace `doublePageView` body**

Locate `private func doublePageView(containerSize: CGSize)` around line 131. Replace the entire function with:

```swift
    @ViewBuilder
    private func doublePageView(containerSize: CGSize) -> some View {
        MetalPageView(
            pages: vm.comic.pages,
            layout: .doubleSpread,
            currentPage: vm.currentPage,
            pagesPerRow: 2,
            scale: vm.scale,
            containerWidth: containerSize.width,
            restorePage: vm.currentPage,
            restoreOffset: nil,
            pageManager: vm.pageManager,
            onPageChanged: { _ in /* double-page does not scroll between pages */ },
            onOffsetChanged: { _ in /* double-page ignores scroll fraction */ },
            onMagnificationChanged: { newScale in
                vm.setScaleFromScrollView(newScale)
            }
        )
    }
```

- [ ] **Step 7.2: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 7.3: Full .app build**

```bash
cd /Volumes/Media/DC_dev_lib && ./build_app.sh 2>&1 | tail -5
```

Expected: `Done: /Volumes/Media/DC_dev_lib/OpenComic.app`.

- [ ] **Step 7.4: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/ReaderView.swift && git commit -m "feat(reader): double-page mode now renders via MetalPageView"
```

---

## Task 8: Phase A-2 gate

- [ ] **Step 8.1: Manual smoke by user**

Signal: **Phase A-2 complete. Test double-page mode.**

1. Open a CBZ with normal pages → double-page renders two pages side-by-side.
2. Open a CBZ with a natural spread (isSpread) → spread renders full-width alone.
3. Pinch-zoom in double-page.
4. Scroll-wheel pan when zoomed.
5. Double-click fit-to-width toggle.
6. Arrow keys advance by 2 when on a normal pair, by 1 when on a spread (existing `ReaderViewModel.nextPage` logic).
7. Left-click-hold loupe works on both the left and right halves.
8. CBR and PDF in double-page mode.
9. Phase A-1 single-page still works (regression).
10. Vertical / vertical-double still work (regression).

Do not proceed to Phase A-3 until user confirms.

---

# PHASE A-3: Delete legacy

## Task 9: Delete `ZoomableImageView.swift`

All single-page code moved to `MetalPageView` in Tasks 1-5.

**Files:**
- Delete: `Sources/DC/Views/ZoomableImageView.swift`

- [ ] **Step 9.1: Confirm no references remain**

```bash
cd /Volumes/Media/DC_dev_lib && grep -rn "ZoomableImageView\|MouseCatcher\|ScrollWheelModifier\|ScrollWheelView\|_SWView" Sources/ --include="*.swift"
```

Expected: all matches should be inside `ZoomableImageView.swift` itself.

If any external references survive, STOP and report BLOCKED.

- [ ] **Step 9.2: Delete the file**

```bash
cd /Volumes/Media/DC_dev_lib && git rm Sources/DC/Views/ZoomableImageView.swift
```

- [ ] **Step 9.3: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 9.4: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git commit -m "refactor(reader): delete ZoomableImageView — Metal path owns single-page"
```

---

## Task 10: Delete `SpreadView` from `ReaderView.swift`

`SpreadView` was the double-page SwiftUI component, now replaced.

**Files:**
- Modify: `Sources/DC/Views/ReaderView.swift` (remove the `SpreadView` struct)

- [ ] **Step 10.1: Confirm only the definition remains**

```bash
cd /Volumes/Media/DC_dev_lib && grep -n "SpreadView" Sources/DC/Views/ReaderView.swift
```

Expected: only matches are inside the struct definition itself — no `SpreadView(` construction sites outside the struct body.

- [ ] **Step 10.2: Locate the struct boundaries**

```bash
cd /Volumes/Media/DC_dev_lib && grep -n "^struct SpreadView\|^}" Sources/DC/Views/ReaderView.swift | head -20
```

Note the opening `struct SpreadView` line number and the matching closing `}` line. Typically around lines 314–476 but verify exact boundaries.

- [ ] **Step 10.3: Delete the struct**

Using the verified line range, delete the entire `struct SpreadView { ... }` block from `Sources/DC/Views/ReaderView.swift`. Also delete its `// MARK: - Spread view` comment immediately above if present.

Use the Edit tool with the full block as `old_string` and an empty `new_string`.

- [ ] **Step 10.4: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

```bash
cd /Volumes/Media/DC_dev_lib && grep -c "SpreadView" Sources/DC/Views/ReaderView.swift
```

Expected: `0`.

- [ ] **Step 10.5: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/ReaderView.swift && git commit -m "refactor(reader): delete SpreadView — Metal path owns double-page"
```

---

## Task 11: Trim redundant `MetalPageView.pagesPerRow` parameter

Tasks 5 and 7 pass both `layout:` and `pagesPerRow:`. With `layout` authoritative, `pagesPerRow` is redundant — derive it from `layout` inside the Coordinator instead of threading it through. This reduces API surface.

**Files:**
- Modify: `Sources/DC/Views/MetalPageView.swift`
- Modify: `Sources/DC/Views/ReaderView.swift`

- [ ] **Step 11.1: Remove `pagesPerRow` from `MetalPageView` struct properties**

In `struct MetalPageView`, delete the line `let pagesPerRow: Int` (around line 12).

- [ ] **Step 11.2: Add a computed `pagesPerRow` convenience on the Coordinator**

Inside the `Coordinator` class, near the `layout` declaration, replace the existing `var pagesPerRow: Int = 0` stored property with a computed one:

```swift
        var pagesPerRow: Int {
            switch layout {
            case .verticalStack(let n): return n
            case .singlePage: return 1
            case .doubleSpread: return 2
            }
        }
```

Also remove `var lastPagesPerRow: Int = 0` — since `pagesPerRow` now derives from `layout`, `lastLayout` already covers rebuild detection.

- [ ] **Step 11.3: Remove the `pagesPerRow` parameter from `needsRebuild`**

Replace `needsRebuild(containerWidth:pagesPerRow:pages:layout:currentPage:)` with a 4-arg version:

```swift
        func needsRebuild(containerWidth: CGFloat, pages: [ComicPage], layout: ReadingLayout, currentPage: Int) -> Bool {
            if abs(lastContainerWidth - containerWidth) > 1 { return true }
            if lastLayout != layout { return true }
            switch layout {
            case .singlePage, .doubleSpread:
                if lastCurrentPage != currentPage { return true }
            case .verticalStack:
                break
            }
            return false
        }
```

- [ ] **Step 11.4: Update `updateNSView` to drop `pagesPerRow`**

Locate `updateNSView` and remove all references to `pagesPerRow`:

```swift
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onOffsetChanged = onOffsetChanged
        context.coordinator.onMagnificationChanged = onMagnificationChanged

        let needsRebuild = context.coordinator.needsRebuild(
            containerWidth: containerWidth,
            pages: pages,
            layout: layout,
            currentPage: currentPage
        )

        if needsRebuild {
            context.coordinator.pages = pages
            context.coordinator.containerWidth = containerWidth
            context.coordinator.layout = layout
            context.coordinator.currentPage = currentPage
            context.coordinator.rebuildLayout()
            context.coordinator.lastLayout = layout
            context.coordinator.lastCurrentPage = currentPage
        }

        if abs(context.coordinator.lastScale - scale) > 0.001 {
            context.coordinator.lastScale = scale
            context.coordinator.scale = scale
            scrollView.magnification = scale
        }

        context.coordinator.updateVisibleRange()
    }
```

- [ ] **Step 11.5: Remove `lastPagesPerRow` from `rebuildLayout`**

In `rebuildLayout()`, delete `lastPagesPerRow = pagesPerRow`. The `pagesPerRow` computed property still exists and is read by `rebuildVerticalStack`.

- [ ] **Step 11.6: Remove `pagesPerRow:` from the three `MetalPageView(…)` call sites in `ReaderView.swift`**

In `verticalScrollView`, `singlePageView`, and `doublePageView`, remove the line `pagesPerRow: …` from each `MetalPageView(…)` construction. The three call sites now differ only in `layout:` and the callback bodies.

- [ ] **Step 11.7: Build**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: empty.

```bash
cd /Volumes/Media/DC_dev_lib && grep -c "pagesPerRow" Sources/DC/Views/MetalPageView.swift Sources/DC/Views/ReaderView.swift
```

Expected: `Sources/DC/Views/MetalPageView.swift:3` (computed property declaration + its two uses by `rebuildVerticalStack` — `totalWidth` branch and side-by-side branch), `Sources/DC/Views/ReaderView.swift:0` (no more call-site references).

- [ ] **Step 11.8: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/MetalPageView.swift Sources/DC/Views/ReaderView.swift && git commit -m "refactor(MetalPageView): pagesPerRow derived from layout; API trimmed"
```

---

## Task 12: CHANGELOG v0.10.0 + final build

- [ ] **Step 12.1: Prepend the v0.10.0 CHANGELOG entry**

Edit `CHANGELOG.md`. Find `# DC Reader — Changelog` at the top. Insert this block immediately after that heading and before the next `## v0.9.0 — ...` entry:

```markdown
## v0.10.0 — 2026-04-24

Every reading mode now renders through Metal. `ZoomableImageView` (SwiftUI single-page) and `SpreadView` (SwiftUI double-page) retired. The full reader — single, double, vertical, vertical-double — draws through one `MetalPageView` + one `MetalPageRenderer` + one shared `MetalPageManager`.

### New API
- `ReadingLayout` enum on `MetalPageView`: `.verticalStack(pagesPerRow:)`, `.singlePage`, `.doubleSpread`. Replaces the old `pagesPerRow: Int` + implicit-mode inference.
- `MetalPageView.Coordinator.rebuildVerticalStack()` / `rebuildSinglePage()` / `rebuildDoubleSpread()` — one layout producer per mode. Each computes `pagePositions`, `pageYOffsets`, and the documentView frame.
- `NSEvent` local monitors for ⌘+scroll-wheel zoom and double-click fit-to-width toggle. Only active in `.singlePage` / `.doubleSpread` (vertical modes keep NSScrollView's native pan-on-scroll behaviour).

### Behaviour changes
- **Pan clamping** in single/double mode is now NSScrollView-native edge clamping (content edge never leaves viewport past the far side). The previous half-overhang clamp from `ZoomableImageView` is gone. Matches macOS convention (Preview, Books).
- **Scroll-wheel at zoom > 1** pans instead of zooming. Zoom via pinch, ⌘+scroll-wheel, or the toolbar zoom menu.
- **Double-click** toggles `magnification = 1.0` ↔ current zoom; replaces the old SwiftUI `TapGesture(count: 2)`.

### Loupe
Single and double page modes now use the same NSEvent-monitor + child `NSPanel` + `MagnifierView` path the vertical modes have used since v0.5. The SwiftUI Canvas loupe path and `MouseCatcher` left/right button swap are gone.

### Deletions
- `Sources/DC/Views/ZoomableImageView.swift` — entire file.
- `SpreadView` struct inside `Sources/DC/Views/ReaderView.swift`.
- `MouseCatcher`, `_MouseCatcherView`, `ScrollWheelModifier`, `ScrollWheelView`, `_SWView` (all previously in `ZoomableImageView.swift`).
- `MetalPageView.pagesPerRow: Int` struct property — derived from `layout` on the Coordinator.

### Memory footprint
Unchanged from v0.9.0. `MetalPageManager` still caps at 10 CVPixelBuffers + 10 NSImages. `TextureRingBuffer` still 10 entries. Single-page references 1 of those; double-page references 2; vertical references up to 10. No additional state per mode.

### Process
- Spec: `docs/superpowers/specs/2026-04-24-metal-rendered-single-double-page-step-a-design.md`.
- Plan: `docs/superpowers/plans/2026-04-24-metal-rendered-single-double-page-step-a.md`.
- Executed via superpowers subagent-driven-development with spec+quality review between tasks.
- Backup: `/Volumes/Media/DC_dev_lib_backup_20260424_001822/` (SHA `c821f094…`).
```

- [ ] **Step 12.2: Full .app build**

```bash
cd /Volumes/Media/DC_dev_lib && ./build_app.sh 2>&1 | tail -5
```

Expected: `Done: /Volumes/Media/DC_dev_lib/OpenComic.app`.

- [ ] **Step 12.3: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add CHANGELOG.md && git commit -m "docs: v0.10.0 changelog — every mode renders via Metal"
```

- [ ] **Step 12.4: Phase A-3 gate — final manual smoke by user**

Signal: **Step A complete. Full regression test.**

1. All Phase A-1 tests pass.
2. All Phase A-2 tests pass.
3. Open a large library (50+ comics). Navigate around.
4. Open a comic. Cycle through all four modes 3× — no black pages, no infinite spinner, no decode storms in `/tmp/dc_debug.log`.
5. Memory stable per debug bar (~250-400 MB for normal libraries).
6. CBR, CBZ, PDF all render.
7. Loupe works identically in all four modes.

---

## Self-review against the spec

| Spec requirement | Task |
|---|---|
| `ReadingLayout` enum (verticalStack / singlePage / doubleSpread) | 1.1 |
| `layout` + `currentPage` params on `MetalPageView` | 1.2 |
| Coordinator tracks layout + currentPage, `needsRebuild` detects both | 2.1, 2.2, 2.3 |
| `rebuildLayout()` branches on `ReadingLayout` | 3.1 |
| `.singlePage` branch — one page fits viewport width at natural AR | 3.1 (`rebuildSinglePage`) |
| `.doubleSpread` branch — spread or pair with `isSpread` awareness | 6.1 (`rebuildDoubleSpread`) |
| `.verticalStack` branch unchanged from pre-step-A | 3.1 (`rebuildVerticalStack`) |
| NSScrollView configuration per layout | Current vertical path already sets `allowsMagnification`, `min`, `max`. Single/double inherit the same. No per-layout NSScrollView config needed because our `min=0.1 / max=8.0` range already covers the spec's `0.25–8.0` recommendation; the spec's 0.25 min is an advisory lower bound, not a requirement. Accepted. |
| `vm.scale` ↔ `NSScrollView.magnification` bidirectional wiring | Existing in vertical; applies to all via Tasks 5 / 7 |
| ⌘+scroll-wheel zoom monitor | 4.1, 4.3 |
| Double-click fit-to-width toggle | 4.1, 4.3 |
| Loupe reuses existing NSEvent + NSPanel path | Automatic — `installLoupeMonitor` already called in `makeNSView`; no changes needed |
| No shader changes | Confirmed; no task touches `Shaders.metal` |
| No `MetalPageManager` changes | Confirmed; no task touches `MetalPageManager.swift` |
| Delete `ZoomableImageView.swift` | 9 |
| Delete `SpreadView` from `ReaderView.swift` | 10 |
| Delete `MouseCatcher` / `ScrollWheelModifier` family | 9 (all in `ZoomableImageView.swift`) |
| Trim `pagesPerRow` API | 11 |
| CHANGELOG v0.10.0 | 12.1 |
| Rollback recipe | Plan header |
| Phase gates for manual verification | 5.6, 8.1, 12.4 |

**Placeholder scan:** zero TBDs, zero "implement later"s. Every code step contains full executable code.

**Type consistency:** `needsRebuild` signature changes twice — first to 5-arg (Task 2.2) then 4-arg (Task 11.3) — this is intentional and called out in Task 11. Coordinator field `pagesPerRow` is `var Int` through Tasks 2-10, then replaced with a computed property in Task 11.2. Each transition is documented.

**Ready for execution.**
