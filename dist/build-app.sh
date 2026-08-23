#!/usr/bin/env bash
# Build OpenV7.app — a self-contained menu-bar app (no Homebrew needed at runtime)
# and a drag-to-install DMG. Requires Xcode CLT + libusb (build-time only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/OpenV7.app"
mkdir -p "$BUILD"

# Deployment target. MUST track LSMinimumSystemVersion in app/Info.plist: without
# -mmacosx-version-min clang stamps the BUILD HOST's SDK version into the binary,
# so a DMG built on a current Mac refused to launch on every OS below it while the
# plist still advertised 13.0. Verify with `vtool -show-build`.
MACOS_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' app/Info.plist)"
echo "==> deployment target: macOS $MACOS_MIN (from app/Info.plist)"

LIBUSB_PREFIX="$(brew --prefix libusb 2>/dev/null || echo /usr/local)"
LIBUSB_A="$LIBUSB_PREFIX/lib/libusb-1.0.a"
[ -f "$LIBUSB_A" ] || { echo "static libusb not found at $LIBUSB_A (brew install libusb)"; exit 1; }

echo "==> building self-contained bridge (static libusb)"
clang -O2 -std=c11 -Wall -Wextra -Wno-deprecated-declarations \
  -mmacosx-version-min="$MACOS_MIN" \
  -I"$LIBUSB_PREFIX/include/libusb-1.0" \
  src/main.c src/nonap.m "$LIBUSB_A" \
  -framework CoreMIDI -framework CoreFoundation -framework Foundation -framework IOKit -framework Security \
  -o "$BUILD/openv7-bridge"

echo "==> building menu-bar app"
clang -O2 -fobjc-arc -Wall -Wextra \
  -mmacosx-version-min="$MACOS_MIN" \
  app/OpenV7App.m \
  -framework Cocoa -framework ServiceManagement -framework CoreMIDI -framework IOKit \
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
# Inside-out, NOT --deep: Apple deprecates --deep for signing (it is a
# verification convenience that happens to sign, and it silently applies the
# outer bundle's options to nested code). Sign the nested helper first, then
# the bundle that contains it.
codesign --force --sign - "$APP/Contents/MacOS/openv7-bridge"
codesign --force --sign - "$APP"

echo "==> verifying the bridge is self-contained (no libusb dylib):"
otool -L "$APP/Contents/MacOS/openv7-bridge" | sed 's/^/    /'

echo "==> verifying the deployment target matches app/Info.plist:"
for bin in OpenV7 openv7-bridge; do
  got="$(vtool -show-build "$APP/Contents/MacOS/$bin" | awk '/minos/{print $2; exit}')"
  printf '    %-16s minos %s\n' "$bin" "$got"
  [ "$got" = "$MACOS_MIN" ] || { echo "ERROR: $bin minos $got != $MACOS_MIN from Info.plist"; exit 1; }
done

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
