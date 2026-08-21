#!/usr/bin/env bash
# Build OpenV7.app — a self-contained menu-bar app (no Homebrew needed at runtime)
# and a drag-to-install DMG. Requires Xcode CLT + libusb (build-time only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/OpenV7.app"
mkdir -p "$BUILD"

LIBUSB_PREFIX="$(brew --prefix libusb 2>/dev/null || echo /usr/local)"
LIBUSB_A="$LIBUSB_PREFIX/lib/libusb-1.0.a"
[ -f "$LIBUSB_A" ] || { echo "static libusb not found at $LIBUSB_A (brew install libusb)"; exit 1; }

echo "==> building self-contained bridge (static libusb)"
clang -O2 -std=c11 -Wall -Wno-deprecated-declarations \
  -I"$LIBUSB_PREFIX/include/libusb-1.0" \
  src/main.c "$LIBUSB_A" \
  -framework CoreMIDI -framework CoreFoundation -framework IOKit -framework Security \
  -o "$BUILD/openv7-bridge"

echo "==> building menu-bar app"
clang -O2 -fobjc-arc \
  app/OpenV7App.m \
  -framework Cocoa -framework ServiceManagement \
  -o "$BUILD/OpenV7"

echo "==> assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f app/AppIcon.icns ] || ./tools/build-icon.sh
cp app/Info.plist       "$APP/Contents/Info.plist"
cp app/AppIcon.icns     "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD/OpenV7"       "$APP/Contents/MacOS/OpenV7"
cp "$BUILD/openv7-bridge" "$APP/Contents/MacOS/openv7-bridge"
chmod +x "$APP/Contents/MacOS/"*

echo "==> ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo "==> verifying the bridge is self-contained (no libusb dylib):"
otool -L "$APP/Contents/MacOS/openv7-bridge" | sed 's/^/    /'

echo "==> building DMG"
DMG="$BUILD/OpenV7.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "OpenV7" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "Done:"
echo "  app: $APP"
echo "  dmg: $DMG"
echo
echo "Distribute the DMG. Users drag OpenV7 to Applications and double-click it."
echo "First launch (unsigned build): right-click the app -> Open -> Open."
