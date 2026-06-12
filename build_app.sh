#!/bin/bash
set -e
PKG="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD="$PKG/.build/arm64-apple-macosx/release/DC"
APP="$PKG/OpenComic.app"
VERSION="$(cat "$PKG/VERSION")"

echo "Building release (v$VERSION)..."
cd "$PKG" && swift build -c release

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Binary
cp "$BUILD" "$APP/Contents/MacOS/DC"
chmod +x "$APP/Contents/MacOS/DC"

# Entitlements + Info.plist from the single canonical sources in AppBundle/
# (shared with build_production.sh — no duplicated heredocs to drift).
cp "$PKG/AppBundle/DC.entitlements" "$APP/Contents/Resources/app.entitlements"
sed "s/__VERSION__/$VERSION/g" "$PKG/AppBundle/Info.plist" > "$APP/Contents/Info.plist"

# Shader (the renderer compiles it at runtime if the SPM default library is
# not present in the bundle).
cp "$PKG/Sources/DC/Shaders.metal" "$APP/Contents/Resources/"

# Ad-hoc sign so the bundle launches cleanly on this machine. (build_app.sh is
# the dev builder — it does NOT bundle unar/lsar or compile the icon asset
# catalog; use build_production.sh for a transferable, fully-sealed release.)
codesign --force --sign - "$APP"

echo "Done: $APP"
ls -la "$APP"
