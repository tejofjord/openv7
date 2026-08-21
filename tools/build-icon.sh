#!/usr/bin/env bash
# Render the OpenV7 app icon and build app/AppIcon.icns (all sizes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build

echo "==> rendering 1024px icon"
clang -fobjc-arc -framework Cocoa tools/makeicon.m -o build/makeicon
build/makeicon build/icon_1024.png

echo "==> building iconset"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"           build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
  d=$((s*2))
  sips -z "$d" "$d"           build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
cp build/icon_1024.png "$ICONSET/icon_512x512@2x.png"

echo "==> packing AppIcon.icns"
iconutil -c icns "$ICONSET" -o app/AppIcon.icns
echo "wrote app/AppIcon.icns"
