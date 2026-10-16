#!/bin/sh
# Builds the debug (or release) binary and wraps it in a minimal .app bundle.
# Usage: scripts/make-app.sh [debug|release] [--preview]
set -eu
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
ARGUS_APP_NAME=Argus
ARGUS_BUNDLE_ID=io.github.bashariq.Argus
ARGUS_UI_ELEMENT=true
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/argus-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${TMPDIR:-/tmp}/argus-swift-cache}"
# This Command Line Tools SDK uses SwiftUIMacros for @State, but its toolchain
# does not ship the plugin. Use the older installed SDK until CLT is repaired.
if [ "${SDKROOT+x}" != x ] && [ "$(xcrun --find swift 2>/dev/null)" = /Library/Developer/CommandLineTools/usr/bin/swift ] &&
   [ "$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)" = 27.0 ] &&
   [ ! -e /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ] &&
   [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    export SDKROOT
fi
if [ "${2:-}" = --preview ]; then
    ARGUS_APP_NAME=ArgusPreview
    ARGUS_BUNDLE_ID=io.github.bashariq.ArgusPreview
    ARGUS_UI_ELEMENT=false
    swift build --disable-sandbox -c "$CONFIG" --product ArgusApp -Xswiftc -DARGUS_PREVIEW
else
    swift build --disable-sandbox -c "$CONFIG" --product ArgusApp
fi

BIN=".build/$CONFIG/ArgusApp"
APP="build/$ARGUS_APP_NAME.app"
# SwiftPM builds the resource bundle next to the binary. Bundle.module looks
# for it in the app's Contents/Resources directory.
RESOURCES="$(ls -d .build/$CONFIG/Argus_ArgusApp.bundle 2>/dev/null || true)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Argus"
if [ -n "$RESOURCES" ]; then
    cp -R "$RESOURCES" "$APP/Contents/Resources/"
fi

# App icon: rasterize logo.png at every icns size and bundle the set.
ICONSET="$(mktemp -d)/Argus.iconset"
mkdir -p "$ICONSET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
            "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" Sources/ArgusApp/Resources/logo.png --out "$ICONSET/$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Argus.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Argus</string>
    <key>CFBundleIconFile</key><string>Argus</string>
    <key>CFBundleIdentifier</key><string>$ARGUS_BUNDLE_ID</string>
    <key>CFBundleName</key><string>$ARGUS_APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><$ARGUS_UI_ELEMENT/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign the completed bundle so its executable and resources share the app ID.
codesign --force --sign - --identifier "$ARGUS_BUNDLE_ID" "$APP"
echo "Built $APP"
