#!/bin/bash
set -e

REPO="/Volumes/Media/__Manus/DC"
BUILD="$REPO/build"
APP="$BUILD/DC.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Cleaning previous app bundle..."
rm -rf "$APP"

echo "==> Building release binary..."
cd "$REPO"
xcodebuild \
    -scheme DC \
    -configuration Release \
    -destination 'platform=macOS' \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD" \
    2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)"

echo "==> Assembling .app bundle..."
mkdir -p "$MACOS" "$RESOURCES"

# Copy binary
cp "$BUILD/DC" "$MACOS/DC"
chmod +x "$MACOS/DC"

# Copy Info.plist
cp "$REPO/Sources/DC/Resources/Info.plist" "$CONTENTS/Info.plist"

# Copy ZIPFoundation bundle if present
if [ -d "$BUILD/ZIPFoundation_ZIPFoundation.bundle" ]; then
    cp -R "$BUILD/ZIPFoundation_ZIPFoundation.bundle" "$RESOURCES/"
fi

echo "==> Signing ad-hoc (no Apple Developer account needed)..."
codesign --force --deep --sign - "$APP"

echo ""
echo "Done! App bundle at:"
echo "  $APP"
echo ""
echo "To run: open \"$APP\""
