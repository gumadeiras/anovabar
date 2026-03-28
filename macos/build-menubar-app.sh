#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/macos/AnovaBar"
BUILD_DIR="$APP_DIR/.build/release"
BUNDLE_DIR="$ROOT_DIR/dist/AnovaBar.app"
EXECUTABLE_NAME="AnovaBar"

swift build --package-path "$APP_DIR" -c release

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$BUNDLE_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$APP_DIR/Resources/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$BUNDLE_DIR"

echo "Built $BUNDLE_DIR"
