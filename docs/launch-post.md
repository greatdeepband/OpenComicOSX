# OpenComic — launch post drafts

Three formats: full launch post (primary), megathread short, and an honest reply for "best Mac comic reader" recommendation threads.

Repo: https://github.com/greatdeepband/OpenComicOSX
Release: https://github.com/greatdeepband/OpenComicOSX/releases/tag/v0.14.0

---

## Format 1 — Full launch post

**Title** (r/macapps requires `[OS]` prefix for open source):

> [OS] Open Comic — a native, Metal-accelerated comic reader for macOS (free, MIT)

**Body:**

Hey r/macapps 👋

I built **Open Comic** because the Mac comic-reader landscape hadn't moved in a while — Simple Comic is great but quiet, YACReader is cross-platform-first, and most newer options are iPad ports. I wanted something that felt like a Mac app written for the M-series era.

It's free, MIT-licensed, and runs on macOS 14+ (with macOS 26 Tahoe-aware UI when you're on Tahoe).

### What's different about it

- **All four reading modes in one app** — single page, double-page spread, vertical scroll, vertical-double. Switch on the fly. Works equally well for Western single-issue and long-form manga.
- **GPU rendering everywhere** — every page goes through a Metal pipeline (`CAMetalLayer` + texture rings). Fast scroll on a 200-page manga stays smooth.
- **Native library, not just a file opener** — Home / Favorites / Recents / All / user-defined Galleries. Drag-to-import any CBZ/CBR/CB7/CBT/PDF onto the window. Per-comic memory of where you left off (page, mode, scroll offset).
- **Loupe magnifier** — hold left-click on any page for a circular zoom centred on the cursor (works in all four reading modes).
- **Free, no account, no sync, no telemetry.** Your library lives on your disk. The app writes thumbnails to `~/Library/Application Support/DC/`.

### What it supports

- CBZ, CBR, CB7, CBT, PDF
- macOS 14 Sonoma → macOS 26 Tahoe (Liquid Glass toolbar on Tahoe, `.ultraThinMaterial` fallback on older)
- Apple Silicon only for now (the bundled `unar`/`lsar` are arm64)

### Where to get it

- **Direct .app download:** https://github.com/greatdeepband/OpenComicOSX/releases/tag/v0.14.0 (4 MB zip, ad-hoc signed — right-click → Open on first launch)
- **Source / build from scratch:** https://github.com/greatdeepband/OpenComicOSX (`./build_production.sh`)
- **Homebrew formula** is in the repo at `homebrew/Formula/open-comic.rb` — tap coming soon

### What's next

I'd love feedback on:
- Reading-mode defaults and gestures — does single-page default match your expectation?
- Any CBR/CB7 archives that don't open (the bundled `unar` handles most, but edge cases happen)
- Anything missing that would make this your daily reader

Built solo over several months, MIT-licensed, contributions welcome. **Disclosure: I'm the author.**

---

## Format 2 — r/macapps monthly megathread (short)

For when posting in the megathread instead of the main feed. Megathreads expect one comment per app, kept tight:

> **[OS] Open Comic v0.14.0** — native macOS comic reader (CBZ/CBR/CB7/CBT/PDF), Metal-accelerated, four reading modes, library with galleries + drag-to-import, no account / no telemetry. Free + MIT. macOS 14+, Apple Silicon.
>
> https://github.com/greatdeepband/OpenComicOSX
>
> Disclosure: I made it. Happy to answer anything.

---

## Format 3 — Honest comment in existing "best Mac comic reader" threads

**Do NOT post these until you have ≥10 karma in the sub** (r/macapps rule 2). When you do, always disclose.

> If you want something free + open source besides Simple Comic, I built **Open Comic** recently — native macOS, GPU-rendered, all four reading modes (single / double / vertical / vertical-double), library with galleries. CBZ/CBR/CB7/CBT/PDF. macOS 14+, Apple Silicon.
>
> https://github.com/greatdeepband/OpenComicOSX/releases/tag/v0.14.0
>
> Disclosure: I'm the author.

---

## Where to post (recommended order)

1. **r/opensource** main feed — most welcoming for MIT-licensed launches. Same title/body works as-is.
2. **r/MacOS** main feed — drop the `[OS]` prefix from the title; the rest is fine.
3. **r/macapps monthly megathread** — use Format 2. Watch for the pinned megathread post each month.
4. **r/swift** (optional) — lean into the technical angle: "Metal pipeline for all four reading modes, NSScrollView + CAMetalLayer sublayer pattern, etc." Good for credibility, won't drive end-user downloads.
5. **Hacker News** — Show HN: "Open Comic — a native, Metal-accelerated macOS comic reader (MIT)". Short title, link straight to the GitHub repo. HN crowd loves native + OSS + technical depth.
6. **Hold off on r/comicbooks, r/manga** until you have karma history there. Their self-promo rules are strict.

## What to add before posting

- **A screenshot or two** — every successful r/macapps launch post has them. A library view + a reading view with the loupe visible would land well.
- **A 10-30 second GIF** of mode-switching or fast-scrolling — shows off the Metal pipeline in a way text can't. Optional but strong.
- **Reply quickly** in the first hour — the Panels post engagement was driven by the author answering questions promptly.
