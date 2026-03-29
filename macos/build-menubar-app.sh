#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/macos/AnovaBar"
BUILD_DIR="$APP_DIR/.build/release"
BUNDLE_DIR="$ROOT_DIR/dist/AnovaBar.app"
EXECUTABLE_NAME="AnovaBar"
ICON_SOURCE="$ROOT_DIR/assets/anovabar-icon.png"
ICON_PATH="$BUNDLE_DIR/Contents/Resources/AnovaBar.icns"
CODESIGN_IDENTITY="${ANOVABAR_CODESIGN_IDENTITY:--}"

swift build --package-path "$APP_DIR" -c release

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$BUNDLE_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$APP_DIR/Resources/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"
if [[ -f "$ICON_SOURCE" && -x "$ROOT_DIR/macos/build-app-icon.sh" ]]; then
    "$ROOT_DIR/macos/build-app-icon.sh" "$ICON_SOURCE" "$ICON_PATH"
fi

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$BUNDLE_DIR"
else
    codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$BUNDLE_DIR"
fi

echo "Built $BUNDLE_DIR"
