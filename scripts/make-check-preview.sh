#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/argus-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${TMPDIR:-/tmp}/argus-swift-cache}"
if [ "${SDKROOT+x}" != x ] && [ "$(xcrun --sdk macosx --show-sdk-version)" = 27.0 ] &&
   [ ! -e /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ] &&
   [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build --disable-sandbox --target ArgusCore
ARGUS_BIN_DIR="$(swift build --disable-sandbox --show-bin-path)"
if [ -f "$ARGUS_BIN_DIR/ArgusCore.o" ]; then
    ARGUS_MODULE_DIR="$ARGUS_BIN_DIR"
    set -- "$ARGUS_BIN_DIR/ArgusCore.o"
else
    ARGUS_MODULE_DIR="$ARGUS_BIN_DIR/Modules"
    set -- "$ARGUS_BIN_DIR/ArgusCore.build/"*.o
fi
ARGUS_CHECK_APP="build/ArgusChecks.app"
mkdir -p "$ARGUS_CHECK_APP/Contents/MacOS" "$ARGUS_CHECK_APP/Contents/Resources"
cp -R Sources/ArgusApp/Resources/Fonts "$ARGUS_CHECK_APP/Contents/Resources/"
ARGUS_CHECK_TEMP="$(mktemp -d)"
trap 'rm -rf "$ARGUS_CHECK_TEMP"' EXIT
cat > "$ARGUS_CHECK_TEMP/Resources.swift" <<'EOF'
import Foundation
extension Bundle {
    static var module: Bundle { .main }
}
EOF
swiftc -parse-as-library -I "$ARGUS_MODULE_DIR" "$@" \
    Sources/ArgusApp/Fonts.swift Sources/ArgusApp/MenuContent.swift \
    Sources/ArgusApp/Notifier.swift Sources/ArgusApp/SessionStore.swift \
    Tests/ArgusAppChecks/Preview.swift "$ARGUS_CHECK_TEMP/Resources.swift" \
    -o "$ARGUS_CHECK_APP/Contents/MacOS/ArgusChecks"
cat > "$ARGUS_CHECK_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ArgusChecks</string>
    <key>CFBundleIdentifier</key><string>io.github.bashariq.ArgusChecks</string>
    <key>CFBundleName</key><string>ArgusChecks</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force --sign - --identifier io.github.bashariq.ArgusChecks "$ARGUS_CHECK_APP"
printf 'Built %s\n' "$ARGUS_CHECK_APP"
