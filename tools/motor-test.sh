#!/bin/bash
# Spin one platter up and down under host control, and measure it.
#
#   ./openv7 -v > /tmp/ns7.log 2>&1 &
#   tools/motor-test.sh /tmp/ns7.log A        # deck A at 33 1/3
#   tools/motor-test.sh /tmp/ns7.log B 01     # deck B at 45
#
# Sequence: zero the pitch trim, select RPM (00 = 33 1/3, 01 = 45) and forward
# direction, SOFT START, measure for 6 s with tools/platter-tach.pl, BRAKE,
# measure 5 s. If the platter is still reporting motion afterwards -- or the
# script is interrupted -- it sends INSTANT STOP to both decks.
#
# Pitch trim is zeroed on purpose: the device keeps whatever trim it last had,
# and on the NS7 a stale value made "33 1/3" run at 42.3 RPM. Never assume it.
#
# Addresses are the V7 motor block (deck B = deck A + 0x0A), confirmed on both
# decks of a V7 (docs/CONTROL-MAP.md) and of an NS7 (docs/NS7-CONTROL-MAP.md).
# Needs build/midi-send (tools/midi-send.c).
#
# CLEAR THE PLATTERS FIRST. This makes them spin.
L=$1; DECK=$2; RV=${3:-00}
[ -n "$L" ] && [ -f "$L" ] || { echo "usage: $0 LOG A|B [00|01]"; exit 2; }
cd "$(dirname "$0")/.." || exit 1
[ -x build/midi-send ] || { echo "build/midi-send missing: see tools/midi-send.c"; exit 1; }
pgrep -x openv7 >/dev/null || { echo "bridge (openv7) is not running"; exit 1; }

if [ "$DECK" = "A" ]; then RPM=45; DIR=46; START=43; BRAKE=44; TRIM=49; TRIML=69; POS=00
elif [ "$DECK" = "B" ]; then RPM=4f; DIR=50; START=4d; BRAKE=4e; TRIM=53; TRIML=73; POS=02
else echo "usage: $0 LOG A|B [00|01]"; exit 2; fi
case "$RV" in
  00) EXPECT="33 1/3 rpm = 2000 cnt/s";;
  01) EXPECT="45 rpm = 2700 cnt/s";;
  *) echo "rpm value must be 00 or 01"; exit 2;;
esac

estop() { build/midi-send b0 42 00 b0 4c 00; echo "!! INSTANT STOP sent to both decks"; }
trap estop INT TERM

echo "== deck $DECK: pitch trim 0 (B0 $TRIM/$TRIML 00), rpm B0 $RPM $RV, forward B0 $DIR 00   [expect $EXPECT]"
build/midi-send b0 $TRIM 00 b0 $TRIML 00 b0 $RPM $RV b0 $DIR 00 || { estop; exit 1; }
sleep 1
echo "== deck $DECK: SOFT START (B0 $START 00)"
build/midi-send b0 $START 00 || { estop; exit 1; }
tools/platter-tach.pl "$L" 6 1.0
echo "== deck $DECK: BRAKE (B0 $BRAKE 00)"
build/midi-send b0 $BRAKE 00 || { estop; exit 1; }
tools/platter-tach.pl "$L" 5 1.0

before=$(wc -c < "$L")
sleep 1
moving=$(tail -c +$((before+1)) "$L" | grep -cE "^\s*in  b0 $POS ")
if [ "$moving" -gt 50 ]; then
  echo "== deck $DECK still reporting motion ($moving msgs/s) after brake"
  estop
  exit 3
fi
echo "== deck $DECK at rest ($moving position msgs in the last second)"
