#!/usr/bin/env bash
# Find how shallow the V7's audio queue can go on this Mac.
#
# Plays the --tone test through a series of iso-OUT queue depths, SECS seconds
# each, and announces every step through the Mac's own speakers (`say`), so you
# can listen to the DECK outputs and note where it starts to click or crackle.
#
#   tools/latency-sweep.sh                 quit OpenV7 first; mixer DOWN
#   STEPS="8:4 8:3" SECS=60 tools/latency-sweep.sh      custom steps, longer
#
# A step is PACKETS:URBS -- packets per URB (8 = 1 ms, 40 = 5 ms) and URBs in
# flight; the queue to the deck is their product / 8 ms. One summary line per
# step goes to build/latency-sweep.log, the full output to build/sweep-*.log.
#
# Every step re-attaches to the deck. If control misbehaves afterwards,
# power-cycle the deck -- this measures audio only.
set -euo pipefail
cd "$(dirname "$0")/.."

STEPS="${STEPS:-40:8 8:16 8:8 8:6 8:4 8:3 8:2}"
SECS="${SECS:-20}"
LOG=build/latency-sweep.log
mkdir -p build

make >/dev/null || { echo "!! build failed -- run make to see why"; exit 1; }

if pgrep -f "/OpenV7.app/Contents/MacOS/OpenV7" >/dev/null 2>&1; then
  echo "==> quitting the OpenV7 app (only one program can hold the deck)"
  osascript -e 'tell application id "com.openv7.app" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
pkill -f openv7-bridge 2>/dev/null || true
pkill -x openv7 2>/dev/null || true
sleep 1

echo "===== latency sweep $(date '+%Y-%m-%d %H:%M:%S')  ${SECS}s per step =====" | tee -a "$LOG"
for st in $STEPS; do
  P="${st%%:*}"; N="${st##*:}"
  MS="$(awk -v p="$P" -v n="$N" 'BEGIN { printf "%g", p * n / 8 }')"
  WANT=$((8000 / P))
  OUT="build/sweep-$P-$N.log"
  printf '\n==> %s ms   (--iso-urb %s --iso-depth %s)  listen...\n' "$MS" "$P" "$N"
  say "$MS milliseconds" >/dev/null 2>&1 &
  ./openv7 --tone --diag --iso-urb "$P" --iso-depth "$N" >"$OUT" 2>&1 &
  pid=$!
  sleep "$SECS"
  kill -TERM "$pid" 2>/dev/null || true   # TERM: background jobs of a script ignore INT
  wait "$pid" 2>/dev/null || true

  # Skip the first two diag lines (start-up), then judge the iso-OUT rate.
  rates="$(grep -o 'iso-out/s=[0-9]*' "$OUT" | cut -d= -f2 | tail -n +3 || true)"
  if [ -z "$rates" ]; then
    line="$MS ms ($P x $N): did not run -- see $OUT"
  else
    lo="$(sort -n <<<"$rates" | head -1)"; hi="$(sort -n <<<"$rates" | tail -1)"
    off="$(awk -v w="$WANT" '{ if ($1 < w * 0.98 || $1 > w * 1.02) n++ } END { print n + 0 }' <<<"$rates")"
    fails="$(grep -c 'submit failed' "$OUT" || true)"
    bad="$(grep -o 'bad=[0-9]*' "$OUT" | tail -1 | cut -d= -f2 || true)"
    miss="$(grep -o 'miss=[0-9]*' "$OUT" | tail -1 | cut -d= -f2 || true)"
    if grep -q 'is real-time' "$OUT"; then rt=rt; else rt=not-rt; fi
    verdict="clean"
    if [ "$off" -gt 0 ] || [ "$fails" -gt 0 ]; then verdict="UNSTEADY"; fi
    line="$(printf '%5s ms (%2s x %2s): %-8s iso-out/s %s..%s (want %s, %s off)  submit-fails %s  fb bad %s miss %s  %s' \
            "$MS" "$P" "$N" "$verdict" "$lo" "$hi" "$WANT" "$off" "$fails" "${bad:-?}" "${miss:-?}" "$rt")"
  fi
  echo "$line" | tee -a "$LOG"
  sleep 2     # let the deck settle between owners
done
say "sweep done" >/dev/null 2>&1 || true
printf '\nDone. Which step was the first one you heard clicks on? (summary: %s)\n' "$LOG"
