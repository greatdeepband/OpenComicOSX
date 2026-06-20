# Third-Party Licenses

Open Comic bundles and depends on third-party software. This document lists each
component, its license, and where to obtain the upstream source.

## Bundled binaries (in `AppBundle/Resources/bin/`)

### The Unarchiver — `unar` and `lsar`

- **Version:** 1.10.7
- **Copyright:** © Dag Ågren and contributors; © MacPaw Inc.
- **License:** LGPL-2.1-or-later (XADMaster + UniversalDetector), full text in
  `LICENSES/LGPL-2.1.txt` (also bundled inside the app at `Contents/Resources/licenses/`).
- **Corresponding source (pinned, unmodified):**
  - XADMaster: https://github.com/MacPaw/XADMaster/tree/v1.10.7
    (commit `75cf99f99ce3e49024fcfb195dcd09834ee3c915`)
  - UniversalDetector: https://github.com/MacPaw/universal-detector/tree/1.1
    (commit `e4f7ffac0105767478bf5fdeb614d9b6c1a6a7e3`)
  - The complete corresponding source is at the URLs above and is linked from each Open Comic
    release. (LGPL-2.1 §3(a) — source provided alongside, not a time-limited written offer.)

Open Comic distributes **unmodified** copies of the upstream `unar` and `lsar`. The bundled
binaries are **arm64-only local builds** of the pinned source (not MacPaw's universal
prebuilts); no source modifications were made.

**Aggregation note:** Open Comic invokes `unar`/`lsar` as separate subprocesses (`Process`/
`exec`) and does NOT link XADMaster into its own executable. They are therefore separate works;
Open Comic's own license (see `LICENSE`) is unaffected.

**Your LGPL rights — modify and relink:**

1. Obtain the corresponding source at the pinned URLs above.
2. Build `unar`/`lsar` per the XADMaster `Extra/` build instructions for that revision (arm64;
   standard Xcode command-line tools).
3. Replace `OpenComic.app/Contents/Resources/bin/unar` (and/or `lsar`) with your build.
4. Re-sign your replacements and the bundle with YOUR OWN identity (or ad-hoc):
   ```
   codesign --force --options runtime --timestamp=none --sign - "OpenComic.app/Contents/Resources/bin/unar"
   codesign --force --options runtime --timestamp=none --sign - "OpenComic.app/Contents/Resources/bin/lsar"
   codesign --force --options runtime --timestamp=none --sign - "OpenComic.app"
   ```
   Relinking necessarily invalidates Open Comic's original Apple notarization — the result is
   your own local build. To launch it without notarization: right-click → Open once, or
   `xattr -dr com.apple.quarantine "OpenComic.app"`.

---

## Swift Package dependencies

### ZIPFoundation

- **Version:** 0.9.20 (pinned; see `Package.resolved`)
- **Upstream:** https://github.com/weichsel/ZIPFoundation
- **License:** MIT
- **Purpose:** Native Swift ZIP reading for `.cbz` extraction.

MIT License — Copyright © 2017-2025 Thomas Zoechling (https://www.peakstep.com) and contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## System frameworks (no bundling)

Open Comic links against Apple system frameworks (`AppKit`, `SwiftUI`, `Metal`,
`PDFKit`, `Foundation`, `CoreVideo`) at runtime. These ship with macOS and are
covered by the macOS SDK License Agreement; no separate notice is required.

---

## System tool dispatch

The system `tar` command is invoked via `Process` for `.cbt` (Tar) archive
extraction. `tar` is part of the macOS base install (BSD tar). Not bundled.
