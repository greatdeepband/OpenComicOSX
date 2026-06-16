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
VERSION="$(cat "$PKG/VERSION")"
# Release-asset naming convention: OpenComic-<version>.zip (the Homebrew cask
# at homebrew/Formula/open-comic.rb downloads exactly this name).
ZIP="$DIST/OpenComic-${VERSION}.zip"

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

# Compile an Asset Catalog (Assets.car) so Stage Manager / Mission
# Control / Spotlight find the icon — these surfaces look at
# CFBundleIconName + Assets.car FIRST and only fall back to
# CFBundleIconFile + .icns for legacy code paths. Without a compiled
# .car the app icon shows as a blank tile in Stage Manager.
echo "==> Compiling Asset Catalog"
XCASSETS="$DIST/Assets.xcassets"
APPICONSET="$XCASSETS/AppIcon.appiconset"
mkdir -p "$APPICONSET"
# Copy each iconset PNG; Apple's expected filenames are identical to
# our DC.iconset names (icon_16x16.png, icon_16x16@2x.png, etc.)
cp "$PKG/AppBundle/DC.iconset/"*.png "$APPICONSET/"
# AppIcon.appiconset/Contents.json — manifest of which file is which size.
cat > "$APPICONSET/Contents.json" << 'EOF'
{
  "images": [
    { "size": "16x16",   "idiom": "mac", "filename": "icon_16x16.png",       "scale": "1x" },
    { "size": "16x16",   "idiom": "mac", "filename": "icon_16x16@2x.png",    "scale": "2x" },
    { "size": "32x32",   "idiom": "mac", "filename": "icon_32x32.png",       "scale": "1x" },
    { "size": "32x32",   "idiom": "mac", "filename": "icon_32x32@2x.png",    "scale": "2x" },
    { "size": "128x128", "idiom": "mac", "filename": "icon_128x128.png",     "scale": "1x" },
    { "size": "128x128", "idiom": "mac", "filename": "icon_128x128@2x.png",  "scale": "2x" },
    { "size": "256x256", "idiom": "mac", "filename": "icon_256x256.png",     "scale": "1x" },
    { "size": "256x256", "idiom": "mac", "filename": "icon_256x256@2x.png",  "scale": "2x" },
    { "size": "512x512", "idiom": "mac", "filename": "icon_512x512.png",     "scale": "1x" },
    { "size": "512x512", "idiom": "mac", "filename": "icon_512x512@2x.png",  "scale": "2x" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
EOF
cat > "$XCASSETS/Contents.json" << 'EOF'
{ "info": { "author": "xcode", "version": 1 } }
EOF
xcrun actool "$XCASSETS" \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$DIST/actool-info.plist" \
    --output-format human-readable-text > /dev/null
# Cleanup intermediate xcassets dir from dist/ (Assets.car is now in
# the bundle; we don't need the source xcassets in dist/).
rm -rf "$XCASSETS" "$DIST/actool-info.plist"

# Bundled CLIs for CBR / CB7 (ComicLoader looks them up at
# Contents/Resources/bin/{unar,lsar}; falls back to Homebrew if
# missing — which would break on a fresh Mac).
cp "$PKG/AppBundle/Resources/bin/unar" "$APP/Contents/Resources/bin/"
cp "$PKG/AppBundle/Resources/bin/lsar" "$APP/Contents/Resources/bin/"
chmod +x "$APP/Contents/Resources/bin/unar"
chmod +x "$APP/Contents/Resources/bin/lsar"

# Entitlements + Info.plist from the single canonical sources in AppBundle/
# (shared with build_app.sh; __VERSION__ substituted from the VERSION file —
# no per-script heredocs to drift out of sync).
cp "$PKG/AppBundle/DC.entitlements" "$APP/Contents/Resources/app.entitlements"
sed "s/__VERSION__/$VERSION/g" "$PKG/AppBundle/Info.plist" > "$APP/Contents/Info.plist"

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

  1. Unzip the downloaded OpenComic-<version>.zip and move OpenComic.app
     into /Applications/ (or anywhere you like).

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
