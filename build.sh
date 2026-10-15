#!/bin/bash
# Builds ClaudeNotClose.app — a bundle ready to drop into /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Not Close"
BINARY="ClaudeNotClose"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$BINARY" "$APP/Contents/MacOS/$BINARY"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "    (ad-hoc signing failed — the app still works)"

echo
echo "Done: $PWD/$APP"
echo
echo "Install:    ./install.sh"
echo "Quick test: open \"$APP\""
