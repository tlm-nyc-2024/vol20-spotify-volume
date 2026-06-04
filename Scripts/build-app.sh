#!/bin/bash
#
# build-app.sh — turn `swift build` output into a real .app bundle.
#
# Without full Xcode installed, `swift build` only gives us a plain command-
# line binary. macOS won't treat that as a menu-bar app on its own; it needs
# to live inside a folder named Foo.app with this layout:
#
#   Vol20v2.app/
#   └── Contents/
#       ├── Info.plist                <- our metadata, including LSUIElement
#       └── MacOS/
#           └── Vol20v2               <- the binary swift build produced
#
# We also ad-hoc sign the bundle (`codesign --sign -`). That uses an
# ephemeral signing identity tied to this Mac — no Apple Developer account
# required. Other Macs would refuse the app, but for personal use it's fine.
#
# Run this script from anywhere; it figures out its own location.
#

set -euo pipefail

# Resolve the project directory (one level up from this script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Vol20v2"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

# Default to debug build for fast iteration. Pass `release` to opt into
# the optimized (slower-to-compile, faster-to-run) build for final use.
#   ./Scripts/build-app.sh          -> debug
#   ./Scripts/build-app.sh release  -> release
CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "ERROR: unknown config '$CONFIG' (use 'debug' or 'release')" >&2
    exit 1
fi

cd "$PROJECT_DIR"

echo "==> Building $APP_NAME ($CONFIG config)"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release
else
    swift build
fi

# swift build puts the binary at .build/<config>/<name>.
BIN_PATH="$PROJECT_DIR/.build/$CONFIG/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "ERROR: expected binary at $BIN_PATH but did not find it." >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app bundle"
# Start fresh each run so we don't accumulate stale files.
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH"                  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Ad-hoc signing the bundle"
# `--sign -` means "ad-hoc identity"; --force overwrites any prior signature;
# --deep recurses into nested code (we have none yet, but harmless).
codesign --force --deep --sign - "$APP_BUNDLE"

echo
echo "Done."
echo "App bundle:  $APP_BUNDLE"
echo "Launch with: open \"$APP_BUNDLE\""
