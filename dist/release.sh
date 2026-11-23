#!/usr/bin/env bash
# Build a release you can hand to someone:
#
#   build/release/OpenV7-<version>.dmg          drag-to-install app; the menu
#                                               item "Install Audio Device…"
#                                               adds the Numark V7 sound output
#   build/release/OpenV7-<version>-source.zip   this folder, minus build output
#                                               and logs
#   build/release/SHA256SUMS
#   build/release/OpenV7-<version>.zip          all of the above + README.txt,
#                                               the one file to send
#
# <version> comes from app/Info.plist. Runs the unit tests first and stops if
# any fail. Same signing knobs as dist/build-app.sh: DEVELOPER_ID (and
# NOTARY_PROFILE) for a distributable signature, ad-hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)"
OUT="$ROOT/build/release"
echo "==> OpenV7 $VER"

echo "==> unit tests"
for t in test audiotest drivertest; do
  if grep -q "^$t:" Makefile; then
    log="$(make "$t" 2>&1)" || { printf '%s\n' "$log"; echo "!! make $t failed"; exit 1; }
    echo "    $t: ok"
  fi
done

echo "==> app, audio device and DMG"
./dist/build-app.sh

rm -rf "$OUT"; mkdir -p "$OUT"
cp build/OpenV7.dmg "$OUT/OpenV7-$VER.dmg"

echo "==> source archive"
STAGE="$(mktemp -d)"
SRC="$STAGE/openv7-$VER"
mkdir "$SRC"
# Everything but build output, the locally built bridge, logs and Finder litter.
tar --exclude=./build --exclude=./openv7 --exclude='*.log' --exclude=.DS_Store \
    --exclude=./Makefile.new -cf - . | tar -xf - -C "$SRC"
(cd "$STAGE" && zip -qry "$OUT/openv7-$VER-source.zip" "openv7-$VER")
rm -rf "$STAGE"
# The changes since the upstream 1.0.3, as one reviewable patch, if present.
[ -f build/openv7-audio.patch ] && cp build/openv7-audio.patch "$OUT/openv7-$VER-changes-since-1.0.3.patch"

(cd "$OUT" && shasum -a 256 -- * > SHA256SUMS)

echo "==> one zip to send"
PKG="OpenV7-$VER"
STAGE="$(mktemp -d)"
mkdir "$STAGE/$PKG"
cp "$OUT"/* "$STAGE/$PKG/"
sed "s/@VERSION@/$VER/g" dist/README-RELEASE.txt > "$STAGE/$PKG/README.txt"
(cd "$STAGE" && zip -qry "$OUT/$PKG.zip" "$PKG")
rm -rf "$STAGE"

echo
echo "Done: $OUT"
ls -lh "$OUT" | sed 1d | awk '{printf "    %-6s %s\n", $5, $NF}'
echo
echo "Send $OUT/$PKG.zip -- it holds everything above plus a README."
