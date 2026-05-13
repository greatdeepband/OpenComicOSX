# Reader toolbar — classic Mac unified toolbar with Liquid Glass

**Date:** 2026-04-27
**Status:** Spec — awaiting user review before plan-out
**Targets:** Reader mode in OpenComic (`/Volumes/Media/DC_dev_lib`), all four reading modes (single, double, vertical, vertical-double).

---

## 1. Goal

Replace the current opaque `TitlebarEffectView`-backed strip in `ReaderView` with a **transparent strip carrying three floating Liquid Glass capsules** — leading (Library / back), centered (transport: prev-comic / prev-page / page-count / next-page / next-comic), trailing (favorite + ellipsis menu). The geometry borrows from the classic unified-toolbar Mac idiom (clusters of related controls grouped into pill-shaped capsules); the material is the macOS 26 Liquid Glass introduced at WWDC 26.

## 2. Non-goals

- Not redesigning the contents of the ellipsis menu, the keyboard shortcuts, page navigation logic, favorites toggle, or mode switching. The handlers behind every button are unchanged.
- Not touching the loupe overlay (`MetalPageView+Loupe.swift`, `MagnifierView`, `LoupeOverlayState`). The loupe is a SwiftUI sibling in the same outer ZStack and is independent of the strip's chrome.
- Not changing the Metal pipeline, scrollview, or any rendering code path.
- Not adjusting `topContentInsets` math, `MetalCanvasView.layout()`, the v0.10.1 centring fix, the top-bar-bleed `topInset` carve-out, or the CAMetalLayer drawable-rotation retry.

## 3. Visual layout

```
┌────────────────────────── 38pt strip · transparent ─────────────────────────────┐
│                                                                                 │
│  ●●●  ┌─[chev.left] Library─┐       ┌─⌫⌫│◀│ 12 / 247 │▶│⌫⌫─┐       ┌─♡│⋯─┐    │
│  TL   └──── leading ────────┘       └────── transport ─────┘       └─trail-┘    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
       ↑ 72pt gutter for traffic-lights (unchanged)
```

- Strip height **38pt** (unchanged — `ReaderConstants.topBarHeight`).
- Strip background is **transparent**. The comic page renders behind the capsules; the existing `topContentInset = 38` keeps actual page geometry off-limits to the bar so content layout/centring math stays valid.
- Three independent **glass capsules** float in the strip, each vertically centred (≈ 5pt above the strip's bottom edge). All three sit inside one `GlassEffectContainer` (macOS 26+) so Liquid Glass refraction sampling is coordinated.
- Traffic lights stay where `.windowStyle(.hiddenTitleBar)` puts them. The leading-edge spacer goes from the current 72pt to **80pt** — the extra 8pt gives the leading capsule visible breathing room from the rightmost traffic light, since the capsule has its own glass rim that would otherwise touch the close-button hit area.

## 4. Capsule contents

| Capsule | Contents | Hit-test / behaviour |
|---|---|---|
| **Leading** | `chevron.left` glyph + "Library" label | Single button. Whole capsule is the hit target. Calls `vm.persistCurrentPosition()` then `library.closeComic()` (current `backButton` body). |
| **Transport** (centred) | `chevron.left.2` ▏ `chevron.left` ▏ `12 / 247` ▏ `chevron.right` ▏ `chevron.right.2` | 5 segments separated by 1pt `Color.primary.opacity(0.12)` hairlines. Segment-level disable: prev-comic / next-comic disable based on `library.adjacentComicURL(offset:)`; prev-page / next-page disable on `vm.currentPage` bounds *and* when `vm.readingMode` is vertical (current behaviour). The page-count segment is never disabled — `Text("\(vm.currentPage + 1) / \(vm.pageCount)").monospacedDigit()`. |
| **Trailing** | favorite (`heart` / `heart.fill`) ▏ ellipsis (`ellipsis.circle`) Menu | 2 segments, hairline divider. Menu contents identical to current `trailingCluster` (Zoom section, Reading Mode section, Toggle Full Screen). |

Each capsule:
- Height **28pt** (`ReaderConstants.toolbarCapsuleHeight`, new).
- Internal horizontal padding **10pt**.
- Segment glyphs at SwiftUI's default toolbar size (`.imageScale(.medium)`); the page-count uses `.font(.callout).monospacedDigit().frame(minWidth: 72)` so the text doesn't jitter as digits change.
- Vertically centred in the 38pt strip → 5pt of strip remains above and below.

## 5. Material & availability

```swift
struct ToolbarCapsule<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(true), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
    }
}
```

- Primary path (macOS 26+): `.glassEffect(.regular.interactive(true), in: .capsule)` — true Liquid Glass with hover/press response.
- Fallback path (macOS 14–25): `.ultraThinMaterial` clipped to a `Capsule()` with a 0.5pt white-10% rim. Same shape, same layout — just no refractive Liquid Glass.
- All three capsules are wrapped in one `GlassEffectContainer { ... }` on macOS 26+ via the same availability gate. The container's job is purely Liquid-Glass refraction-sampling coordination (so the three capsules sample a consistent backdrop and would morph correctly if we ever animate `glassEffectID` between them). On macOS 14–25 the container is a plain `Group { … }`; the three capsules render independently with their own `.ultraThinMaterial` backgrounds because there's nothing to coordinate.

**Deployment target.** Stays at `.macOS(.v14)` per current `Package.swift`. The availability gate is the responsible default. If we want to drop the fallback and bump to `.macOS(.v26)`, that's a one-line change but excludes pre-Tahoe users — we'll only do it on explicit request.

## 6. File structure

### New file: `Sources/DC/Views/ReaderToolbar.swift` (≈ 200 lines)

Top-level view that ReaderView calls into. Receives `vm: ReaderViewModel` and `library: LibraryViewModel` as observed dependencies. Exposes one public symbol: `ReaderToolbar`.

Internal types (all `private` or `fileprivate` to keep the surface small):
- `ToolbarCapsule<Content>` — material wrapper with the availability gate (Section 5).
- `Segmented<Content>` — `HStack` with hairline `Divider`s injected between children. Used by transport and trailing capsules.
- `LeadingCapsule`, `TransportCapsule`, `TrailingCapsule` — three sub-views, each owning its own state bindings, each rendered inside a `ToolbarCapsule`.

Layout root:

```swift
struct ReaderToolbar: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var library: LibraryViewModel
    var onCloseFullscreen: () -> Void  // toggleFullscreen passed in from ReaderView

    var body: some View {
        glassContainer {
            ZStack {
                HStack(spacing: 0) {
                    Spacer().frame(width: 80)        // traffic-lights gutter
                    LeadingCapsule(...)
                    Spacer()
                    TrailingCapsule(...)
                }
                .padding(.horizontal, 8)
                TransportCapsule(...)                // centred via ZStack
            }
            .frame(height: ReaderConstants.topBarHeight)
        }
    }

    @ViewBuilder
    private func glassContainer<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer { c() } } else { c() }
    }
}
```

### Modified file: `Sources/DC/Views/ReaderView.swift`

- `readerTopBar` reduces to a one-line call site:
  ```swift
  private var readerTopBar: some View {
      ReaderToolbar(vm: vm, library: library, onCloseFullscreen: toggleFullscreen)
  }
  ```
- The current inline computed properties `backButton`, `transportCluster`, `trailingCluster` move into `ReaderToolbar.swift` as parts of `LeadingCapsule` / `TransportCapsule` / `TrailingCapsule` respectively.
- `TitlebarEffectView()` background on the strip is removed.
- `readerTopBarHeight` and the `.padding(.top, readerTopBarHeight)` arithmetic are unchanged (still relevant for any future caller; today the modeContent path uses it via `topContentInset` only).

### Modified file: `Sources/DC/ReaderConstants.swift`

Adds:

```swift
/// Height of an individual toolbar capsule. Each capsule sits centred in
/// the 38pt strip with ≈ 5pt of strip remaining above and below.
static let toolbarCapsuleHeight: CGFloat = 28

/// Hairline divider opacity inside Segmented capsules. Tuned for both
/// light and dark mode against ultra-thin / Liquid Glass material.
static let toolbarSegmentDividerOpacity: Double = 0.12
```

`topBarHeight = 38` is unchanged. No inset arithmetic moves.

### Conditional cleanup: `Sources/DC/Views/TitlebarEffectView.swift`

`grep -rn TitlebarEffectView Sources/` before deleting. If `ReaderView.readerTopBar` was the only caller, delete the file. If anything else uses it (a debug overlay, an alternate toolbar style, etc.), leave it. The plan-out will run this grep and decide.

## 7. Architecture & data flow

```
ReaderView
  └── ZStack (alignment: .top)
        ├── modeContent(containerSize: geo.size)        ← unchanged
        ├── (loupe overlay if metalLoupe != nil)        ← unchanged
        └── VStack(spacing: 0)
              ├── ReaderToolbar(vm:, library:, onCloseFullscreen:)  ← NEW root
              │     └── GlassEffectContainer? + ZStack
              │           ├── HStack
              │           │     ├── Spacer(80)
              │           │     ├── LeadingCapsule  → ToolbarCapsule { … }
              │           │     ├── Spacer()
              │           │     └── TrailingCapsule → ToolbarCapsule { … }
              │           └── TransportCapsule (centred) → ToolbarCapsule { … }
              └── Divider()                              ← unchanged (or removed; TBD §10)
```

State flow is unchanged from today. Each capsule reads from `vm` / `library` and calls existing methods. `ReaderToolbar` itself owns no `@State`; everything is reactive via the existing `@StateObject` / `@EnvironmentObject` chain in `ReaderView`.

## 8. Testing approach

Manual / visual — UI-only change with no algorithmic logic. Build and verify:

1. **Material rendering**
   - macOS 26+ (current dev machine): each capsule shows real Liquid Glass — translucent, refractive, with edge highlight. Drag the loupe over the capsules; the Liquid Glass should pick up the comic content beneath. Hover each segment; the `.interactive(true)` should lift the highlight.
   - macOS 14–25 (any Sonoma/Sequoia mac, if available): `.ultraThinMaterial` capsule with hairline rim. Same geometry, same hit targets, no refraction.

2. **Geometry / regressions**
   - Window-resize: capsules vertically stay centred in the 38pt strip, transport stays horizontally centred.
   - All four reading modes: comic page geometry is unchanged (top is still inset by 38pt). The v0.10.1 single-page off-centre fix and v0.10.0 top-bar-bleed fix still hold — confirm by switching modes back-to-back.
   - Traffic lights: not visually overlapped by the leading capsule; full-screen toggle hides/shows the strip as before.

3. **Functional**
   - Each segment fires the same handler as today — verified by running the same keyboard/UI flows: prev-comic, prev-page, page-count text updates, next-page, next-comic, favorite toggle, ellipsis menu (Zoom / Reading Mode / Full Screen).
   - Disabled states: at first page → prev-page dimmed; at last page → next-page dimmed; in vertical modes → both single-page arrows dimmed; no adjacent comic → corresponding double-chevron dimmed.

4. **Edge cases**
   - Long page counts (`9999 / 9999`): the page-count segment's `.frame(minWidth: 72)` accommodates 4-digit numbers without jitter; verify with a large CBZ.
   - Window narrower than the sum of capsule widths: each `Spacer` collapses; if widths overflow, transport remains centred while leading/trailing get pushed to the edges (acceptable). The library spec doesn't constrain minimum window width any further.
   - Light mode: confirm the `Color.primary.opacity(0.12)` divider stays visible against bright comic backgrounds.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Liquid Glass material on macOS 26 conflicts with existing `.windowStyle(.hiddenTitleBar)` (e.g. drags through the transparent strip stop dragging the window). | The transparent strip retains hit-testing for traffic lights and window-drag via the existing `.toolbar(.hidden, for: .windowToolbar)` setup. Capsules use `.allowsHitTesting(true)` for buttons; the gap between them (and around them) stays draggable. Verify visually. |
| `GlassEffectContainer` API shape isn't quite what we expect. | Wrap availability check around the container too; on failure, fall back to a plain `Group { … }` and the capsules still each render their own `.glassEffect(...)` independently. |
| Comic page bleeds into the now-transparent strip if `topContentInset` arithmetic was actually relying on `TitlebarEffectView` opacity to mask the bleed. | Today's setup carves the strip from `metalLayer.frame` BEFORE intersecting with `docFrame` (v0.10.0 fix). The CAMetalLayer never renders into the top 38pt regardless of the SwiftUI background's opacity — verified by reading `MetalCanvasView.updateMetalLayerFrame()`. So this risk is moot, but we'll re-verify after the change. |
| `TitlebarEffectView` is referenced from somewhere else and deleting it breaks the build. | The plan step that cleans it up runs `grep -rn TitlebarEffectView Sources/` first and only deletes if `ReaderView.readerTopBar` was the sole call site. |
| macOS 14–25 fallback doesn't visually match the spirit of "Liquid Glass" closely enough. | Acceptable — the fallback is honest about being a fallback; the rim + ultra-thin material still give a clean, modern Mac feel. |

## 10. Open questions

1. **Divider under the strip.** Today there's a `Divider()` immediately below `readerTopBar` in the outer VStack. With Liquid Glass capsules and a transparent strip, the divider line may look out of place (a hairline floating in mid-air). **Default in this spec: keep the `Divider()` for now**; revisit visually in step "manual review" of the implementation plan and remove if it clashes. Reversible.
2. **Capsule shape — true pill vs. rounded-rectangle.** Spec assumes `Capsule()` (full pill, corner-radius = height/2). If the user prefers a 12pt rounded-rect, swap `Capsule()` → `RoundedRectangle(cornerRadius: 12)` in `ToolbarCapsule` and the matching `.glassEffect(in:)` shape. **Default: `Capsule()`.**
3. **Deployment target bump.** Stays at `.v14` for now; bump to `.v26` is a one-line follow-up if the user explicitly wants to drop the fallback path.

## 11. Out-of-scope / follow-ups

- A unified-glass morph effect where the three capsules merge into one super-capsule on hover (`glassEffectID` + `GlassEffectContainer.spacing` makes this trivial). Worth doing once the basic three-capsule version is approved.
- Adding a toolbar-only progress slider (current plan keeps page count as text).
- Adapting the library's grid view chrome to match.
- Removing `TitlebarEffectView` if the cleanup grep confirms it's the sole caller.
