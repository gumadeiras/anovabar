#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${ANOVABAR_INSTALL_ROOT:-$HOME/.local/share/anovabar}"
BIN_DIR="${ANOVABAR_BIN_DIR:-$HOME/.local/bin}"
APP_NAME="AnovaBarCLI.app"
APP_SOURCE="$ROOT_DIR/dist/$APP_NAME"
APP_DEST="$INSTALL_ROOT/$APP_NAME"
LAUNCHER_PATH="$BIN_DIR/anovabar"

"$ROOT_DIR/macos/build-cli-app.sh"

mkdir -p "$INSTALL_ROOT" "$BIN_DIR"
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"

cat >"$LAUNCHER_PATH" <<EOF
#!/usr/bin/env bash

set -euo pipefail

APP_BUNDLE="$APP_DEST"
STDOUT_FILE="\$(mktemp)"
STDERR_FILE="\$(mktemp)"
STATUS_FILE="\$(mktemp)"

cleanup() {
    rm -f "\$STDOUT_FILE" "\$STDERR_FILE" "\$STATUS_FILE"
}

trap cleanup EXIT
rm -f "\$STATUS_FILE"

if [[ ! -d "\$APP_BUNDLE" ]]; then
    echo "error: missing CLI app bundle at \$APP_BUNDLE" >&2
    exit 1
fi

if [[ \$# -eq 0 ]]; then
    open -n "\$APP_BUNDLE" \
        --env "ANOVABAR_EXIT_STATUS_PATH=\$STATUS_FILE" \
        --stdout "\$STDOUT_FILE" \
        --stderr "\$STDERR_FILE"
else
    open -n "\$APP_BUNDLE" \
        --env "ANOVABAR_EXIT_STATUS_PATH=\$STATUS_FILE" \
        --stdout "\$STDOUT_FILE" \
        --stderr "\$STDERR_FILE" \
        --args "\$@"
fi

while [[ ! -f "\$STATUS_FILE" ]]; do
    sleep 0.1
done

cat "\$STDOUT_FILE"
cat "\$STDERR_FILE" >&2

exit "\$(tr -d '\n' < "\$STATUS_FILE")"
EOF

chmod +x "$LAUNCHER_PATH"

cat <<EOF
Installed $APP_DEST
Installed $LAUNCHER_PATH

If needed, add $BIN_DIR to your PATH:
  export PATH="$BIN_DIR:\$PATH"
EOF
