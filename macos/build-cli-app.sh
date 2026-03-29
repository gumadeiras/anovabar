#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="$ROOT_DIR/dist/AnovaBarCLI.app"
LAUNCHER_PATH="$ROOT_DIR/dist/anovabar"
EXECUTABLE_NAME="anovabar"

cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"

cp "$ROOT_DIR/target/release/$EXECUTABLE_NAME" "$BUNDLE_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT_DIR/macos/anovabar-cli-Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$BUNDLE_DIR"

cat >"$LAUNCHER_PATH" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/AnovaBarCLI.app"
STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"
STATUS_FILE="$(mktemp)"

cleanup() {
    rm -f "$STDOUT_FILE" "$STDERR_FILE" "$STATUS_FILE"
}

trap cleanup EXIT
rm -f "$STATUS_FILE"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: missing CLI app bundle at $APP_BUNDLE" >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    open -n "$APP_BUNDLE" \
        --env "ANOVABAR_EXIT_STATUS_PATH=$STATUS_FILE" \
        --stdout "$STDOUT_FILE" \
        --stderr "$STDERR_FILE"
else
    open -n "$APP_BUNDLE" \
        --env "ANOVABAR_EXIT_STATUS_PATH=$STATUS_FILE" \
        --stdout "$STDOUT_FILE" \
        --stderr "$STDERR_FILE" \
        --args "$@"
fi

while [[ ! -f "$STATUS_FILE" ]]; do
    sleep 0.1
done

cat "$STDOUT_FILE"
cat "$STDERR_FILE" >&2

exit "$(tr -d '\n' < "$STATUS_FILE")"
EOF

chmod +x "$LAUNCHER_PATH"

echo "Built $BUNDLE_DIR"
echo "Built $LAUNCHER_PATH"
