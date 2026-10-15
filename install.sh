#!/bin/bash
# Builds and installs the app into /Applications, then launches it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Not Close"
SRC="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

./build.sh

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
