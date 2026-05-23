#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/package-homebrew-source.sh [output-dir]
EOF
}

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/release}"
VERSION="${ANOVABAR_RELEASE_VERSION:-}"

if [[ -z "$VERSION" ]]; then
    VERSION="$(awk '
        /^\[package\]$/ { in_package = 1; next }
        /^\[/ { in_package = 0 }
        in_package && /^version = / {
            gsub(/"/, "", $3)
            print $3
            exit
        }
    ' "$ROOT_DIR/Cargo.toml")"
fi

if [[ -z "$VERSION" ]]; then
    echo "error: could not determine package version" >&2
    exit 1
fi

ARCHIVE_NAME="anovabar-homebrew-source-$VERSION.tar.gz"
STAGE_PARENT="$(mktemp -d)"
STAGE_ROOT="$STAGE_PARENT/anovabar-$VERSION"

cleanup() {
    rm -rf "$STAGE_PARENT"
}

trap cleanup EXIT

mkdir -p "$OUTPUT_DIR" "$STAGE_ROOT"

tracked_inputs=(
    Cargo.toml
    Cargo.lock
    LICENSE
    src
    assets/anovabar-icon.png
    macos/anovabar-cli-Info.plist
    macos/build-app-icon.sh
    macos/build-cli-app.sh
)

while IFS= read -r -d "" file; do
    mkdir -p "$STAGE_ROOT/$(dirname "$file")"
    cp -p "$ROOT_DIR/$file" "$STAGE_ROOT/$file"
done < <(git -C "$ROOT_DIR" ls-files -z -- "${tracked_inputs[@]}")

(
    cd "$STAGE_PARENT"
    COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/$ARCHIVE_NAME" "anovabar-$VERSION"
)

echo "Wrote $OUTPUT_DIR/$ARCHIVE_NAME"
