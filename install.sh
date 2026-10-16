#!/bin/bash
# Builds and installs the app into /Applications, then launches it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Not Close"
SRC="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

./build.sh

# Forced mode runs `pmset -a disablesleep 0|1`, which needs root. Allow exactly those two
# commands without a password so the app (and its quit cleanup) never blocks on a dialog.
PMSET="/usr/bin/pmset"
SUDOERS="/etc/sudoers.d/claude-not-close"
if ! sudo -n -l "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
    echo "==> Allowing 'pmset -a disablesleep 0|1' without a password (asks for your password once)"
    TMP="$(mktemp)"
    printf '%s ALL=(root) NOPASSWD: %s -a disablesleep 0, %s -a disablesleep 1\n' \
        "$(id -un)" "$PMSET" "$PMSET" > "$TMP"
    sudo visudo -cf "$TMP"
    sudo install -m 440 -o root -g wheel "$TMP" "$SUDOERS"
    rm -f "$TMP"
fi

echo "==> Quitting the running instance (if any)"
pkill -x ClaudeNotClose 2>/dev/null || true
sleep 1

echo "==> Installing into /Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Launching"
open "$DEST"

echo
echo "Done. The icon (cup / moon) is in the menu bar at the top of the screen."
echo "To start it automatically: menu -> Settings -> Launch at login."
