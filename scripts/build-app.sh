#!/bin/bash
# Builds "LTE Stick View.app", signs it ad hoc for this Mac, and installs it into /Applications.
# Run from anywhere: scripts/build-app.sh            build and install
#                    scripts/build-app.sh --no-install   build only, into build/
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/LTE Stick View.app"
DEST="/Applications/LTE Stick View.app"

echo "== icon"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o build/AppIcon.icns

echo "== release build"
swift build -c release

echo "== bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LTEStickView "$APP/Contents/MacOS/LTEStickView"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "== sign (ad hoc, for this Mac only)"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "signature ok"

if [ "${1:-}" = "--no-install" ]; then
  echo "built: $APP"
  exit 0
fi

if pgrep -f "$DEST/Contents/MacOS/LTEStickView" >/dev/null; then
  echo "LTE Stick View is running from /Applications; quit it first, then run this again." >&2
  exit 1
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed: $DEST"
