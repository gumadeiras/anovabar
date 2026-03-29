#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <source-png> <output-icns>" >&2
    exit 1
fi

SOURCE_PNG="$1"
OUTPUT_ICNS="$2"
WORK_DIR="$(mktemp -d)"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

mkdir -p "$ICONSET_DIR" "$(dirname "$OUTPUT_ICNS")"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null

    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
