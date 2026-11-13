#!/bin/bash
# The rest of the motor command set, measured: instant start/stop, reverse,
# ramp times, and the pitch-trim law. Companion to tools/motor-test.sh.
#
#   ./openv7 -v > /tmp/ns7.log 2>&1 &
#   tools/motor-extra.sh /tmp/ns7.log instant A
#   tools/motor-extra.sh /tmp/ns7.log reverse A|B
#   tools/motor-extra.sh /tmp/ns7.log ramp A        # 0x47 / 0x48 at 00 and 7f
#   tools/motor-extra.sh /tmp/ns7.log trim A        # s = +4000, then -4000
#
# Every test zeroes pitch trim and selects 33 1/3 first, ends with the platter
# stopped, and leaves direction forward and trim zero. Interrupting it sends
# INSTANT STOP to both decks. Needs build/midi-send (tools/midi-send.c).
#
# CLEAR THE PLATTERS FIRST. This makes them spin.
L=$1; TEST=$2; DECK=$3
[ -n "$L" ] && [ -f "$L" ] && [ -n "$TEST" ] && [ -n "$DECK" ] || { echo "usage: $0 LOG instant|reverse|ramp|trim A|B"; exit 2; }
cd "$(dirname "$0")/.." || exit 1
[ -x build/midi-send ] || { echo "build/midi-send missing: see tools/midi-send.c"; exit 1; }
pgrep -x openv7 >/dev/null || { echo "bridge (openv7) is not running"; exit 1; }

if [ "$DECK" = "A" ]; then
  ISTART=41; ISTOP=42; SSTART=43; BRAKE=44; RPM=45; DIR=46; RUP=47; RDN=48; TRIM=49; TRIML=69; POS=00
elif [ "$DECK" = "B" ]; then
  ISTART=4b; ISTOP=4c; SSTART=4d; BRAKE=4e; RPM=4f; DIR=50; RUP=51; RDN=52; TRIM=53; TRIML=73; POS=02
else echo "deck must be A or B"; exit 2; fi

S() { build/midi-send "$@" || { estop; exit 1; }; }
estop() { build/midi-send b0 42 00 b0 4c 00; echo "!! INSTANT STOP sent to both decks"; }
trap 'estop; exit 130' INT TERM
tach() { tools/platter-tach.pl "$L" "$1" "$2"; }
reset() { S b0 $TRIM 00 b0 $TRIML 00 b0 $RPM 00 b0 $DIR 00; }
at_rest() {
  before=$(wc -c < "$L"); sleep 1
  moving=$(tail -c +$((before+1)) "$L" | grep -cE "^\s*in  b0 $POS ")
  if [ "$moving" -gt 50 ]; then echo "== still moving ($moving msgs/s)"; estop; exit 3; fi
  echo "== deck $DECK at rest"
}

reset; sleep 1
case "$TEST" in
instant)
  echo "== INSTANT START (B0 $ISTART 00)   [V7: full speed in ~0.7 s]"
  S b0 $ISTART 00; tach 3 0.25
  echo "== INSTANT STOP (B0 $ISTOP 00)     [V7: stops immediately]"
  S b0 $ISTOP 00; tach 2 0.25
  at_rest ;;
reverse)
  echo "== direction REVERSE while stopped (B0 $DIR 01), then SOFT START (B0 $SSTART 00)   [expect about -33 rpm]"
  S b0 $DIR 01; sleep 0.5; S b0 $SSTART 00; tach 5 1.0
  echo "== BRAKE (B0 $BRAKE 00)"
  S b0 $BRAKE 00; tach 4 1.0
  at_rest
  S b0 $DIR 00; echo "== direction back to forward (B0 $DIR 00)" ;;
ramp)
  for v in 00 7f; do
    echo "== start ramp B0 $RUP $v, brake ramp B0 $RDN $v, SOFT START   [V7: higher = slower]"
    S b0 $RUP $v b0 $RDN $v; sleep 0.5; S b0 $SSTART 00; tach 8 0.5
    echo "== BRAKE"
    S b0 $BRAKE 00; tach 9 0.5
    at_rest
  done
  S b0 $RUP 00 b0 $RDN 00; echo "== ramps left at 00" ;;
trim)
  # s = +4000 -> 14-bit 4000 -> msb 0x1f, lsb 0x20 ; s = -4000 -> 12384 -> msb 0x60, lsb 0x60
  echo "== trim s=+4000 (B0 $TRIM 1f, B0 $TRIML 20), SOFT START   [V7 law: 33.33*(1+0.4) = 46.7 rpm]"
  S b0 $TRIM 1f b0 $TRIML 20; sleep 0.5; S b0 $SSTART 00; tach 5 1.0
  echo "== trim s=-4000 (B0 $TRIM 60, B0 $TRIML 60) while running   [V7 law: 33.33*(1-0.4) = 20.0 rpm]"
  S b0 $TRIM 60 b0 $TRIML 60; tach 5 1.0
  echo "== BRAKE"
  S b0 $BRAKE 00; tach 4 1.0
  at_rest
  S b0 $TRIM 00 b0 $TRIML 00; echo "== trim back to 0" ;;
*) echo "unknown test: $TEST"; exit 2 ;;
esac
