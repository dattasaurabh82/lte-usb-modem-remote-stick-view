#!/bin/bash
# Builds "LTE Stick View.app", signs it ad hoc, and installs it into /Applications.
#
#   scripts/build-app.sh                       build for this Mac and install
#   scripts/build-app.sh --no-install          build only, into build/
#   scripts/build-app.sh --universal           one app for Apple silicon and Intel
#   scripts/build-app.sh --dmg                 also make build/LTE-Stick-View-<version>.dmg and its .sha256
#
# The release workflow runs: scripts/build-app.sh --universal --dmg --no-install
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1; UNIVERSAL=0; DMG=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --universal) UNIVERSAL=1 ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option: $arg (use --no-install, --universal, --dmg)" >&2; exit 2 ;;
  esac
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="build/LTE Stick View.app"
DEST="/Applications/LTE Stick View.app"
mkdir -p build

echo "== icon"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o build/AppIcon.icns

echo "== release build ($([ $UNIVERSAL = 1 ] && echo "arm64 and x86_64" || echo "this Mac's architecture"))"
ARCHS=()
[ $UNIVERSAL = 1 ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/LTEStickView"

echo "== bundle, version $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LTEStickView"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
lipo -info "$APP/Contents/MacOS/LTEStickView"

echo "== sign (ad hoc)"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "signature ok"

if [ $DMG = 1 ]; then
  echo "== disk image"
  NAME="LTE-Stick-View-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "build/$NAME" "build/$NAME.sha256"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "LTE Stick View $VERSION" -srcfolder "$STAGE" -ov -format UDZO "build/$NAME" >/dev/null
  (cd build && shasum -a 256 "$NAME" > "$NAME.sha256")
  echo "made: build/$NAME"
  cat "build/$NAME.sha256"
fi

if [ $INSTALL = 0 ]; then
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
