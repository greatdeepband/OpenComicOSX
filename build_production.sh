#!/bin/bash
#
# Production build for OpenComic.app — self-contained, transferable to another
# Mac. Writes to dist/ relative to this script. Differences vs build_app.sh:
#
#   - Bundles AppBundle/Resources/bin/unar and lsar into the .app at
#     Contents/Resources/bin/ (ComicLoader.swift looks for them there;
#     without them, CBR / CB7 archives don't open without Homebrew on
#     the target Mac).
#   - Bundles AppBundle/DC.icns as Contents/Resources/AppIcon.icns and
#     references it in Info.plist's CFBundleIconFile so Finder/Dock
#     show the proper icon.
#   - Re-signs the whole bundle deep+ad-hoc after assembly so all
#     resources (icon, shaders, lsar, unar) are sealed under one
#     signature — the linker-only adhoc sign that build_app.sh leaves
#     behind has `Sealed Resources=none`, which Gatekeeper rejects on
#     first launch on a different machine.
#   - Strips the binary's debug symbols (separate dSYM kept in dist/).
#   - Produces a .zip of the .app for transfer (preserves bundle
#     metadata correctly; plain `cp` to USB sometimes loses extended
#     attributes / signature seal on non-APFS filesystems).
#
# Target: Apple Silicon Macs running macOS 14 (Sonoma) or newer. The
# bundled lsar/unar binaries are arm64-only — Intel Macs would need
# their own build with Rosetta-toolchain x86_64 binaries, not done here.
#
set -e
PKG="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD="$PKG/.build/arm64-apple-macosx/release/DC"
DSYM="$PKG/.build/arm64-apple-macosx/release/DC.dSYM"
DIST="$PKG/dist"
APP="$DIST/OpenComic.app"
ZIP="$DIST/OpenComic.app.zip"

echo "==> Cleaning dist/"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building release (arm64)..."
cd "$PKG"
swift build -c release

echo "==> Assembling app bundle at $APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/bin"

# Binary
cp "$BUILD" "$APP/Contents/MacOS/DC"
chmod +x "$APP/Contents/MacOS/DC"

# Strip debug symbols (keep dSYM separately for crash decoding)
echo "==> Stripping debug symbols"
if [ -d "$DSYM" ]; then
    cp -R "$DSYM" "$DIST/DC.dSYM"
fi
strip -S "$APP/Contents/MacOS/DC" 2>/dev/null || true

# Resources: shader, icon
cp "$PKG/Sources/DC/Shaders.metal" "$APP/Contents/Resources/"
cp "$PKG/AppBundle/DC.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundled CLIs for CBR / CB7 (ComicLoader looks them up at
# Contents/Resources/bin/{unar,lsar}; falls back to Homebrew if
# missing — which would break on a fresh Mac).
cp "$PKG/AppBundle/Resources/bin/unar" "$APP/Contents/Resources/bin/"
cp "$PKG/AppBundle/Resources/bin/lsar" "$APP/Contents/Resources/bin/"
chmod +x "$APP/Contents/Resources/bin/unar"
chmod +x "$APP/Contents/Resources/bin/lsar"

# Entitlements (matches dev build)
cat > "$APP/Contents/Resources/app.entitlements" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
EOF

# Info.plist (note: CFBundleIconFile names the icon WITHOUT extension)
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>DC</string>
    <key>CFBundleIdentifier</key><string>com.opncomic.open-comic</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Open Comic</string>
    <key>CFBundleDisplayName</key><string>Open Comic</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.11.2</string>
    <key>CFBundleVersion</key><string>0.11.2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHumanReadableCopyright</key><string>Copyright 2026. All rights reserved.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign nested executables FIRST (codesign --deep used to be enough; on
# modern macOS the recommended order is leaves-up).
echo "==> Code-signing nested binaries"
codesign --force --options runtime --sign - "$APP/Contents/Resources/bin/unar"
codesign --force --options runtime --sign - "$APP/Contents/Resources/bin/lsar"

# Now sign the bundle as a whole; --deep re-signs anything we missed.
echo "==> Code-signing bundle (deep ad-hoc)"
codesign --force --deep --sign - "$APP"

# Verify the signature is valid and seals everything
echo
echo "==> Verifying bundle"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'
echo
codesign -dv "$APP" 2>&1 | sed 's/^/   /'

# README for the receiving Mac
cat > "$DIST/README.txt" << 'EOF'
OpenComic — production build
============================

System requirements:
  - Apple Silicon Mac (M1 / M2 / M3 / M4 ...)
  - macOS 14 (Sonoma) or newer

To install on the target Mac:

  1. Copy OpenComic.app (or unzip OpenComic.app.zip) into /Applications/
     or anywhere you like.

  2. First-launch Gatekeeper prompt:
     Because this build is ad-hoc signed (not notarized via an Apple
     Developer account), macOS will refuse to open it on first try
     with: "Open Comic can't be opened because the developer cannot
     be verified."

     EITHER:
       Right-click (or Control-click) the .app -> "Open" -> "Open" in
       the confirmation dialog. Only required once; after that it
       launches normally.
     OR, from a Terminal:
       xattr -dr com.apple.quarantine /path/to/OpenComic.app
       open /path/to/OpenComic.app

What's inside:
  - The DC executable (arm64 release build, debug symbols stripped)
  - Shaders.metal (compiled at runtime by the renderer)
  - lsar / unar (bundled, no Homebrew needed for CBR / CB7)
  - AppIcon.icns
  - app.entitlements (sandbox=false, file-read-write granted)

If you keep the .dSYM file alongside the .app, crashes can be
symbolicated later with `atos` / `lldb`.

For the developer:
  - To rebuild: ./build_production.sh from the project root.
  - Bundle is fully self-contained except for system frameworks and
    /usr/lib/swift/* (OS-shipped on macOS 10.14.4+).
EOF

# Pack as zip for transfer (ditto preserves bundle metadata and
# extended attributes correctly, unlike `zip -r`).
echo "==> Packaging as .zip"
cd "$DIST"
ditto -c -k --keepParent OpenComic.app "$ZIP"
cd - > /dev/null

echo
echo "==> Done."
echo "    App:    $APP"
echo "    ZIP:    $ZIP"
[ -d "$DIST/DC.dSYM" ] && echo "    dSYM:   $DIST/DC.dSYM"
echo "    README: $DIST/README.txt"
echo
du -sh "$APP" "$ZIP" 2>/dev/null
