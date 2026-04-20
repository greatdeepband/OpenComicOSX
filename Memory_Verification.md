# Memory Ring Buffer Verification

**Status: VERIFIED** | Build: ✅ Clean

This document confirms the two-ring GPU memory architecture is correctly wired and evicting.

---

## Architecture Overview

The app uses a **two-ring design** for memory-efficient comic page rendering:

```
[ComicPage.source]
        │
        ▼ (decode)
MetalPageManager (actor)          ← Ring 1: CVPixelBuffer (decoded images)
  decodedPages: [Int: CVPixelBuffer]   maxCachedPages = 10
  lastAccessTimes: [Int: Date]          LRU eviction via lastAccessTimes.min()
        │
        │ pageManager.page(for:)         ← fetch from ring 1
        ▼
MetalPageRenderer                  ← Ring 2: MTLTexture (uploaded to GPU)
  textureRing: TextureRingBuffer         maxSize = 10
  entries: [Int: (texture, lastAccess)]  LRU eviction via entries.min()
        │
        │ renderer.render()                ← draw to CAMetalLayer drawable
        ▼
  CAMetalLayer (GPU)
```

Both rings are **10-page capped** with **true LRU eviction** (by access timestamp, not arbitrary dictionary order).

---

## Ring 1: `MetalPageManager` (Actor)

**File:** `Sources/DC/ViewModels/MetalPageManager.swift`

| Property | Type | Notes |
|---|---|---|
| `decodedPages` | `[Int: CVPixelBuffer]` | Decoded pixel buffers, keyed by sequential index |
| `lastAccessTimes` | `[Int: Date]` | Access timestamps for LRU eviction |
| `pendingPages` | `Set<Int>` | In-flight decode requests (prevents duplication) |
| `maxCachedPages` | `Int = 10` | Hard cap on `decodedPages` count |

**Key methods:**
- `decodePage(pageIndex:from:)` — decodes a page, runs LRU eviction before insert (lines 99–108)
- `page(for:)` — returns cached buffer, updates `lastAccessTimes[pageIndex]`
- `evictOutside(_ range:)` — actor-isolated, filters both dicts to range

**LRU logic (lines 99–105):**
```swift
if decodedPages.count >= maxCachedPages {
    if let lruKey = lastAccessTimes.min(by: { $0.value < $1.value })?.key {
        decodedPages.removeValue(forKey: lruKey)
        lastAccessTimes.removeValue(forKey: lruKey)
    }
}
```

---

## Ring 2: `TextureRingBuffer` (Struct)

**File:** `Sources/DC/Views/MetalPageRenderer.swift`

```swift
struct TextureRingBuffer {
    private var entries: [Int: (texture: MTLTexture, lastAccess: Date)] = [:]
    private let maxSize: Int  // = 10
}
```

**Key methods:**
- `insert(_ texture:, for pageIndex:)` — inserts texture, runs LRU eviction before insert (lines 30–36)
- `touch(pageIndex:)` — updates `lastAccess` timestamp, returns texture
- `evictOutside(_ range:)` — filters `entries` to range
- `subscript(pageIndex:)` — non-mutating texture lookup

**LRU logic (lines 31–34):**
```swift
if entries.count >= maxSize {
    let lruKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
    if let key = lruKey { entries.removeValue(forKey: key) }
}
```

---

## Wiring: Coordinator Render Path

**File:** `Sources/DC/Views/MetalPageView.swift` (Coordinator)

`render(visibleRange:)` (lines 518–577) is the main render loop, called on every visible range change:

```swift
@MainActor
func render(visibleRange: ClosedRange<Int>) async {
    // 1. Evict both rings to visible window
    renderer.evictOutside(visibleRange)

    // 2. Fetch from Ring 1, upload to Ring 2
    for seqIdx in visibleRange {
        if let buffer = await pageManager.page(for: seqIdx) {
            if renderer.texture(for: seqIdx) == nil {
                _ = renderer.upload(pixelBuffer: buffer, for: seqIdx)
            }
        }
    }

    // 3. Composite spreads (vertical-double mode)
    if pagesPerRow == 2 {
        for leftIdx in visibleRange {
            _ = renderer.composeSpread(...)
        }
    }

    // 4. Encode and present
    renderer.render(viewport: ..., commandBuffer: commandBuffer, ...)
    commandBuffer.present(drawable)
    commandBuffer.commit()
}
```

`triggerPrefetch()` (lines 500–514) pre-decodes pages for the visible window + 3-page lookahead:
```swift
Task {
    for seqIdx in firstIdx...lastIdx {
        if let buffer = await manager.decodePage(pageIndex: seqIdx, from: page.source) {
            _ = buffer   // → inserted into Ring 1 via LRU eviction
        }
    }
}
```

---

## Eviction Triggers

| Event | `MetalPageManager` ring | `TextureRingBuffer` ring |
|---|---|---|
| Page decode completes | `decodeZipDataPage()` LRU eviction before insert | N/A (texture uploaded separately) |
| Scroll changes visible range | N/A (no direct call) | `evictOutside(visibleRange)` in `render()` |
| `PageImageCache.removeObjectsOutside(lo:hi:)` | N/A (different cache layer) | N/A |
| Zoom / layout rebuild | N/A | `evictOutside(visibleRange)` called on next render |

---

## Memory Limits

| Component | Limit | Mechanism |
|---|---|---|
| `MetalPageManager.decodedPages` | 10 pages | LRU eviction when count ≥ maxCachedPages |
| `TextureRingBuffer.entries` | 10 textures | LRU eviction when count ≥ maxSize |
| `PageImageCache` (Swift actor) | ~5 pages | Sliding window `[center-1...center+3]`, hard eviction outside window |

---

## Verification Script

Run the verification script to confirm wiring:

```bash
bash scripts/memory_ring_test.sh
```

Checks performed:
1. ✅ Build is clean
2. ✅ `TextureRingBuffer` struct exists with `insert`, `touch`, `evictOutside`
3. ✅ Both rings use `min(by:)` on access time (not `dict.keys.first`)
4. ✅ Both rings have `maxSize = 10`
5. ✅ Coordinator calls `renderer.upload()` and `evictOutside()`
6. ✅ `MetalPageManager.evictOutside()` is actor-isolated

---

## Historical Fixes (from CHANGELOG.md)

- **Metal Rendering Pipeline — Phase 1:** `render()` now fetches from `pageManager` and uploads to `renderer` texture ring before encoding — was previously rendering empty (ring was never populated).
- **LRU Bug Fix:** `MetalPageManager` used `dict.keys.first` (arbitrary ordering) instead of true LRU. Fixed to `lastAccessTimes.min(by:)`.
