# Unify Reader Decode Cache (Step B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire `PageImageCache` so all four reading modes (single / double / vertical / vertical-double) decode through a single shared `MetalPageManager` instance, cutting the reader's cache surface from two stores to one.

**Architecture:** `MetalPageManager` gains a parallel `NSCache<NSNumber, NSImage>` on top of its existing `CVPixelBuffer` ring (10-page LRU), plus a `prefetch(around:pages:)` API and an `onPageReadyNSImage` callback that mirrors what `PageImageCache` used to provide. `ReaderViewModel` holds a single `MetalPageManager` instance and injects it into `MetalPageView`; `MetalPageView` stops creating its own manager. `ZoomableImageView` and `SpreadView` keep SwiftUI rendering — only the NSImage source changes.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit, `NSVisualEffectView`, `NSCache`, Swift actors, `CGImageSource`. No external deps added.

**Spec:** `docs/superpowers/specs/2026-04-23-unify-decode-cache-step-b-design.md`

**Rollback:** `/Volumes/Media/DC_dev_lib_backup_20260423_234635/` (full source + `.app`, binary SHA `eaf84360…`).

**Build + verify:** No unit-test harness exists. Each task verifies via `swift build -c release 2>&1 | grep -E "error:"` producing no output, plus targeted `grep` checks on source state, plus (for later tasks) manual launch of `OpenComic.app` with `/tmp/dc_debug.log` inspection.

---

## File structure

Files touched by this plan:

| File | Role |
|---|---|
| `Sources/DC/ViewModels/MetalPageManager.swift` | Add NSImage cache, `nsImage(for:)`, `prefetch(around:pages:)`, `onPageReadyNSImage` callback, LRU-coupled eviction. |
| `Sources/DC/ViewModels/ReaderViewModel.swift` | Delete `PageImageCache` actor class; replace `let imageCache = PageImageCache()` with `let pageManager = MetalPageManager()`; rewire `currentImage`, `image(for:)`, `triggerPrefetch()`, and the callback binding. |
| `Sources/DC/Views/ReaderView.swift` | Swap `imageCache: vm.imageCache` call-site argument for `pageManager: vm.pageManager`. |
| `Sources/DC/Views/MetalPageView.swift` | Replace `imageCache: PageImageCache?` parameter with `pageManager: MetalPageManager`. Remove the local `MetalPageManager()` creation in `makeNSView`. Remove `Coordinator.imageCache`; switch loupe fast path to `pageManager.nsImage(for:)`. |

The plan keeps the build green after every task by layering additions before removals.

---

## Task 1: Expose the CVPixelBuffer → NSImage converter

`MetalPageView.swift:820` has a `Coordinator.nsImage(from: CVPixelBuffer)` static helper. `MetalPageManager` needs the same logic to populate its new NSImage cache. Simplest approach: lift it to a file-level internal helper in `MetalPageManager.swift` so the manager can call it directly; leave the existing `Coordinator.nsImage(from:)` in `MetalPageView.swift` forwarding to it so no v0.8.2 behaviour changes.

**Files:**
- Modify: `Sources/DC/ViewModels/MetalPageManager.swift` (add helper)
- Modify: `Sources/DC/Views/MetalPageView.swift:820-849` (forward to shared helper)

- [ ] **Step 1.1: Add the shared helper to `MetalPageManager.swift`**

Append at the end of the file (after the actor's closing brace):

```swift
/// Converts a 32BGRA `CVPixelBuffer` into an `NSImage` by snapshotting the
/// pixel memory into a `CGImage`. Shared between `MetalPageManager` (which
/// populates its NSImage cache after decode) and `MetalPageView.Coordinator`
/// (which uses it for the vertical-mode loupe fallback).
///
/// Safe to call from any actor — it reads locked CVPixelBuffer bytes and
/// produces a value-type NSImage that outlives the source buffer.
func makeNSImageFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> NSImage? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0 else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    guard let ctx = CGContext(
        data: baseAddress,
        width: width, height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ),
          let cgImage = ctx.makeImage() else { return nil }

    return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
}
```

Add at the top of `MetalPageManager.swift`:

```swift
import AppKit
```

- [ ] **Step 1.2: Point `MetalPageView.Coordinator.nsImage(from:)` at the helper**

Replace `Sources/DC/Views/MetalPageView.swift` around line 820 — replace the entire body of `nsImage(from:)` with:

```swift
nonisolated private static func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
    return makeNSImageFromPixelBuffer(pixelBuffer)
}
```

- [ ] **Step 1.3: Build and confirm no behaviour change**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected output: (empty — no errors).

```bash
cd /Volumes/Media/DC_dev_lib && grep -c "makeNSImageFromPixelBuffer" Sources/DC/Views/MetalPageView.swift Sources/DC/ViewModels/MetalPageManager.swift
```

Expected: `Sources/DC/Views/MetalPageView.swift:1` and `Sources/DC/ViewModels/MetalPageManager.swift:1` (each file names the helper once).

- [ ] **Step 1.4: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/ViewModels/MetalPageManager.swift Sources/DC/Views/MetalPageView.swift && git commit -m "refactor(reader): extract shared CVPixelBuffer→NSImage converter"
```

---

## Task 2: Add NSImage cache + `nsImage(for:)` read to `MetalPageManager`

Parallel `NSCache<NSNumber, NSImage>` (countLimit 10). Populated lazily from the CVPixelBuffer cache after each decode. Nonisolated read for SwiftUI-fast-path access.

**Files:**
- Modify: `Sources/DC/ViewModels/MetalPageManager.swift`

- [ ] **Step 2.1: Declare the parallel NSImage cache**

Inside the `actor MetalPageManager` body, near the other storage fields (at the top, after `maxCachedPages`), add:

```swift
    /// Parallel NSImage cache derived from `decodedPages`. Populated lazily
    /// after each decode. Actor-state is the CVPixelBuffer dict; this is a
    /// nonisolated NSCache read from any context (SwiftUI render paths).
    /// Evicted in lockstep with the CVPixelBuffer when `store(...)` crosses
    /// the LRU cap or `evictOutside(_:)` runs.
    nonisolated let nsImageCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 10
        return cache
    }()
```

- [ ] **Step 2.2: Add the nonisolated fast-path read**

In the actor body, under the `// MARK: - Per-source decoders` line (around the `page(for:)` region) or at the end before the `// MARK: - Per-source decoders` marker, add:

```swift
    /// O(1) NSImage lookup — returns the pre-converted NSImage if present,
    /// or nil if nothing is decoded for that page yet. Intended for SwiftUI
    /// render paths that need to bail and wait for the `onPageReadyNSImage`
    /// callback to trigger a re-render.
    nonisolated func nsImage(for pageIndex: Int) -> NSImage? {
        nsImageCache.object(forKey: NSNumber(value: pageIndex))
    }
```

- [ ] **Step 2.3: Populate NSImage cache after every decode**

In the actor body, modify `store(_ buffer: CVPixelBuffer, for pageIndex: Int)`:

```swift
    private func store(_ buffer: CVPixelBuffer, for pageIndex: Int) {
        if decodedPages.count >= maxCachedPages {
            if let lruKey = lastAccessTimes.min(by: { $0.value < $1.value })?.key {
                decodedPages.removeValue(forKey: lruKey)
                lastAccessTimes.removeValue(forKey: lruKey)
                nsImageCache.removeObject(forKey: NSNumber(value: lruKey))
            }
        }
        decodedPages[pageIndex] = buffer
        lastAccessTimes[pageIndex] = Date()

        // Populate the parallel NSImage cache so SwiftUI render paths have a
        // synchronous hit on the next render pass.
        if let image = makeNSImageFromPixelBuffer(buffer) {
            nsImageCache.setObject(image, forKey: NSNumber(value: pageIndex))
        }
    }
```

- [ ] **Step 2.4: Couple `evictOutside` to the NSImage cache**

In the actor body, replace `evictOutside(_:)` with:

```swift
    func evictOutside(_ range: ClosedRange<Int>) {
        let survivors = decodedPages.keys.filter { range.contains($0) }
        let evicted = Set(decodedPages.keys).subtracting(survivors)
        decodedPages = decodedPages.filter { range.contains($0.key) }
        lastAccessTimes = lastAccessTimes.filter { range.contains($0.key) }
        for key in evicted {
            nsImageCache.removeObject(forKey: NSNumber(value: key))
        }
    }
```

- [ ] **Step 2.5: Build cleanly**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: (empty).

```bash
cd /Volumes/Media/DC_dev_lib && grep -c "nsImageCache" Sources/DC/ViewModels/MetalPageManager.swift
```

Expected: `4` (declaration, fast-path read, store site, evict site).

- [ ] **Step 2.6: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/ViewModels/MetalPageManager.swift && git commit -m "feat(MetalPageManager): parallel NSImage cache + nsImage(for:) read"
```

---

## Task 3: Add `prefetch(around:pages:)` + `onPageReadyNSImage` callback

API shape mirrors what `PageImageCache.prefetch(around:pages:)` + `onPageReadySwiftUI` used to do. Fire-and-forget from any context; schedules decodes for `[center-1 … center+3]`; calls the main-actor callback on each successful decode+convert.

**Files:**
- Modify: `Sources/DC/ViewModels/MetalPageManager.swift`

- [ ] **Step 3.1: Declare the callback**

Near the other nonisolated members, add:

```swift
    /// Fires on the main actor after a decode-and-convert completes during
    /// `prefetch(around:pages:)`. Consumers (e.g. `ReaderViewModel`) use this
    /// to bump a `@Published` SwiftUI counter so the reader re-renders.
    nonisolated(unsafe) var onPageReadyNSImage: ((Int, NSImage) -> Void)?
```

- [ ] **Step 3.2: Declare constants**

Near the other private constants (top of actor body, after `maxCachedPages = 10`):

```swift
    /// Prefetch-window shape: how many pages behind and ahead of centre to
    /// decode. Matches the old `PageImageCache` window so the user-visible
    /// prefetch radius is unchanged.
    private let lookBehind = 1
    private let lookAhead  = 3
```

- [ ] **Step 3.3: Add the prefetch entry point and its async core**

Near the end of the actor body (above the closing `}` of the actor), add:

```swift
    /// Fire-and-forget prefetch for `[center - lookBehind … center + lookAhead]`.
    /// Safe to call from any context. Evicts anything outside the window
    /// after scheduling.
    nonisolated func prefetch(around center: Int, pages: [ComicPage]) {
        Task { [weak self] in
            await self?._prefetchAround(center: center, pages: pages)
        }
    }

    private func _prefetchAround(center: Int, pages: [ComicPage]) async {
        let lo = max(0, center - lookBehind)
        let hi = min(pages.count - 1, center + lookAhead)
        guard lo <= hi else { return }
        let window = lo...hi

        evictOutside(window)

        for i in window {
            if decodedPages[i] != nil { continue }
            if pendingPages.contains(i) { continue }
            let source = pages[i].source
            guard let buffer = await decodePage(pageIndex: i, from: source),
                  let image  = nsImage(for: i) else { continue }

            if let cb = onPageReadyNSImage {
                await MainActor.run { cb(i, image) }
            }
        }
    }
```

- [ ] **Step 3.4: Build cleanly**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: (empty).

```bash
cd /Volumes/Media/DC_dev_lib && grep -cE "prefetch\(around:|onPageReadyNSImage" Sources/DC/ViewModels/MetalPageManager.swift
```

Expected: `4` (2 mentions of `prefetch(around:` — the entry + the async core's invocation, plus 2 mentions of `onPageReadyNSImage`).

- [ ] **Step 3.5: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/ViewModels/MetalPageManager.swift && git commit -m "feat(MetalPageManager): prefetch(around:pages:) + onPageReadyNSImage"
```

---

## Task 4: Inject `MetalPageManager` into `MetalPageView`

Today `MetalPageView.makeNSView` creates a local `MetalPageManager()` (line 51). Change it to take one via the initialiser so the reader VM can own the one shared instance. Swap `imageCache: PageImageCache?` for `pageManager: MetalPageManager`.

**Files:**
- Modify: `Sources/DC/Views/MetalPageView.swift`
- Modify: `Sources/DC/Views/ReaderView.swift:171` (call-site)

- [ ] **Step 4.1: Swap the parameter on `MetalPageView`**

In `Sources/DC/Views/MetalPageView.swift`, replace the property near line 17:

```swift
    weak var imageCache: PageImageCache?
```

with:

```swift
    let pageManager: MetalPageManager
```

- [ ] **Step 4.2: Wire it into the coordinator and drop the local `MetalPageManager()`**

In `makeNSView`, replace the block around lines 50-57 — the `let manager = MetalPageManager()` plus the `context.coordinator.imageCache = imageCache` line:

```swift
        context.coordinator.scrollView = scrollView
        context.coordinator.metalView = metalView
        context.coordinator.renderer = renderer
        context.coordinator.pageManager = pageManager
```

Remove entirely:

- the `let manager = MetalPageManager()` line, and
- the `context.coordinator.imageCache = imageCache` line.

- [ ] **Step 4.3: Delete the Coordinator's `imageCache` field**

Around line 258 delete:

```swift
        weak var imageCache: PageImageCache?
```

- [ ] **Step 4.4: Switch the loupe fast-path to `pageManager.nsImage`**

Around line 694, change:

```swift
            if let img = imageCache?.image(for: seqIdx) {
```

to:

```swift
            if let img = pageManager.nsImage(for: seqIdx) {
```

- [ ] **Step 4.5: Update the `MetalPageView` construction site in `ReaderView`**

`Sources/DC/Views/ReaderView.swift:171`. Replace:

```swift
                imageCache: vm.imageCache,
```

with:

```swift
                pageManager: vm.pageManager,
```

(Note — `vm.pageManager` is introduced in Task 5. This step will fail to build until Task 5 lands. Commit only after Task 5's Step 5.1 is done and the build is clean.)

- [ ] **Step 4.6: Hold commit**

Do not commit yet — the build will be broken until Task 5's VM changes land. This task's changes will be committed together with Task 5 in Step 5.7.

---

## Task 5: Swap `PageImageCache` out of `ReaderViewModel` for `MetalPageManager`

**Files:**
- Modify: `Sources/DC/ViewModels/ReaderViewModel.swift`

- [ ] **Step 5.1: Replace the `imageCache` field declaration**

At line 238 replace:

```swift
    let imageCache = PageImageCache()
```

with:

```swift
    /// Shared decode cache for every reading mode (single, double, vertical,
    /// vertical-double). Owns both the CVPixelBuffer ring and the NSImage
    /// fast-path cache. Injected into `MetalPageView` so vertical modes use
    /// the same instance the single/double path reads from.
    let pageManager = MetalPageManager()
```

- [ ] **Step 5.2: Update `currentImage`**

Find `currentImage` around line 244 (inside the `ReaderViewModel` class):

```swift
    var currentImage: NSImage? {
        imageCache.image(for: currentPage)
    }
```

Replace with:

```swift
    var currentImage: NSImage? {
        pageManager.nsImage(for: currentPage)
    }
```

- [ ] **Step 5.3: Update `image(for:)`**

Around line 249:

```swift
    func image(for index: Int) -> NSImage? {
        imageCache.image(for: index)
    }
```

Replace with:

```swift
    func image(for index: Int) -> NSImage? {
        pageManager.nsImage(for: index)
    }
```

- [ ] **Step 5.4: Rewire the callback binding**

Around line 281 — the old binding site is:

```swift
        imageCache.onPageReadySwiftUI = { [weak self] index, _ in
            guard let self = self else { return }
            if index == self.currentPage || index == self.currentPage + 1 {
                self.cacheVersion += 1
            }
        }
```

Replace with:

```swift
        pageManager.onPageReadyNSImage = { [weak self] index, _ in
            guard let self = self else { return }
            // Only bump for pages SwiftUI is actively rendering — the current
            // page, and the current + 1 slot for double-page mode. Prefetched
            // far-neighbours should not trigger re-renders.
            if index == self.currentPage || index == self.currentPage + 1 {
                self.cacheVersion += 1
            }
        }
```

- [ ] **Step 5.5: Update `triggerPrefetch`**

Around line 294:

```swift
        imageCache.prefetch(around: currentPage, pages: comic.pages)
```

Replace with:

```swift
        pageManager.prefetch(around: currentPage, pages: comic.pages)
```

- [ ] **Step 5.6: Build cleanly**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: (empty).

If the build errors with "use of unresolved identifier `PageImageCache`" anywhere — those call sites have to be migrated too. Run:

```bash
cd /Volumes/Media/DC_dev_lib && grep -rn "PageImageCache\|imageCache" Sources/ --include="*.swift"
```

The only matches should be inside the still-alive `actor PageImageCache { ... }` class definition at `Sources/DC/ViewModels/ReaderViewModel.swift:16-220` (removed in Task 6).

- [ ] **Step 5.7: Commit (bundles Task 4 + Task 5)**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/Views/MetalPageView.swift Sources/DC/Views/ReaderView.swift Sources/DC/ViewModels/ReaderViewModel.swift && git commit -m "feat(reader): route single/double page through shared MetalPageManager"
```

---

## Task 6: Delete the `PageImageCache` class

Now unreferenced outside its own definition. Safe to remove.

**Files:**
- Modify: `Sources/DC/ViewModels/ReaderViewModel.swift` (deletion)

- [ ] **Step 6.1: Confirm nothing references it**

```bash
cd /Volumes/Media/DC_dev_lib && grep -rn "PageImageCache" Sources/ --include="*.swift"
```

Expected: all matches should be inside the `PageImageCache` class definition or its doc comment block. No `-> PageImageCache`, no `: PageImageCache`, no `PageImageCache()` construction sites outside the class itself.

- [ ] **Step 6.2: Remove the class**

In `Sources/DC/ViewModels/ReaderViewModel.swift`, delete the entire block from the leading `// MARK: - Page Image Cache` comment (around line 4) through the closing brace of `actor PageImageCache { ... }` (around line 220). The next line after the deletion should be `// MARK: - ReaderViewModel` (around line 222 in the old numbering).

- [ ] **Step 6.3: Build cleanly**

```bash
cd /Volumes/Media/DC_dev_lib && swift build -c release 2>&1 | grep -E "error:"
```

Expected: (empty).

```bash
cd /Volumes/Media/DC_dev_lib && grep -c "PageImageCache" Sources/DC/ViewModels/ReaderViewModel.swift
```

Expected: `0`.

- [ ] **Step 6.4: Commit**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/ViewModels/ReaderViewModel.swift && git commit -m "refactor(reader): delete PageImageCache — single decode cache lands"
```

---

## Task 7: Build the `.app` and run manual verification

`build_app.sh` produces `OpenComic.app`. The four smoke cases below cover every `PageSource` variant (`.zipData`, `.file`, `.pdf`) and all four reading modes, plus the loupe.

**Files:** no source edits.

- [ ] **Step 7.1: Build the `.app`**

```bash
cd /Volumes/Media/DC_dev_lib && ./build_app.sh 2>&1 | tail -6
```

Expected final line: `Done: /Volumes/Media/DC_dev_lib/OpenComic.app`.

- [ ] **Step 7.2: Clear the log and launch**

```bash
rm -f /tmp/dc_debug.log
open /Volumes/Media/DC_dev_lib/OpenComic.app
```

- [ ] **Step 7.3: Smoke test — CBZ in single-page mode**

Open any `.cbz` from the library. The first page must render within ~1 second. Click next, then prev. Flip to double-page mode. Flip to vertical. Flip to vertical-double. All four modes must show actual page content (not black, not a spinner that never completes).

```bash
grep -Ec "FAIL|error" /tmp/dc_debug.log || echo "0 errors"
```

Expected: `0 errors`.

- [ ] **Step 7.4: Smoke test — CBR in single-page mode**

Open a `.cbr` from the library (format fans out via `unar` to `.file(URL)`). Single-page mode must show the page. Switch to vertical — still renders. Regression anchor: the v0.8.2 fix for vertical CBR decoding must survive the decode-cache swap.

- [ ] **Step 7.5: Smoke test — PDF in single-page mode**

Open a `.pdf`. Pages render on white backgrounds (not black). The zoom slider and fit-to-width still function.

- [ ] **Step 7.6: Smoke test — mode switch stability**

With a comic open, cycle through all four modes three times: Single → Double → Vertical → VerticalDouble → Single. Every transition renders within a couple of seconds. No double-decode storms in the log:

```bash
grep -c "PREFETCH QUEUE" /tmp/dc_debug.log
```

(Expected: a modest number — on the order of the number of pages that passed through the active window during the test, not hundreds per mode-switch.)

- [ ] **Step 7.7: Smoke test — loupe**

Right-click-hold on a page in each of the four modes. The 1.45× circular magnifier must show the correct region under the cursor. Drag the cursor across pages — the loupe tracks. Release — loupe disappears. No stale cursor-hidden state.

- [ ] **Step 7.8: Memory sanity**

Enable the debug memory bar (the memory chip icon in the library pane toolbar). Open a 50+ page CBZ, scroll through all pages in vertical mode, then switch to single-page and flip through 10 pages. Resident memory should stabilise near the pre-change baseline (roughly ~250-400 MB depending on screen resolution and page pixel dimensions). Single-digit-MB growth between mode switches is fine; 100+ MB growth on each switch means a regression.

- [ ] **Step 7.9: Commit verification notes if any issues found**

If steps 7.3-7.8 reveal issues, create a short markdown note under `docs/superpowers/plans/2026-04-23-unify-decode-cache-step-b-verification.md` summarising what failed, then stop and escalate. If everything passes, no commit needed — the plan is done.

---

## Self-review against the spec

| Spec requirement | Covered by |
|---|---|
| `MetalPageManager.nsImage(for:)` nonisolated O(1) read | Task 2.2 |
| `MetalPageManager.prefetch(around:pages:)` fire-and-forget | Task 3.3 |
| `onPageReadyNSImage` callback fires on MainActor | Task 3.3 (`await MainActor.run`) |
| NSImage cache evicted with CVPixelBuffer on LRU overflow | Task 2.3 (`store` touches `nsImageCache`) |
| NSImage cache evicted with `evictOutside(_:)` | Task 2.4 |
| `ReaderViewModel.currentImage` / `image(for:)` swap | Task 5.2, 5.3 |
| `triggerPrefetch` swap | Task 5.5 |
| `cacheVersion` bump limited to current + next page | Task 5.4 (filter preserved from old wiring) |
| `MetalPageView` takes `pageManager:` not `imageCache:` | Task 4.1 |
| `MetalPageView` stops constructing its own `MetalPageManager` | Task 4.2 (removal of `let manager = MetalPageManager()`) |
| Loupe fast-path uses `pageManager.nsImage(for:)` | Task 4.4 |
| `PageImageCache` deleted | Task 6.2 |
| Rollback recipe noted | Plan header |
| Manual verification for all four modes | Task 7.3-7.8 |
| CBR / PDF regression coverage | Task 7.4, 7.5 |

No gaps against the spec's "Target architecture" or "Component contracts" sections. No TBDs. No "similar to earlier task" shortcuts — each code snippet is complete and self-contained.

**Ready for execution.**
