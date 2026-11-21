#!/usr/bin/env bash
# Collect what macOS says about the "Numark V7" audio device (the HAL plug-in in
# /Library/Audio/Plug-Ins/HAL) into build/audio-diag.txt. Read-only: changes
# nothing, needs no password.
#
#   ./tools/audio-diag.sh
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
OUT=build/audio-diag.txt
D=/Library/Audio/Plug-Ins/HAL/NumarkV7.driver
BIN="$D/Contents/MacOS/NumarkV7"
APPDRV=/Applications/OpenV7.app/Contents/Resources/NumarkV7.driver

sec() { printf '\n== %s\n' "$*"; }
{
  echo "audio-diag $(date '+%Y-%m-%d %H:%M:%S')  macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))  $(uname -m)"

  sec "HAL plug-in folder"
  ls -la /Library/Audio/Plug-Ins/HAL/ 2>&1

  sec "installed bundle"
  ls -laR "$D" 2>&1 | head -40
  sec "extended attributes (quarantine?)"
  xattr -lr "$D" 2>&1 | head -20
  sec "signature check"
  codesign --verify --strict -vvv "$D" 2>&1
  sec "signature details"
  codesign -dvvv "$D" 2>&1 | head -25
  sec "architectures and version stamps"
  lipo -archs "$BIN" 2>&1
  vtool -show-build "$BIN" 2>&1 | grep -E "architecture|minos|sdk"
  sec "exported factory"
  nm -gU "$BIN" 2>&1 | grep -i create
  sec "Info.plist"
  plutil -p "$D/Contents/Info.plist" 2>&1

  sec "copy inside /Applications/OpenV7.app"
  ls -la "$APPDRV" 2>&1
  codesign --verify --strict -vvv "$APPDRV" 2>&1
  diff -rq "$APPDRV" "$D" 2>&1 | head

  sec "audio devices macOS lists"
  system_profiler SPAudioDataType 2>/dev/null | grep -E "^ {8}[^ ].*:$" | sed 's/^ *//'
  system_profiler SPAudioDataType 2>/dev/null | grep -A10 "Numark V7:" || echo "   (no Numark V7 device)"

  sec "Core Audio processes"
  ps axo pid,lstart,comm | grep -i -E "coreaudiod|Core.Audio.Driver|NumarkV7|openv7" | grep -v grep

  sec "Core Audio log, last 3 h, about plug-ins"
  log show --last 3h --style compact \
    --predicate 'process == "coreaudiod" OR process CONTAINS[c] "Audio Driver" OR process CONTAINS[c] "AudioComponent"' 2>/dev/null \
    | grep -i -E "numark|openv7|NumarkV7|plug-?in|HAL|bundle|load|sign|reject|denied|fail" | tail -200

  sec "log lines naming the plug-in anywhere, last 3 h"
  log show --last 3h --style compact --predicate 'eventMessage CONTAINS[c] "NumarkV7" OR eventMessage CONTAINS[c] "com.openv7"' 2>/dev/null | tail -100

  sec "crash reports mentioning the plug-in"
  for f in $(ls -t /Library/Logs/DiagnosticReports/* ~/Library/Logs/DiagnosticReports/* 2>/dev/null | head -60); do
    grep -l -i -E "NumarkV7|openv7" "$f" 2>/dev/null
  done
} > "$OUT" 2>&1

echo "Wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)."
