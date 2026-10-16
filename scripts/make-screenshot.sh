#!/bin/sh
# Renders the panel with sample sessions to docs/screenshot.png for the README.
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
ARGUS_SHOT_TEMP="$(mktemp -d)"
trap 'rm -rf "$ARGUS_SHOT_TEMP"' EXIT
cat > "$ARGUS_SHOT_TEMP/Resources.swift" <<EOF
import Foundation
extension Bundle {
    static var module: Bundle { Bundle(path: "$PWD/Sources/ArgusApp/Resources")! }
}
EOF
swiftc -parse-as-library -I "$ARGUS_MODULE_DIR" "$@" \
    Sources/ArgusApp/Fonts.swift Sources/ArgusApp/MenuContent.swift \
    Sources/ArgusApp/Notifier.swift Sources/ArgusApp/SessionStore.swift \
    Tests/ArgusAppChecks/Screenshot.swift "$ARGUS_SHOT_TEMP/Resources.swift" \
    -o "$ARGUS_SHOT_TEMP/ArgusScreenshot"
mkdir -p docs
"$ARGUS_SHOT_TEMP/ArgusScreenshot" docs/screenshot.png
