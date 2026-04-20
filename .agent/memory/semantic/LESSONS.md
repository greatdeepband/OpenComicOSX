# Lessons (auto-distilled + manually curated)

> Entries here outlive specific tasks. The dream cycle promotes recurring
> patterns from episodic into this file. Feel free to curate manually —
> delete bad lessons, tighten wording, reorganize sections.

## Seed lessons
- Always read `protocols/permissions.md` before any destructive tool call.
- Write the failing test before writing the fix.
- Log to episodic memory on every significant action, success or failure.
- When a skill has failed 3+ times in 14 days, propose a rewrite.
- Never force push to protected branches under any circumstance.

## Auto-promoted entries will be appended below

### 2026-04

- Always serialize timestamps in UTC to avoid cross-region comparison bugs  <!-- status=accepted confidence=0.46 evidence=1 id=lesson_422695ae5b2d -->

### 2026-04-20 (Metal GPU reader)

- Two-ring architecture (CPU decode + GPU texture) is better than one: evicting from a shared ring loses both decoded pixels AND GPU texture; independent rings allow reuse  <!-- status=accepted confidence=0.95 evidence=9 id=lesson_metal_ring -->

- Sequential index is the right canonical key for per-session page lookups — not a global unique ID assigned by the library. ID-to-index translation must be explicit and consistent throughout  <!-- status=accepted confidence=0.95 evidence=9 id=lesson_seq_index -->

- GPU compositing (compute shader blit) beats CPU readback for spread pages — keeps all pixel data GPU-resident, eliminates the most expensive copy in the pipeline  <!-- status=accepted confidence=0.9 evidence=1 id=lesson_gpu_composite -->

- OpenCode max_iterations: 50 is too small for multi-file architectural changes; 300 is the right budget for 3+ file rewrites  <!-- status=accepted confidence=0.95 evidence=3 id=lesson_opencode_limit -->
