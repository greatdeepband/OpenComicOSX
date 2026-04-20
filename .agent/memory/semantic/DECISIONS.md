# Major Decisions

> Record architectural or workflow choices that would be costly to re-debate.
> Use this template for each entry:

## YYYY-MM-DD: Decision title
**Decision:** _what was chosen_
**Rationale:** _why, in one or two sentences_
**Alternatives considered:** _what else was on the table and why rejected_
**Status:** active | revisited | superseded

## 2026-01-01: Four-layer memory separation
**Decision:** Split memory into working / episodic / semantic / personal rather than one flat folder.
**Rationale:** Each layer has different retention and retrieval needs. Flat memory breaks at ~6 weeks.
**Alternatives considered:** Flat directory (fails at scale), vector store (over-engineered for single user).
**Status:** active

## 2026-04-20: Metal GPU reader architecture
**Decision:** Rebuild vertical/vertical-double scroll modes using Metal with a two-ring buffer (MetalPageManager actor + MetalPageRenderer texture ring), both 10-page LRU capped.
**Rationale:** NSImage/NSStackView pipeline had unbounded memory growth. Metal allows GPU-resident textures with explicit management. Two rings (CVPixelBuffer on CPU, MTLTexture on GPU) keep decoded image memory flat at ~340MB regardless of comic length.
**Alternatives considered:**
- Keep NSImage pipeline with NSCache — NSCache is automatic, not bounded, and evicts under memory pressure unpredictably
- Single ring — having both decoded pixels and GPU textures in the same ring means evicting a page loses both; two rings allow independent scaling
**Status:** active

## 2026-04-20: Sequential index as canonical key
**Decision:** All ring buffers, page lookups, and render passes use sequential array index as the canonical key, not `ComicPage.id`.
**Rationale:** `page.id` is a global unique ID assigned by the library — it does not correspond to the page's position in the current comic's `pages` array. The mismatch caused pages to render as wrong images or not at all.
**Status:** active

## 2026-04-20: GPU compositing for vertical double mode
**Decision:** Left+right pages composited via `composeSpreadKernel` compute shader into a single spread MTLTexture, rendered as one quad per row — rather than two quads per row or CPU-side compositing.
**Rationale:** GPU-only path avoids CPU readback and keeps all pixel data GPU-resident. Single quad is more efficient than two.
**Status:** active

## 2026-04-20: GPU loupe
**Decision:** Loupe rendered via `loupeKernel` compute shader sampling the page texture, rather than CPU-side CVPixelBuffer sampling + NSImage overlay.
**Rationale:** Keeps all rendering on GPU; no CPU pixel access required.
**Status:** active
