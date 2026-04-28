# Gallery thumbnail-refresh decouple — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the gallery covers from flickering during fast scroll by decoupling per-card thumbnail refreshes from `LibraryViewModel`'s `@Published` state. A thumbnail decoded for card N must invalidate only card N — never every other observing view in the grid.

**Architecture:** Replace the `@Published var updatedThumbnailURLs: Set<URL>` + `pendingURLs` + `scheduleFlush` + dual-assignment trick with a single `PassthroughSubject<URL, Never>`. `LibraryViewModel.insertIntoCache` and `saveThumbnailAndCache` send one event per inserted URL. `ComicCard` and `ContinueReadingHero` subscribe via `.onReceive` and flip their `renderToken` only when the published URL matches their own. The subject does not fire `objectWillChange`, so unrelated cards stay rendered.

**Tech Stack:** Swift 5.10, Combine `PassthroughSubject`, SwiftUI `.onReceive`. macOS 14+.

**Plan version:** 1 — based on the live-debug trace at `2026-04-28 11:15:43–11:16:46` (~3 minutes of scrolling) where a fresh-cache scroll produced 200+ `[gthumb] render NIL` lines per second across 20+ cards per flush. Root cause: each batch flush mutated a `@Published Set<URL>` twice (`= []` then `= batch`), and `LibraryViewModel` is consumed via `@EnvironmentObject`, so every `objectWillChange` re-rendered every visible `ComicCard`, even ones whose thumbnail status was unchanged.

---

## File structure

| File | Role | Touched in tasks |
|---|---|---|
| `Sources/DC/ViewModels/LibraryViewModel.swift` | Owns the NSCache + emits per-URL refresh events. Adds `thumbnailUpdates` subject; removes `updatedThumbnailURLs` / `pendingURLs` / `flushScheduled` / `scheduleFlush()` / `flushThumbnailGeneration()`. Wires `insertIntoCache`, `saveThumbnailAndCache`, and the visible-URL branch of `generateThumbnailsParallel` to `thumbnailUpdates.send(url)`. | 1, 3, 4 |
| `Sources/DC/Views/LibraryView.swift` | `ComicCard` and `ContinueReadingHero` subscribers. Replace `.onChange(of: library.updatedThumbnailURLs)` with `.onReceive(library.thumbnailUpdates)`. | 2 |
| `CHANGELOG.md` | New `v0.11.1` entry. | 6 |
| `README.md` | Cache-layers section + the "library uses NSCache" prose. | 6 |
| `.agent/memory/working/WORKSPACE.md` | Current task + summary. | 6 |

No new files. No tests added (project has no test target; verification is a manual scroll-test against the symptom).

---

### Task 1: Add `thumbnailUpdates` subject to LibraryViewModel

**Files:**
- Modify: `Sources/DC/ViewModels/LibraryViewModel.swift` — top imports + new property near the existing `@Published` declarations (around line 66).

- [ ] **Step 1: Verify `Combine` is already imported.**

Run: `grep -n "^import" /Volumes/Media/DC_dev_lib/Sources/DC/ViewModels/LibraryViewModel.swift`

Expected: at least `import Foundation`, `import SwiftUI`. If `import Combine` is missing, add it after the existing imports.

- [ ] **Step 2: Add the subject as a non-published stored property.**

Locate the block of `@Published` declarations (currently at lines 55–66, ending with `@Published var updatedThumbnailURLs: Set<URL> = []`). Immediately after `updatedThumbnailURLs`, add:

```swift
/// Per-URL refresh signal for thumbnail availability. Cards subscribe
/// via `.onReceive(library.thumbnailUpdates)` and flip their render
/// token only when the emitted URL matches their own. This subject is
/// **not** `@Published` — sending an event does NOT fire
/// `objectWillChange`, so a thumbnail decoded for card N never
/// invalidates cards 1..N-1 / N+1..end. Eliminates the full-grid
/// re-render that surfaced as cover-flicker during fast scroll
/// (diagnosed 2026-04-28; see CHANGELOG v0.11.1).
let thumbnailUpdates = PassthroughSubject<URL, Never>()
```

- [ ] **Step 3: Build to confirm no compile errors.**

Run:

```bash
cd /Volumes/Media/DC_dev_lib && ./build_app.sh 2>&1 | tail -3
```

Expected: a line containing `Build complete!` and the bundle path. Warnings about the new field being unused are fine — it's wired in Task 2.

---

### Task 2: Migrate subscribers to `.onReceive`

**Files:**
- Modify: `Sources/DC/Views/LibraryView.swift` — `ComicCard.body` (around lines 1248–1252) and `ContinueReadingHero.body` (around lines 949–953).

The previous subscriber was:

```swift
.onChange(of: library.updatedThumbnailURLs) { _, urls in
    if urls.contains(url) { renderToken = UUID() }
}
```

The new subscriber is:

```swift
.onReceive(library.thumbnailUpdates) { updatedURL in
    if updatedURL == url { renderToken = UUID() }
}
```

- [ ] **Step 1: Update `ComicCard`.**

In `Sources/DC/Views/LibraryView.swift`, find the existing `.onAppear { library.requestThumbnail(for: url) }` line in `ComicCard.body` (around line 1248). The line directly below it is the `.onChange(of: library.updatedThumbnailURLs) { _, urls in ... }`. Replace just that `.onChange` with `.onReceive`:

```swift
.onAppear { library.requestThumbnail(for: url) }
.onReceive(library.thumbnailUpdates) { updatedURL in
    if updatedURL == url { renderToken = UUID() }
}
```

- [ ] **Step 2: Update `ContinueReadingHero`.**

Same swap in `ContinueReadingHero.body` (around line 949–952). Find:

```swift
.onAppear { library.requestThumbnail(for: url) }
.onChange(of: library.updatedThumbnailURLs) { _, urls in
    if urls.contains(url) { renderToken = UUID() }
}
```

Replace with:

```swift
.onAppear { library.requestThumbnail(for: url) }
.onReceive(library.thumbnailUpdates) { updatedURL in
    if updatedURL == url { renderToken = UUID() }
}
```

- [ ] **Step 3: Build to confirm.**

Run:

```bash
cd /Volumes/Media/DC_dev_lib && ./build_app.sh 2>&1 | tail -3
```

Expected: `Build complete!`. The build will still succeed at this point even though `updatedThumbnailURLs` is no longer subscribed-to — it's still a property on `LibraryViewModel` that gets mutated by `scheduleFlush`. That mutation is now wasted work; Task 3 removes it.

---

### Task 3: Wire publish-side to the subject; delete the old plumbing

**Files:**
- Modify: `Sources/DC/ViewModels/LibraryViewModel.swift` — `insertIntoCache`, `saveThumbnailAndCache`, the `generateThumbnailsParallel` visible-branch, `closeComic`, the `@Published updatedThumbnailURLs`, `pendingURLs`, `flushScheduled`, `scheduleFlush()`, `flushThumbnailGeneration()`. Plus the disk-fallback path inside `requestThumbnail`.

- [ ] **Step 1: Send via the subject from `insertIntoCache`.**

Find the existing implementation (around line 770–775):

```swift
func insertIntoCache(_ image: NSImage, for comicURL: URL) {
    let key = LibraryViewModel.thumbnailCacheKey(for: comicURL) as NSString
    let isNew = thumbnailCache.object(forKey: key) == nil
    thumbnailCache.setObject(image, forKey: key)
    if isNew { thumbnailCacheCount += 1 }
}
```

Append the subject send:

```swift
func insertIntoCache(_ image: NSImage, for comicURL: URL) {
    let key = LibraryViewModel.thumbnailCacheKey(for: comicURL) as NSString
    let isNew = thumbnailCache.object(forKey: key) == nil
    thumbnailCache.setObject(image, forKey: key)
    if isNew { thumbnailCacheCount += 1 }
    thumbnailUpdates.send(comicURL)
}
```

- [ ] **Step 2: Send via the subject from `saveThumbnailAndCache`.**

Find the existing tail of `saveThumbnailAndCache` (around line 798–799):

```swift
        // Notify only this card — no full-grid re-render.
        pendingURLs.insert(comicURL)
        scheduleFlush()
    }
```

Replace those three lines with:

```swift
        thumbnailUpdates.send(comicURL)
    }
```

- [ ] **Step 3: Update the disk-fallback in `requestThumbnail`.**

Find the `Task.detached(priority: .utility)` block inside `requestThumbnail` (around line 436–446):

```swift
        Task.detached(priority: .utility) { [weak self] in
            guard let img = LibraryViewModel.loadThumbnail(for: comicURL) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.insertIntoCache(img, for: comicURL)
                // Notify only this card — no full-grid re-render.
                self.pendingURLs.insert(comicURL)
                self.scheduleFlush()
            }
        }
```

`insertIntoCache` already sends via the subject after Step 1, so the `pendingURLs.insert + scheduleFlush` lines are now redundant. Remove them:

```swift
        Task.detached(priority: .utility) { [weak self] in
            guard let img = LibraryViewModel.loadThumbnail(for: comicURL) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.insertIntoCache(img, for: comicURL)
            }
        }
```

- [ ] **Step 4: Update the visible-cache branch in `generateThumbnailsParallel`.**

Find the inner `MainActor.run` at around line 405–420. Currently it ends:

```swift
                            self.thumbnailCache.setObject(thumb, forKey: key)
                            if isNew { self.thumbnailCacheCount += 1 }
                            // Notify only this card — no full-grid re-render.
                            self.pendingURLs.insert(url)
                            self.scheduleFlush()
                        }
```

Replace the trailing `pendingURLs.insert + scheduleFlush` with a subject send:

```swift
                            self.thumbnailCache.setObject(thumb, forKey: key)
                            if isNew { self.thumbnailCacheCount += 1 }
                            self.thumbnailUpdates.send(url)
                        }
```

- [ ] **Step 5: Remove `updatedThumbnailURLs.remove(url)` in `closeComic`.**

Find the block in `closeComic()` (around line 504–511):

```swift
        if let url = lastOpenedURL {
            addRecent(url: url)
            // Remove this URL from updatedThumbnailURLs so that when the card
            // reappears and requestThumbnail fires scheduleFlush, the Set value
            // genuinely changes and onChange triggers a re-render on the card.
            // Without this, the URL stays in the Set from the background thumbnail
            // generation that ran while the reader was open, and the subsequent
            // scheduleFlush produces no Set change — so onChange never fires.
            updatedThumbnailURLs.remove(url)
        }
```

The remove-from-Set workaround is no longer needed: `thumbnailUpdates` is a `PassthroughSubject` (not a stored value), so every `send()` reaches the subscriber, regardless of what was sent before. Replace the whole guarded block with:

```swift
        if let url = lastOpenedURL {
            addRecent(url: url)
        }
```

- [ ] **Step 6: Delete the dead `@Published` + helper plumbing.**

Remove the following declarations from `LibraryViewModel`:

- The `@Published var updatedThumbnailURLs: Set<URL> = []` block + its surrounding doc comment (around lines 62–66).
- `private var pendingURLs: Set<URL> = []` and `private var flushScheduled = false` (around lines 69–70).
- The entire `private func scheduleFlush()` (around lines 809–822).
- The entire `private func flushThumbnailGeneration()` (around lines 858–862).

Also delete the orphaned call site at the tail of `generateMissingThumbnails` (around line 352):

```swift
        await generateThumbnailsParallel(for: prioritised)
        await MainActor.run { flushThumbnailGeneration() }   ← delete this line
```

becomes:

```swift
        await generateThumbnailsParallel(for: prioritised)
```

The flush at end-of-generation is no longer needed: every individual `saveThumbnailAndCache` and the visible-cache branch in `generateThumbnailsParallel` already send via `thumbnailUpdates`, so by the time `generateThumbnailsParallel` returns, every URL has already been broadcast.

After deletion, Combine is no longer used by anything except `thumbnailUpdates`. Leave the `import Combine` in place.

- [ ] **Step 7: Build to confirm.**

Run:

```bash
cd /Volumes/Media/DC_dev_lib && ./build_app.sh 2>&1 | tail -3
```

Expected: `Build complete!`. If the compiler points at a residual reference to `updatedThumbnailURLs`, `pendingURLs`, `flushScheduled`, `scheduleFlush`, or `flushThumbnailGeneration`, fix that reference to use `thumbnailUpdates.send(...)` and rebuild.

---

### Task 4: Manual gallery scroll test

**Files:** none modified. This is a verification-only step.

The project has no test target for SwiftUI views; the diagnostic that originally surfaced this bug was a live trace at `[gthumb] render NIL`. The verification is a manual reproduction of the same scroll path and a visual + log check.

- [ ] **Step 1: Wipe the in-memory NSCache by killing the app.**

```bash
pkill -x DC 2>&1 || true
pkill -f "OpenComic.app/Contents/MacOS/DC" 2>&1 || true
sleep 1
pgrep -lf "OpenComic|/DC$" 2>&1
```

Expected: empty output (no DC process running).

- [ ] **Step 2: Reset the debug log.**

```bash
rm -f /tmp/dc_debug.log && touch /tmp/dc_debug.log
```

- [ ] **Step 3: Launch the freshly built app.**

```bash
open /Volumes/Media/DC_dev_lib/OpenComic.app && echo "launched at $(date '+%H:%M:%S')"
```

- [ ] **Step 4: Navigate to a large gallery and fast-scroll for ~10 seconds.**

Open the gallery that originally exhibited the symptom (the one with hundreds of comics — e.g. *Detective Comics*, *Batman*, *100 Bullets*). Scroll fast, then stop. Then scroll back up. Then back down.

- [ ] **Step 5: Verify visually.**

Pass criteria: covers do **not** "appear and then disappear again" after scroll stop. A card that has its thumbnail in cache shows the cover continuously through every batch flush; a card that doesn't have its thumbnail yet still shows a placeholder until its disk-load completes (this is correct lazy-loading behaviour and was never the bug).

If flicker is still visible: the fix is incomplete — return to Task 3 and verify every cache-write path now calls `thumbnailUpdates.send(...)`. Re-run the live `gthumb` log instrumentation if needed (the v0.10.x diagnostic in the previous session is the reference).

- [ ] **Step 6: Commit the code change.**

```bash
cd /Volumes/Media/DC_dev_lib && git add Sources/DC/ViewModels/LibraryViewModel.swift Sources/DC/Views/LibraryView.swift
```

Then write the commit message to a temp file (the body contains an apostrophe so a HEREDOC would need careful escaping; `-F` is safer):

```bash
cat > /tmp/dc_commit_msg.txt <<'EOF'
fix(library): decouple per-card thumbnail refresh from @Published

Replace `@Published var updatedThumbnailURLs: Set<URL>` and its
`pendingURLs` / `scheduleFlush` / dual-assignment-onto-the-Set
plumbing with a single `PassthroughSubject<URL, Never>`. Cards
subscribe via `.onReceive(library.thumbnailUpdates)` and flip their
renderToken only when the emitted URL matches their own.

The previous mechanism mutated a @Published property twice per flush
(`= []` then `= batch`), and `LibraryViewModel` is consumed via
@EnvironmentObject — so every flush re-rendered every visible
ComicCard via objectWillChange, regardless of whether the card's
thumbnail status had changed. During fresh-cache scroll across a
large gallery, cards that were merely WAITING for their disk-load
to complete re-rendered NIL on every neighbour's flush, surfacing
as the "covers appear and disappear" flicker the user reported on
2026-04-28.

PassthroughSubject does not fire objectWillChange. The new
mechanism only invalidates the specific card whose URL was just
inserted into the cache. Other cards stay rendered with whatever
they already had.

Files
- Sources/DC/ViewModels/LibraryViewModel.swift
  Added `thumbnailUpdates = PassthroughSubject<URL, Never>()`.
  Wired `insertIntoCache`, `saveThumbnailAndCache`, and the visible
  branch of `generateThumbnailsParallel` to `send(url)`.
  Deleted `@Published updatedThumbnailURLs`, `pendingURLs`,
  `flushScheduled`, `scheduleFlush()`, `flushThumbnailGeneration()`,
  and the `updatedThumbnailURLs.remove(url)` workaround in
  `closeComic`.
- Sources/DC/Views/LibraryView.swift
  ComicCard + ContinueReadingHero replaced
  `.onChange(of: library.updatedThumbnailURLs)` with
  `.onReceive(library.thumbnailUpdates)`. Same renderToken bump
  logic; only-when-URL-matches gate is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
git commit -F /tmp/dc_commit_msg.txt
```

Expected: the commit succeeds. `git log -1 --pretty=format:"%h %s"` shows `<hash> fix(library): decouple per-card thumbnail refresh from @Published`.

---

### Task 5: Verify no regressions in adjacent cache flows

**Files:** none modified. Verification-only step covering the three other code paths that touched the old `pendingURLs`/`scheduleFlush` mechanism.

- [ ] **Step 1: Open a comic from the library.**

Launch / reuse the running app, click a comic, confirm the reader opens, then close the reader (back arrow / `Esc`). The card you just opened should be visible in the gallery without any flicker — `closeComic`'s removal of `updatedThumbnailURLs.remove(url)` (Task 3 step 5) means the card no longer relies on the old Set-mutation trick. The thumbnail is still in cache; `cachedThumbnail(for: url)` still returns it; the card re-renders cleanly.

- [ ] **Step 2: Trigger a thumbnail-generation pass for an unseen comic.**

Add a new comic to the library that isn't yet thumbnail-cached on disk (or use *Library → Clear All Cache…* and confirm). After the cache wipe, the gallery's cards initially show placeholders. As `generateMissingThumbnails` runs in the background, cards should fill in one-by-one without any other card flickering.

- [ ] **Step 3: Switch from a small gallery to a large one and back.**

Click between two galleries with very different sizes. Confirm: no stale placeholders, no flicker spike on the gallery switch. SwiftUI tears down the previous LazyVGrid and builds the new one; each new card runs `onAppear → requestThumbnail`, which hits the cache for previously-loaded thumbnails and renders immediately.

- [ ] **Step 4: If any of the above misbehaves, revert and re-investigate.**

```bash
cd /Volumes/Media/DC_dev_lib && git revert HEAD
```

Then re-instrument with the same `[gthumb]` log points used in the original diagnostic session and re-run.

---

### Task 6: Update CHANGELOG / README / WORKSPACE

**Files:**
- Modify: `CHANGELOG.md` (new entry at top).
- Modify: `README.md` (caching-layers section).
- Modify: `.agent/memory/working/WORKSPACE.md` (current task).

- [ ] **Step 1: Add `v0.11.1` entry to `CHANGELOG.md`.**

Insert immediately under the `# DC Reader — Changelog` header, above the existing `## v0.11.0` entry:

```markdown
## v0.11.1 — 2026-04-28 — Gallery thumbnail refresh decoupled from @Published

### Fixed
- **Gallery covers flickered during fast scroll on a fresh-cache library** — the previous thumbnail-refresh mechanism mutated a `@Published var updatedThumbnailURLs: Set<URL>` twice per batch flush (`= []` then `= batch` — a workaround so `onChange` would fire even when the new batch contained a URL from a previous flush). `LibraryViewModel` is consumed via `@EnvironmentObject`, so every `objectWillChange` re-rendered every visible `ComicCard`. Cards waiting for their own disk-load to complete re-rendered NIL on every neighbour's flush, which the user perceived as covers "appearing and disappearing" while/just-after scrolling. Diagnosed via per-event live debug at `2026-04-28 11:15:43–11:16:46`; trace showed 200+ `[gthumb] render NIL` lines per second across 20+ cards per flush during cache warm-up.

### Changed
- **`LibraryViewModel.thumbnailUpdates: PassthroughSubject<URL, Never>`** — replaces the `@Published Set<URL>` mechanism. `insertIntoCache`, `saveThumbnailAndCache`, and the visible-cache branch of `generateThumbnailsParallel` send one event per inserted URL. The subject is **not** `@Published`, so sending an event does not fire `objectWillChange` — a thumbnail decoded for card N never invalidates cards 1..N-1 / N+1..end.
- **`ComicCard` and `ContinueReadingHero`** subscribe via `.onReceive(library.thumbnailUpdates)` instead of `.onChange(of: library.updatedThumbnailURLs)`. The `if updatedURL == url { renderToken = UUID() }` gate is unchanged; only the publisher and the trigger site moved.

### Removed
- `@Published var updatedThumbnailURLs: Set<URL>`, `private var pendingURLs: Set<URL>`, `private var flushScheduled: Bool`, `private func scheduleFlush()`, `private func flushThumbnailGeneration()` — all obsolete with the per-URL subject.
- `updatedThumbnailURLs.remove(url)` workaround in `closeComic()` — `PassthroughSubject` always delivers `send()` to subscribers regardless of prior emissions, so the Set-mutation workaround that ensured `onChange` would fire is no longer needed.
```

- [ ] **Step 2: Update the cache-layers section in `README.md`.**

Find the line near line 64 that currently reads:

```markdown
| `MetalPageManager` | Actor holding decoded `CVPixelBuffer`s (10-entry LRU) + parallel nonisolated `NSCache<NSNumber, NSImage>` (cap 10). Shared across all reading modes. `nsImage(for:)` fast-path for the loupe; `prefetch(around:pages:)` decodes the surrounding window. |
```

After it, locate the existing `LibraryViewModel`-cache caption (the README mentions "NSCache thumbnails 600-cap + disk fallback"). Replace any reference to `updatedThumbnailURLs` / `scheduleFlush` with the new subject. Specifically, if there's a sentence like *"Cards observe `updatedThumbnailURLs` and re-render only when their own URL is present"*, change it to:

> Cards subscribe to `library.thumbnailUpdates` (a `PassthroughSubject<URL, Never>`) via `.onReceive` and flip their internal `renderToken` only when the emitted URL matches their own. The subject is not `@Published`, so a thumbnail-cache write does not re-render unrelated cards.

If no such README section exists yet, add one paragraph under the *Caching layers* heading describing the per-URL refresh path.

- [ ] **Step 3: Update WORKSPACE.md.**

In `.agent/memory/working/WORKSPACE.md`, replace the `## Current task` block at the top with:

```markdown
## Current task
**v0.11.1 shipped.** Gallery thumbnail refresh decoupled from `@Published` — `PassthroughSubject<URL, Never>` replaces the dual-assignment `updatedThumbnailURLs` Set. Per-URL invalidation only; no full-grid re-render on cache writes. CHANGELOG + README updated.

## What shipped in v0.11.1 (2026-04-28)
- `LibraryViewModel.thumbnailUpdates = PassthroughSubject<URL, Never>()` added; `insertIntoCache`, `saveThumbnailAndCache`, and the visible branch of `generateThumbnailsParallel` send per-URL events.
- `ComicCard` and `ContinueReadingHero` subscribe via `.onReceive(library.thumbnailUpdates)` instead of `.onChange(of: library.updatedThumbnailURLs)`.
- Removed: `@Published updatedThumbnailURLs`, `pendingURLs`, `flushScheduled`, `scheduleFlush()`, `flushThumbnailGeneration()`, and the `updatedThumbnailURLs.remove(url)` workaround in `closeComic`.
- Diagnosed via live `[gthumb]` event log at 2026-04-28 11:15:43–11:16:46 (cache warmed from 25 to 1210 entries; 20+ `render NIL` per flush across uninvolved cards). Instrumentation removed before final build.
```

- [ ] **Step 4: Commit docs.**

```bash
cd /Volumes/Media/DC_dev_lib && git add CHANGELOG.md README.md .agent/memory/working/WORKSPACE.md
cat > /tmp/dc_commit_msg.txt <<'EOF'
docs(library): v0.11.1 changelog + README + WORKSPACE for thumbnail-refresh decouple

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
git commit -F /tmp/dc_commit_msg.txt
```

Expected: commit succeeds; `git log -2 --pretty=format:"%h %s"` shows the docs commit on top of the code commit from Task 4.

---

## Acceptance criteria

The plan is complete when ALL of the following hold:

1. `swift build -c release` (via `./build_app.sh`) succeeds with no compile errors.
2. `git grep -n "updatedThumbnailURLs\|pendingURLs\|flushScheduled\|scheduleFlush\|flushThumbnailGeneration"` in `Sources/` returns zero matches.
3. The manual scroll test in Task 4 step 5 shows no flicker — covers that have their thumbnail in cache stay rendered through every batch flush.
4. The three regression checks in Task 5 pass (open/close comic, fresh-cache thumbnail generation, gallery switch).
5. `CHANGELOG.md`, `README.md`, and `.agent/memory/working/WORKSPACE.md` are updated.
6. Two commits land on `main`: the code change and the docs change.

## Risks & rollback

| Risk | Likelihood | Mitigation |
|---|---|---|
| `.onReceive` doesn't fire on the same run-loop tick that `.onChange` did, breaking some card-update timing assumption. | Low. `.onReceive` and `.onChange` both deliver on the main run loop in SwiftUI; in practice timing is identical for this synchronous-publish use case. | If a card stays placeholder after its disk-load completes, log inside the new `.onReceive` closure to confirm the URL arrives, then check `cachedThumbnail(for: url)` returns non-nil in the same render pass. |
| `thumbnailUpdates.send(...)` is called from a non-main thread somewhere I missed. | Low. The three call sites all happen inside `await MainActor.run { ... }` blocks. | If a runtime warning fires about main-thread updates, hop to main: `DispatchQueue.main.async { [weak self] in self?.thumbnailUpdates.send(url) }`. |
| `closeComic`'s removed `updatedThumbnailURLs.remove(url)` regresses the original "card stays blank when reading-mode resumes" symptom that workaround was added for. | Low. The workaround existed only because the same URL appearing in two consecutive Set values would fail to fire `onChange` (since Set equality wouldn't change). `PassthroughSubject.send()` always delivers to subscribers, so the underlying race is moot. | Task 5 step 1 (open/close comic) is the smoke test for this exact path. |
| `git revert HEAD` after a bad fix doesn't fully restore subscribers if downstream views were edited mid-flight. | Very low. Tasks 1–3 are atomic per file; the commit in Task 4 step 6 is one logical unit. | Use `git revert HEAD` not `git reset` so the history is preserved. |

If 3+ regressions surface, return to Phase 1 (Root Cause) — do not attempt a fourth fix on top.
