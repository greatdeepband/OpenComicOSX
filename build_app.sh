#!/bin/bash
set -e
PKG="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD="$PKG/.build/arm64-apple-macosx/release/DC"
APP="$PKG/OpenComic.app"

echo "Building release..."
cd "$PKG" && swift build -c release

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp "$BUILD" "$APP/Contents/MacOS/DC"

# Copy entitlements
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

# Write Info.plist
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
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHumanReadableCopyright</key><string>Copyright 2024. All rights reserved.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
</dict>
</plist>
EOF

# Copy Shaders.metal
cp "$PKG/Sources/DC/Shaders.metal" "$APP/Contents/Resources/"

# Assets
cat > "$APP/Contents/Resources/Assets.xcassets/Contents.json" << 'EOF'
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF
cat > "$APP/Contents/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" << 'EOF'
{ "images" : [ { "idiom" : "mac", "scale" : "1x", "size" : "16x16" }, { "idiom" : "mac", "scale" : "2x", "size" : "16x16" }, { "idiom" : "mac", "scale" : "1x", "size" : "32x32" }, { "idiom" : "mac", "scale" : "2x", "size" : "32x32" }, { "idiom" : "mac", "scale" : "1x", "size" : "128x128" }, { "idiom" : "mac", "scale" : "2x", "size" : "128x128" }, { "idiom" : "mac", "scale" : "1x", "size" : "256x256" }, { "idiom" : "mac", "scale" : "2x", "size" : "256x256" }, { "idiom" : "mac", "scale" : "1x", "size" : "512x512" }, { "idiom" : "mac", "scale" : "2x", "size" : "512x512" } ], "info" : { "author" : "xcode", "version" : 1 } }
EOF

chmod +x "$APP/Contents/MacOS/DC"
echo "Done: $APP"
ls -la "$APP"
