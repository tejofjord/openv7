# Numark NS7 — control map

The NS7 is a V7-family Ploytec device. The OpenV7 bridge drives it unchanged
apart from accepting its USB product ID. This page records every control the
NS7 reports to the host, and how sure each row is.

It is the NS7 companion to [CONTROL-MAP.md](CONTROL-MAP.md), which stays the
reference for anything the two devices share.

## Provenance and confidence

All measurements were taken on one physical NS7, on Apple Silicon macOS,
through the OpenV7 bridge (`./openv7 -v` and `./openv7 --learn`), in November 2026.

- ✅ **Measured on the NS7, one control at a time.** The control was moved on
  its own while the bridge log was watched live with
  [`tools/wait-control.pl`](../tools/wait-control.pl). Each burst was accepted
  only once it contained that control's address and nothing else. Where several
  buttons were pressed in sequence, their arrival order was checked against
  the order pressed.
- 📎 **Seen on the NS7, named by the deck-B rule.** These are deck-B controls
  that showed up in a full-panel `--learn` sweep but weren't pressed one at a
  time. Each has a measured deck-A twin, and the A → B offset was confirmed on
  six separate deck-B controls (see [Structural rules](#structural-rules)).
- ❔ **Not established.**

**Every input control on the panel is now accounted for.** Every deck-A and
mixer control is ✅, and the 📎 rows are deck-B twins of ✅ deck-A controls.

## Device identity

| Field | NS7 | V7 |
|---|---|---|
| USB VID:PID | `15E4:0071` ✅ | `15E4:0075` |
| `bcdDevice` | `0x0100` ✅ | `0x0100` |
| Firmware read (`'V'`, byte 0) | chip `0x31` ✅ | chip `0x33` |

The NS7's configuration descriptor matches the V7's endpoint table in
[PROTOCOL.md](PROTOCOL.md) exactly. Read it yourself with
[`tools/usb-descriptors.c`](../tools/usb-descriptors.c), which is read-only and
safe to run alongside the bridge. The descriptor has one configuration,
self-powered (0 mA), and two vendor-class interfaces whose endpoints all live
on alt setting 1:

```text
IF0 alt1  EP 0x02 OUT iso   156 B  interval 1   audio clock
          EP 0x83 IN  bulk  512 B               control / MIDI in
          EP 0x04 OUT bulk  512 B               control / MIDI out
IF1 alt1  EP 0x81 IN  iso    64 B  interval 4   audio return (drained)
          EP 0x86 IN  bulk  512 B               drained
```

The V7 handshake, iso pacing and keepalives work unchanged. The `--diag`
output held the healthy `iso-out/s=200 iso-in/s=62` figures from the first
second of every session, and every session tore down cleanly (exit 0).

## Structural rules

The NS7 behaves like a V7 whose A/B switch is set to both decks at once, plus a
mixer that the V7 does not have.

| Block | Left / deck A | Right / deck B | Offset |
|---|---|---|---|
| Deck buttons (note-on) | `0x0F`–`0x2B` | `0x30`–`0x4C` | **+0x21**, as on the V7 ✅ |
| Mixer channel strip (14-bit CC) | `0x08`–`0x0C` | `0x0D`–`0x11` | +0x05, but **not mirrored**: see below |

- **The deck-B offset was confirmed on six controls:** PLAY (`0x32`), HOT CUE 1
  (`0x34`), TRACK FORWARD (`0x41`), LOOP ON/OFF (`0x45`), the pitch fader
  (`B0 05`) and the strip (`B0 4D`). All six landed exactly where the rule
  predicts.
- **14-bit controls** send the coarse value on CC `n` and the fine value on
  CC `n+0x20`, the standard MIDI pairing that the V7 pitch fader also uses.
- **Buttons** send `90 nn 7F` on press and `90 nn 00` on release, never note-off.
- **Latching switches** send one `90 nn` message per flip, with no release. Each
  switch has its own polarity, so 127 does not consistently mean "left" or "on".
  The switch table below gives each one.
- The device sends **`B0 6E 00` once at start-up**. The V7 docs list it as idle
  chatter, and the bridge's learn mode skips it.

---

## Mixer: 14-bit faders and knobs ✅

Each of these is 14-bit (coarse `n`, fine `n+0x20`), and every one swept the
full range 0–127 in testing.

| Control | Left channel | Right channel |
|---|---|---|
| Channel fader | `B0 08` + `28` ✅ | `B0 0D` + `2D` ✅ |
| Bass | `B0 09` + `29` ✅ | `B0 0E` + `2E` ✅ |
| Mid | `B0 0A` + `2A` ✅ | `B0 0F` + `2F` ✅ |
| Treble | `B0 0B` + `2B` ✅ | `B0 10` + `30` ✅ |
| Gain trim | `B0 0C` + `2C` ✅ | `B0 11` + `31` ✅ |

| Control | Address |
|---|---|
| Crossfader | `B0 07` + `27` ✅ |
| Headphone mix (cue/program blend) | `B0 12` + `32` ✅ |

> The two channel strips use the **same order**: fader, then bass, mid,
> treble, gain, with the right strip at left + `0x05`. That is not a mirror
> image, so don't predict one side from the other by symmetry. Gain landed on
> `0x11`, not the `0x10` a mirror would give.

## Mixer: 7-bit knobs ✅

These send a single CC with no fine byte.

| Control | Address |
|---|---|
| Master volume | `B0 40` ✅ |
| Booth volume | `B0 41` ✅ |
| Headphone volume (front edge) | `B0 42` ✅ |
| Crossfader contour (front edge) | `B0 55` ✅ |

## Switches ✅

Each switch sends one message per flip, and the value is the new position.
Both positions of every switch were measured.

| Switch | Address | 127 | 0 |
|---|---|---|---|
| Headphone mode | `90 00` ✅ | left | right |
| Meter mode | `90 01` ✅ | left | right |
| Fader start, left | `90 02` ✅ | on (right) | off (left) |
| Fader start, right | `90 03` ✅ | on (right) | off (left) |
| Crossfader reverse | `90 04` ✅ | on (right) | off (left) |
| Motor torque | `90 05` ✅ | high (right) | low (left) |

- **The right fader-start switch bounces.** One flip to "off" sent three
  messages (0, 127, 0). A mapping should act on the last value rather than on
  each edge.
- **The crossfader reverse LED did not light** when that switch was turned on.
  V7 LEDs are host-driven ([CONTROL-MAP.md](CONTROL-MAP.md#leds)), so this LED
  probably needs a host command too. ❔ That hasn't been tested.

## Library and navigation (centre) ✅

These buttons send 127 on press and 0 on release. All are at the same addresses
as on the V7.

| Control | Address |
|---|---|
| BACK | `90 06` ✅ |
| FWD | `90 07` ✅ |
| Scroll knob press | `90 08` ✅ |
| PREPARE | `90 09` ✅ |
| FILES | `90 0A` ✅ |
| CRATES | `90 0B` ✅ |
| LOAD A | `90 0C` ✅ |
| LOAD PREPARE | `90 0D` ✅ |
| LOAD B | `90 0E` ✅ |
| Scroll knob turn | `B0 44` ✅: **relative**, one message per click. **`7F` (−1) = one click left / anticlockwise**, **`01` = one click right / clockwise** |

## Deck: continuous controls

| Control | Deck A | Deck B | Notes |
|---|---|---|---|
| Platter position | `B0 00` ✅ | `B0 02` 📎 | **Clockwise counts up** ✅. Hand-turning about 167° of deck A gave +1,667 counts net at 3,600 counts/rev |
| Platter timestamp | `E0` ✅ | **`E2`** 📎 | Paired **1:1** with position: 1,313 of each on deck A in a single turn ✅, and 4,049 of each on deck B in the sweep. Deck B's timestamp is on MIDI channel 3. The bridge matches on the status nibble, so it already forwards both |
| Pitch fader | `B0 04` + `24` ✅ | `B0 05` + `25` ✅ | 14-bit |
| Strip search | `B0 45` ✅ | `B0 4D` ✅ | **Left → right increases**, reaching 124 at the right end. See the strip notes below |
| START TIME knob | `B0 46` ✅ | `B0 4E` 📎 | 7-bit |
| STOP TIME knob | `B0 47` ✅ | `B0 4F` 📎 | 7-bit |

**Strip search on the NS7 differs from the V7 in two ways that matter to a
mapping:**

- **It jitters between 0 and 4 continuously at rest**, on both decks, whether
  touched or not. Over one session deck B sent 469 × `00`, 438 × `03`,
  103 × `02` and 87 × `04` while nobody touched it.
- **Lifting a finger falls back into that jitter, not to a clean 0.** On the V7,
  release sends `0` (see "Strip search — releasing sends `0`" under
  [CONTROL-MAP.md → Platter and continuous controls](CONTROL-MAP.md#platter-and-continuous-controls-cc-status-0xb0)).

So a mapping should treat **any value ≤ 4 as "not touched"** and ignore it.
Taking `0` as the release signal would fire constantly.

## Deck: buttons

Deck B = deck A + `0x21` throughout. Names follow the NS7 manual (p. 7–8) and
the panel labels on the measured unit.

| Note A | Note B | Control | A | B |
|---|---|---|---|---|
| `0x0F` | `0x30` | SYNC | ✅ | 📎 |
| `0x10` | `0x31` | CUE | ✅ | 📎 |
| `0x11` | `0x32` | PLAY / PAUSE | ✅ | ✅ |
| `0x12` | `0x33` | DELETE CUE | ✅ | 📎 |
| `0x13`–`0x17` | `0x34`–`0x38` | HOT CUE 1–5, left to right | ✅ | ✅ HOT CUE 1 · 📎 2–5 |
| `0x18` | `0x39` | PITCH BEND − | ✅ | 📎 |
| `0x19` | `0x3A` | PITCH BEND + | ✅ | 📎 |
| `0x1A` | `0x3B` | PITCH RANGE | ✅ | 📎 |
| `0x1B` | `0x3C` | KEYLOCK | ✅ | 📎 |
| `0x1C` | `0x3D` | **BLEEP**: held at 127 while the switch is pushed, 0 at centre | ✅ | 📎 |
| `0x1D` | `0x3E` | **REVERSE**: held at 127 while the switch is pushed, 0 at centre | ✅ | 📎 |
| `0x1E` | `0x3F` | TAP | ✅ | 📎 |
| `0x1F` | `0x40` | **TRACK BACK** ⏮ | ✅ | 📎 |
| `0x20` | `0x41` | **TRACK FORWARD** ⏭ | ✅ | ✅ |
| `0x21` | `0x42` | **MOTOR OFF** (the manual calls it SCRATCH OFF) | ✅ | 📎 |
| `0x22` | `0x43` | LOOP ½X | ✅ | 📎 |
| `0x23` | `0x44` | LOOP 2X | ✅ | 📎 |
| `0x24` | `0x45` | **LOOP ON / OFF** | ✅ | ✅ |
| `0x25` | `0x46` | LOOP SHIFT ◀ | ✅ | 📎 |
| `0x26` | `0x47` | LOOP SHIFT ▶ | ✅ | 📎 |
| `0x27` | `0x48` | **MODE** (manual / autoloop) | ✅ | 📎 |
| `0x28` | `0x49` | LOOP IN | ✅ | 📎 |
| `0x29` | `0x4A` | LOOP OUT | ✅ | 📎 |
| `0x2A` | `0x4B` | LOOP SELECT | ✅ | 📎 |
| `0x2B` | `0x4C` | RELOOP | ✅ | 📎 |

- **`0x1F` and `0x20` are new.** They are absent from the V7 table, and they
  are the NS7's track back/forward buttons.
- **`0x1C` / `0x1D` resolve the V7 table's "REVERSE / CENSOR" pair.** On the
  NS7 they are the two positions of the spring-loaded BLEEP / REVERSE switch:
  `1C` is BLEEP and `1D` is REVERSE.
- **`0x24` is LOOP ON / OFF**, measured on both decks. That settles the
  conflict in [CONTROL-MAP.md](CONTROL-MAP.md), which labels `0x24` both
  RELOOP/EXIT and LOOP CONTROL. RELOOP is a separate button, at `0x2B`. Both
  were pressed on their own and arrived at different addresses. The V7's loop
  section shares this layout, so the same answer very likely holds there, but
  it hasn't been confirmed on a V7.

## Hardware-only controls (no MIDI)

The **MIC/AUX switch** and the **MIC/AUX GAIN, BASS and TREBLE** knobs are
treated as analog-only, with no MIDI. None of them sent anything while moved,
in windows of 20–40 seconds. A longer 60-second retest was dropped as
unnecessary, because nothing in the mic/aux path has a software function.

The mic/aux knobs are the only knobs on the NS7 that don't send MIDI. Headphone
volume, master volume and booth volume all do.

## Output (host → device)

Everything here is sent as CC on status `0xB0`, one message per 42-byte frame,
by writing to the bridge's CoreMIDI destination. `-v` logs each one as
`out ...`. Use [`tools/midi-send.c`](../tools/midi-send.c) to send by hand.

### LEDs ✅

Each LED was driven on its own, and someone at the unit said which lamp lit.
Groups were lit one at a time, in a fixed order, and the order seen was checked
against the order sent. `0x00` = off, any non-zero value = on.

**Deck B is deck A + `0x16` for the lower block, and + `0x17` from KEYLOCK
onward.** CC `0x26` sits in between and drives nothing. This is also what the
V7 table's *rows* say, although that table's header gives a flat +`0x16`. Don't
apply one offset to the whole block.

| CC A | CC B | Lamp | A | B |
|---|---|---|---|---|
| `0x07` | `0x1D` | SYNC | ✅ | ✅ |
| `0x08` | `0x1E` | CUE | ✅ | ✅ |
| `0x09` | `0x1F` | PLAY / PAUSE | ✅ | ✅ |
| `0x0A` | `0x20` | DELETE CUE | ✅ | 📎 +`0x16` |
| `0x0B`–`0x0F` | `0x21`–`0x25` | HOT CUE 1–5, left to right | ✅ | ✅ HOT CUE 1 · 📎 2–5 |
| — | `0x26` | nothing (offset gap) | | ✅ no lamp |
| `0x10` | `0x27` | KEYLOCK | ✅ | ✅ |
| `0x11` | `0x28` | **No visible lamp.** On the V7 this is TAP, but the NS7's TAP LED is lit by the device itself and stays lit whatever is sent | ✅ | ✅ |
| `0x12` | `0x29` | MOTOR OFF | ✅ | ✅ |
| `0x13`–`0x17` | `0x2A`–`0x2E` | LOOP ½X, 2X, ON/OFF, SHIFT ◀, SHIFT ▶ | ✅ | ✅ ½X · 📎 rest |
| `0x18`–`0x1C` | `0x2F`–`0x33` | MODE, IN, OUT, SELECT, RELOOP | ✅ | ✅ MODE, RELOOP · 📎 rest |
| `0x37` | `0x38` | Pitch fader at 0 % (deck A / deck B) | ✅ | ✅ |

📎 = the measured offset for that block, applied to a measured deck-A lamp.

Global LEDs:

| CC | Lamp | Status |
|---|---|---|
| `0x00` | **FSTART A** | ✅ |
| `0x01` | **FSTART B** | ✅ |
| `0x02` | **Crossfader reverse** | ✅ |
| `0x03` / `0x04` / `0x05` | PREPARE / FILES / CRATES | ✅ |
| `0x34` | **Left output level meter**: value `0x00`–`0x0C` = empty → full | ✅ |
| `0x35` | **Right output level meter**: value `0x00`–`0x0C` = empty → full | ✅ |
| `0x36` | **BPM meter**: the red LED strip with a white centre LED, above the master knob. Takes the same 0–12 range | ✅ |
| `0x39` | **Every LED on (`7F`) / every LED off (`00`)** | ✅ |

- **`0x34`–`0x36` are a group of three on both devices, but the NS7 uses them
  differently.** On the V7 they were listed as one numeric display. On the NS7
  they are two output meters and a tempo-match meter. Each was swept 0 → 12
  and climbed in step.
- **The three switch LEDs (`0x00`–`0x02`) are host-driven only.** Flipping a
  switch does not light its LED, and the LED follows the host whatever the
  switch says. All three were lit with every switch off, and again with only
  FSTART B's switch off. A mapping that wants the LED to show the switch must
  echo the switch's own report (`90 02`–`04`) back as the matching CC.
  - These three were missed in the first two scans, where each was lit for
    only 2–2.5 seconds, and they were only found when all candidates were lit
    together and narrowed down. A switch-gating theory was put forward and
    then disproved by that all-switches-off test. **A brief single-lamp flash
    is easy to miss, so confirm a "no lamp" result by holding the lamp on.**
- **No visible effect** came from `0x06`, `0x11`, `0x26`, `0x28` or `0x3A`–`0x3F`,
  even when lit together and held. Above `0x40` (excluding the motor range
  `0x41`–`0x53` and pitch trim `0x69`/`0x73`), all 43 addresses were checked by
  binary search with each group held on. None lit the three switch LEDs, and
  nothing else was reported lighting.
- **Note-on doesn't drive LEDs.** `90 02`–`04` (the switches' own input
  addresses) lit nothing, as on the V7.

### Motor ✅

**The V7 motor block works unchanged: deck B = deck A + `0x0A`.** Speed was
measured from the platter's own position counter with
[`tools/platter-tach.pl`](../tools/platter-tach.pl). Runs used
[`tools/motor-test.sh`](../tools/motor-test.sh) (start/brake at each RPM) and
[`tools/motor-extra.sh`](../tools/motor-extra.sh) (everything else).

| CC A | CC B | Function | A | B |
|---|---|---|---|---|
| `0x41` | `0x4B` | Instant start: 33 RPM in about 0.75 s | ✅ | 📎 |
| `0x42` | `0x4C` | Instant stop: at rest in about 0.5 s, then rocks back about 2° as it settles | ✅ | 📎 |
| `0x43` | `0x4D` | Soft start: speed set by the start-ramp time | ✅ | ✅ |
| `0x44` | `0x4E` | Brake: speed set by the brake-ramp time | ✅ | ✅ |
| `0x45` | `0x4F` | RPM select: `00` = 33⅓, `01` = 45 | ✅ | ✅ |
| `0x46` | `0x50` | Direction: `00` forward, `01` **reverse** (−33.2 / −33.3 RPM). Set while stopped | ✅ | ✅ |
| `0x47` | `0x51` | Start-ramp time: higher = slower | ✅ | 📎 |
| `0x48` | `0x52` | Brake-ramp time: higher = slower | ✅ | 📎 |
| `0x49`+`0x69` | `0x53`+`0x73` | Pitch trim, signed 14-bit. **Applies live while running** | ✅ | ✅ zero only |

📎 = the confirmed +`0x0A` deck offset, applied to a measured deck-A command.

**Ramp times** were tested only at the two extremes, on deck A:

| Value | Spin-up | Brake to rest |
|---|---|---|
| `0x00` | about 0.75 s to full speed | about 1 s |
| `0x7F` | **about 8 s** to 90 %, climbing steadily at about 3 RPM/s | **about 8 s**, from 30 RPM |

At `0x7F` the NS7 ramps more slowly than the V7 (5.9 s up). Whether the NS7
also lumps nearby values together, like the V7's few coarse ramp steps, is
untested. The scripts leave both ramps at `0x00` afterwards. The NS7's
power-on ramp values are unknown; the default soft start took 1–1.5 s.

**Pitch trim** follows the V7's law, `speed = nominal × (1 + s/10000)`, closely
but not exactly. Measured on deck A at 33⅓:

| `s` | V7 law | Measured | |
|---|---|---|---|
| +4000 | 46.7 RPM | **46.3 RPM** | −0.9 % |
| −4000 | 20.0 RPM | **19.3 RPM** | −3.5 % |

Part of that is the NS7's base speed running slightly under (33.2 rather than
33.3). The slow end still runs about 3 % under after allowing for that, where
the V7 was within 0.4 %. A host that corrects speed using the platter's own
position counter would absorb the difference.

Measured steady speeds, with pitch trim zeroed:

| | 33⅓ (`00`) | 45 (`01`) |
|---|---|---|
| Deck A | 33.2 RPM (1,993 counts/s) | 44.6 RPM (2,678 counts/s) |
| Deck B | 33.3 RPM (2,000 counts/s) | 44.7 RPM (2,683 counts/s) |

Each held within ±0.1 RPM over 5 s.

- **The decks are independent.** The V7 answers one command block at a time,
  chosen by its A/B switch. The NS7 answers both at once: while deck B ran,
  deck A reported no movement at all, and the reverse was also true.
- **Always set pitch trim before starting a motor.** The NS7 keeps whatever
  trim it last had. The very first soft start, sent without touching trim,
  ran at **42.3 RPM** at "33⅓". With trim zeroed, the same command gave 33.2.
- **The encoder has the V7's resolution.** One clockwise revolution turned by
  hand read **+3,665 counts**, against the V7's 3,600. The difference is within
  hand-alignment error (about 6°). The motor speeds also read 0.4–0.9 % under
  nominal at 3,600 counts/rev. Both point to the same 3,600-count encoder, or
  one very slightly under it.

Not tested: setting reverse *while* the platter is spinning (the V7 ignores
it), intermediate ramp values, and pitch trim on deck B beyond zero.

## Still to verify

The input side is complete. What remains:

```text
Motor          optional: intermediate ramp values; reverse set while spinning;
               pitch trim on deck B beyond zero
Deck B         optional: the remaining deck-B rows marked 📎, if a mapping ever
               behaves unexpectedly on deck B only
```

Inputs, LEDs and the motor command set are all confirmed. Every remaining
item is a refinement, not a gap.

Measure one control at a time with the bridge in `-v`, using
[`tools/wait-control.pl`](../tools/wait-control.pl) (its header shows how). For
a strip or platter, set `NS7_KEEP` (for example `NS7_KEEP="b0 45"`), because
the watcher otherwise filters those addresses out as background noise. For a
strip, also set `NS7_FLOOR=8`. The strip's 0–4 rest jitter never pauses, so
without a floor the watcher never sees the gesture end.
