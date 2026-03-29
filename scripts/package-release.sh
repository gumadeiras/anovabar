#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/package-release.sh [output-dir]
  ./scripts/package-release.sh --skip-build [output-dir]
EOF
}

SKIP_BUILD=0

if [[ "${1:-}" == "--skip-build" ]]; then
    SKIP_BUILD=1
    shift
fi

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: packaging requires macOS" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/release}"
CLI_STAGE_PARENT="$(mktemp -d)"
CLI_STAGE_DIR="$CLI_STAGE_PARENT/anovabar-cli-macos"

cleanup() {
    rm -rf "$CLI_STAGE_PARENT"
}

trap cleanup EXIT

if (( ! SKIP_BUILD )); then
    "$ROOT_DIR/macos/build-menubar-app.sh"
    "$ROOT_DIR/macos/build-cli-app.sh"
fi

if [[ ! -d "$ROOT_DIR/dist/AnovaBar.app" ]]; then
    echo "error: missing dist/AnovaBar.app" >&2
    exit 1
fi

if [[ ! -d "$ROOT_DIR/dist/AnovaBarCLI.app" ]]; then
    echo "error: missing dist/AnovaBarCLI.app" >&2
    exit 1
fi

if [[ ! -x "$ROOT_DIR/dist/anovabar" ]]; then
    echo "error: missing dist/anovabar launcher" >&2
    exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR" "$CLI_STAGE_DIR"

ditto -c -k --sequesterRsrc --keepParent \
    "$ROOT_DIR/dist/AnovaBar.app" \
    "$OUTPUT_DIR/AnovaBar.app.zip"

ditto "$ROOT_DIR/dist/AnovaBarCLI.app" "$CLI_STAGE_DIR/AnovaBarCLI.app"
cp "$ROOT_DIR/dist/anovabar" "$CLI_STAGE_DIR/anovabar"

cat >"$CLI_STAGE_DIR/README.txt" <<'EOF'
Keep `anovabar` and `AnovaBarCLI.app` in the same directory.

Example:
  ./anovabar --help

To install globally, move both files to a stable location and put the directory
containing `anovabar` on your PATH.
EOF

ditto -c -k --sequesterRsrc --keepParent \
    "$CLI_STAGE_DIR" \
    "$OUTPUT_DIR/anovabar-cli-macos.zip"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 AnovaBar.app.zip anovabar-cli-macos.zip > SHA256SUMS.txt
)

echo "Wrote release assets to $OUTPUT_DIR"
