# Third-Party Licenses

Open Comic bundles and depends on third-party software. This document lists each
component, its license, and where to obtain the upstream source.

## Bundled binaries (in `AppBundle/Resources/bin/`)

### The Unarchiver — `unar` and `lsar`

- **Version:** 1.10.7 (Oct 10 2023)
- **Upstream:** https://theunarchiver.com/command-line
- **Source code:** https://github.com/MacPaw/XADMaster (the CLI tools live in
  the `Extra/` subdirectory of XADMaster + UniversalDetector)
- **License:** **LGPL-2.1-or-later** (XADMaster framework) plus **MIT** /
  **public domain** for portions of the depended libraries.

Open Comic distributes unmodified copies of the upstream `unar` and `lsar`
binaries to extract `.cbr` (RAR) and `.cb7` (7-Zip) comic archives at runtime.
No source modifications have been made.

**LGPL compliance — your rights as a user:**

You may modify and relink the `unar` / `lsar` binaries against your own version
of XADMaster. To do so:

1. Download the XADMaster source from
   https://github.com/MacPaw/XADMaster
2. Build per the instructions in `Extra/` of that repository.
3. Replace the binaries inside
   `Open Comic.app/Contents/Resources/bin/unar` and
   `…/lsar` with your built versions.
4. The app's ad-hoc code signature must be re-applied after replacement
   (`codesign --force --deep --sign - "Open Comic.app"`).

The full text of the GNU Lesser General Public License, version 2.1, is
available at https://www.gnu.org/licenses/lgpl-2.1.html — and is reproduced
in the `LICENSES/LGPL-2.1.txt` file in this repository.

---

## Swift Package dependencies

### ZIPFoundation

- **Version:** 0.9.19+ (see `Package.resolved` for the exact resolved version)
- **Upstream:** https://github.com/weichsel/ZIPFoundation
- **License:** **MIT**
- **Purpose:** Native Swift ZIP reading for `.cbz` archive extraction.

The full MIT license text is in the ZIPFoundation source tree at
`LICENSE`, and is reproduced upstream at the URL above.

---

## System frameworks (no bundling)

Open Comic links against Apple system frameworks (`AppKit`, `SwiftUI`, `Metal`,
`PDFKit`, `Foundation`, `CoreVideo`) at runtime. These ship with macOS and are
covered by the macOS SDK License Agreement; no separate notice is required.

---

## System tool dispatch

The system `tar` command is invoked via `Process` for `.cbt` (Tar) archive
extraction. `tar` is part of the macOS base install (BSD tar). Not bundled.
