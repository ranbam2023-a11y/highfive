#!/usr/bin/env bash
#
# Builds HighFive.app (and optionally a .dmg) into ./build and ./dist.
# Nothing is installed by this script.
#
#   ./build.sh          build the app
#   ./build.sh --dmg    build the app and a distributable .dmg
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="HighFive"
VERSION="1.0"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/$APP_NAME.app"
ICNS="$ROOT/assets/AppIcon.icns"
ICONSET="$BUILD/AppIcon.iconset"

WANT_DMG=0
[ "${1:-}" = "--dmg" ] && WANT_DMG=1

echo "==> Building $APP_NAME $VERSION"
mkdir -p "$BUILD"

# ---- icon -----------------------------------------------------------------
if [ ! -f "$ICNS" ] || [ "$ROOT/src/make-icon.swift" -nt "$ICNS" ] || [ ! -f "$ROOT/assets/icon_1024.png" ]; then
  echo "--> generating icon"
  swiftc -O "$ROOT/src/make-icon.swift" -o "$BUILD/make-icon"
  "$BUILD/make-icon" "$ROOT/assets/icon_1024.png"

  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/assets/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ROOT/assets/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi

# ---- compile --------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "--> compiling"
swiftc -O -import-objc-header "$ROOT/src/mt.h" "$ROOT/src/main.swift" \
       -o "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

echo "--> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Built $APP"

# ---- dmg ------------------------------------------------------------------
if [ "$WANT_DMG" = "1" ]; then
  DMG="$DIST/$APP_NAME-$VERSION.dmg"
  STAGE="$BUILD/dmg"
  echo "==> Packaging $DMG"
  mkdir -p "$DIST"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
          -ov -format UDZO "$DMG"
  echo "==> Wrote $DMG"
fi
