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

# SDK selection. A Mach-O records TWO versions and BOTH gate launch: `minos`
# (above) and the version of the SDK it was built against. macOS refuses to run a
# GUI app whose recorded sdk comes from a FUTURE MAJOR OS -- it reports "You can't
# use this version of the application with this version of macOS", which reads
# like a corrupt download and is nothing of the sort.
#
# Bare `clang` does NOT use the SDK `xcrun` reports; it resolves to the Command
# Line Tools SDK. On a machine running a macOS seed that is the seed's SDK, so
# every DMG built here was stamped `sdk 27.0` and could only launch on macOS 27 --
# working perfectly for the person who built it and for nobody else. The old
# `vtool` check below caught a wrong `minos` and sailed straight past this,
# because it only ever looked at one of the two fields.
#
# tools/pick-sdk.sh owns the ceiling and the search; it is shared with the
# Makefile so the two build paths cannot drift apart on this.
MACOS_SDK_MAX="$(./tools/pick-sdk.sh --max)"
SDK="$(./tools/pick-sdk.sh)"
SDK_VER="$(./tools/pick-sdk.sh --version)"
export SDKROOT="$SDK"
echo "==> SDK: macOS $SDK_VER (max allowed major: $MACOS_SDK_MAX)"
echo "    $SDK"

LIBUSB_PREFIX="$(brew --prefix libusb 2>/dev/null || echo /usr/local)"
LIBUSB_A="$LIBUSB_PREFIX/lib/libusb-1.0.a"
[ -f "$LIBUSB_A" ] || { echo "static libusb not found at $LIBUSB_A (brew install libusb)"; exit 1; }

echo "==> building self-contained bridge (static libusb)"
clang -O2 -std=c11 -Wall -Wextra -Wno-deprecated-declarations \
  -isysroot "$SDK" -mmacosx-version-min="$MACOS_MIN" \
  -I"$LIBUSB_PREFIX/include/libusb-1.0" \
  src/main.c src/nonap.m "$LIBUSB_A" \
  -framework CoreMIDI -framework CoreFoundation -framework Foundation -framework IOKit -framework Security \
  -o "$BUILD/openv7-bridge"

echo "==> building menu-bar app"
clang -O2 -fobjc-arc -Wall -Wextra \
  -isysroot "$SDK" -mmacosx-version-min="$MACOS_MIN" \
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

# Signing. DEVELOPER_ID (a "Developer ID Application: ..." identity) upgrades this
# from ad-hoc to a distributable signature; NOTARY_PROFILE additionally submits
# the DMG to Apple and staples the ticket, which is what removes the first-launch
# block on the user's Mac entirely. With neither set, the ad-hoc build still runs
# -- the user just has to approve it once in System Settings.
#
# Notarization REQUIRES the hardened runtime and a secure timestamp, and the
# hardened runtime gates USB behind com.apple.security.device.usb. The bridge
# talks to the V7 over libusb, so a distribution build without that entitlement
# would sign, notarize, launch -- and then find no device.
#
# Inside-out, NOT --deep: Apple deprecates --deep for signing (it is a
# verification convenience that happens to sign, and it silently applies the
# outer bundle's options to nested code). Sign the nested helper first, then
# the bundle that contains it.
SIGN_ID="${DEVELOPER_ID:-}"
if [ -n "$SIGN_ID" ]; then
  echo "==> code signing for distribution: $SIGN_ID"
  SIGN_ARGS=(--force --options runtime --timestamp
             --entitlements "$ROOT/dist/OpenV7.entitlements" --sign "$SIGN_ID")
else
  echo "==> ad-hoc code signing (set DEVELOPER_ID to sign for distribution)"
  SIGN_ARGS=(--force --sign -)
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/openv7-bridge"
codesign "${SIGN_ARGS[@]}" "$APP"

echo "==> verifying the bridge is self-contained (no libusb dylib):"
otool -L "$APP/Contents/MacOS/openv7-bridge" | sed 's/^/    /'

echo "==> verifying the recorded versions (BOTH gate launch, so check both):"
for bin in OpenV7 openv7-bridge; do
  ./tools/check-stamps.sh "$APP/Contents/MacOS/$bin" "$MACOS_MIN"
done

echo "==> building DMG"
DMG="$BUILD/OpenV7.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "OpenV7" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$SIGN_ID" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> notarizing (uploads the DMG to Apple and waits for the verdict)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> stapling the ticket so first launch works offline"
  xcrun stapler staple "$DMG"
elif [ -n "$SIGN_ID" ]; then
  echo "==> signed but NOT notarized (set NOTARY_PROFILE to notarize)"
fi

# The verdict the end user's Mac will reach. "accepted" means a plain
# double-click works; "rejected" means they must approve it once in
# System Settings -> Privacy & Security -> Open Anyway.
echo "==> Gatekeeper verdict for the recipient:"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/    /' || true

echo
echo "Done:"
echo "  app: $APP"
echo "  dmg: $DMG"
echo
echo "Distribute the DMG. Users drag OpenV7 to Applications and double-click it."
echo "First launch: macOS blocks it (not notarized). Approve once in System Settings"
echo "-> Privacy & Security -> Open Anyway. Control-click -> Open was removed in macOS 15."
