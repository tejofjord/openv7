#!/usr/bin/env bash
# Build build/NumarkV7.driver -- the "Numark V7" CoreAudio device (an
# AudioServerPlugIn; see driver/NumarkV7Audio.c). Install it with
#   ./install.sh --audio-driver
# which copies it to /Library/Audio/Plug-Ins/HAL and restarts coreaudiod.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
DRV="$BUILD/NumarkV7.driver"

# Same deployment-target and SDK rules as the app (see dist/build-app.sh): the
# floor comes from the bundle's own Info.plist, the SDK from tools/pick-sdk.sh.
MACOS_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' driver/Info.plist)"
SDK="$(./tools/pick-sdk.sh)"
echo "==> driver: macOS $MACOS_MIN+, SDK $(./tools/pick-sdk.sh --version)"

mkdir -p "$BUILD"
rm -rf "$DRV"
mkdir -p "$DRV/Contents/MacOS"

# arm64 + x86_64, exactly like BlackHole's release builds. NOT arm64e: coreaudiod
# hosts third-party plug-ins in a helper process of the plug-in's own
# architecture, and a third-party arm64e slice would be refused (the arm64e ABI
# is not open to non-Apple code).
# -fvisibility=hidden: the only exported symbol is the factory Info.plist names.
clang -O2 -std=c11 -Wall -Wextra -fvisibility=hidden -bundle \
  -arch arm64 -arch x86_64 \
  -isysroot "$SDK" -mmacosx-version-min="$MACOS_MIN" \
  driver/NumarkV7Audio.c \
  -framework CoreAudio -framework CoreFoundation \
  -o "$DRV/Contents/MacOS/NumarkV7"
cp driver/Info.plist "$DRV/Contents/Info.plist"
# coreaudiod loads the bundle as its own user, so it must be world-readable no
# matter what umask or file modes this checkout has (600 files = silently skipped).
chmod -R u=rwX,go=rX "$DRV"

# The factory must be exported, or coreaudiod silently skips the bundle.
# (Captured first: `nm | grep -q` under pipefail can fail on SIGPIPE.)
SYMS="$(nm -gU "$DRV/Contents/MacOS/NumarkV7")"
grep -q '_NumarkV7_Create$' <<<"$SYMS" || { echo "ERROR: NumarkV7_Create is not exported"; exit 1; }

# Signing: a Developer ID if DEVELOPER_ID is set (the same variable the app
# build uses), ad-hoc otherwise. Ad-hoc is what BlackHole's build-from-source
# instructions produce too; if a future macOS refuses ad-hoc HAL plug-ins, set
# DEVELOPER_ID and rebuild.
if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> signing with $DEVELOPER_ID"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$DRV"
else
  echo "==> ad-hoc signing (set DEVELOPER_ID to sign with your Developer ID)"
  codesign --force --sign - "$DRV"
fi
codesign --verify --strict "$DRV"

echo "Done: $DRV"
