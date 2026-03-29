#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/AnovaBar.app"
CLI_BUNDLE="$ROOT_DIR/dist/AnovaBarCLI.app"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

for required_var in \
    ANOVABAR_APPLE_ID \
    ANOVABAR_APPLE_TEAM_ID \
    ANOVABAR_APPLE_APP_SPECIFIC_PASSWORD
do
    if [[ -z "${!required_var:-}" ]]; then
        echo "error: missing required environment variable $required_var" >&2
        exit 1
    fi
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: notarization requires macOS" >&2
    exit 1
fi

for bundle in "$APP_BUNDLE" "$CLI_BUNDLE"; do
    if [[ ! -d "$bundle" ]]; then
        echo "error: missing app bundle at $bundle" >&2
        exit 1
    fi
done

submit_for_notarization() {
    local bundle_path="$1"
    local bundle_name
    local archive_path

    bundle_name="$(basename "$bundle_path")"
    archive_path="$TMP_DIR/$bundle_name.zip"

    ditto -c -k --sequesterRsrc --keepParent "$bundle_path" "$archive_path"

    xcrun notarytool submit "$archive_path" \
        --apple-id "$ANOVABAR_APPLE_ID" \
        --password "$ANOVABAR_APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$ANOVABAR_APPLE_TEAM_ID" \
        --wait

    xcrun stapler staple "$bundle_path"
    xcrun stapler validate "$bundle_path"
}

submit_for_notarization "$APP_BUNDLE"
submit_for_notarization "$CLI_BUNDLE"

echo "Notarized and stapled AnovaBar.app and AnovaBarCLI.app."
