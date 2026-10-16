#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

ARGUS_CHECK_TEMP="$(mktemp -d)"
trap 'rm -rf "$ARGUS_CHECK_TEMP"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/argus-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${TMPDIR:-/tmp}/argus-swift-cache}"

swift run --disable-sandbox ArgusTests
ARGUS_BIN_DIR="$(swift build --disable-sandbox --show-bin-path)"
if [ -f "$ARGUS_BIN_DIR/ArgusCore.o" ]; then
    ARGUS_MODULE_DIR="$ARGUS_BIN_DIR"
    set -- "$ARGUS_BIN_DIR/ArgusCore.o"
else
    ARGUS_MODULE_DIR="$ARGUS_BIN_DIR/Modules"
    set -- "$ARGUS_BIN_DIR/ArgusCore.build/"*.o
fi
swiftc -parse-as-library -I "$ARGUS_MODULE_DIR" "$@" \
    Sources/ArgusApp/SessionStore.swift Sources/ArgusApp/Notifier.swift \
    Tests/ArgusAppChecks/main.swift -o "$ARGUS_CHECK_TEMP/ArgusAppChecks"
"$ARGUS_CHECK_TEMP/ArgusAppChecks"
