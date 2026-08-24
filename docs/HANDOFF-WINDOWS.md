# Handoff — the Windows investigation is finished

**Status: X1 through X5 are all answered. There is nothing left that needs this
machine.** Everything below is a result, not a task.

The Windows box was the working reference: Windows 11 + VirtualDJ + the stock
Ploytec/Numark driver v2.9.64 drives this V7 with no hiccups, while the same
application on Apple Silicon through the OpenV7 bridge hiccups in vinyl mode.
That converted an open-ended search into a diff, and the diff is now measured.

Read [PROTOCOL.md](PROTOCOL.md) and [CONTROL-MAP.md](CONTROL-MAP.md) for the
detail. [HANDOFF-MAC.md](HANDOFF-MAC.md) covers the earlier protocol work.

---

## The two faults, both measured

They are independent. Neither would be found by tuning the other, which is
likely why a month of listening did not converge.

### 1. The Mac drops frames the vendor driver does not

| | Vendor driver (measured) | OpenV7 on macOS |
|---|---|---|
| Frame rate | **exactly 1000/s** | ~936/s |
| Max inter-frame gap | **1.675 ms** | ~17 ms bursts |
| Gaps ≥ 5 ms | **0** in 9,999 intervals | — |

Captured twice: once motor-only, once while VirtualDJ actually played a track
and the platter was scratched. Both hold 1000 frames in every one-second
bucket. **The deck emits one control frame per USB frame, exactly.**

`PROTOCOL.md` previously presented the ~936/s and the 17 ms bursts as *inherent
to the deck* — that is now corrected. They are a property of the macOS path,
which is losing roughly **6.4 % of frames in bursts**.

This matters for where to look next. If the gaps were real, the work is wrap
handling and interpolation. They are not, so the question is **why the bridge
drops frames the vendor driver does not**. The knobs already tried — control-IN
queue depth 1–16, keepalives on/off, logging — were the wrong ones.

### 2. VirtualDJ commands the motor on Windows and not on macOS

```
b0 41 7f   x3    MOTOR instant start
b0 42 7f   x2    MOTOR instant stop
```

Confirmed by eye too: the platter spins up on PLAY. On macOS, VDJ drives the
LEDs but has **never** been observed emitting `B0 41`/`42`/`43` in any capture.
**H5 confirmed — a mapping/definition difference, not a timing problem.**

Two details worth carrying:

- It uses **`0x41`/`0x42`**, a pair in **no published mapping**. They were found
  in this project by hardware probing; the community Mixxx map lacks them.
  VirtualDJ's Windows definition knows commands the community never documented.
- It sends value **`0x7F`** where our probing used `0x00`. The motor obeyed
  both, so the value is likely ignored — but `0x7F` is what the working system
  sends.

At idle with a track loaded but stopped, VDJ sends only the PLAY LED blinking on
a 500 ms period, and nothing else.

---

## The framing bug — X1's other result

**MIDI messages span the 42-byte frames.** 11.7 % of frames begin with a
leftover data byte from the previous frame's message:

```
frame N     b0 00 16   e0 4d             fd..fd 00     <- pitch-bend MSB absent
frame N+1   0b         b0 00 18  e0 02   fd..fd 00     <- it is here
```

The frame is a **transport container, not a message container**: strip the
`0xFD` filler and the trailing `0x00`, concatenate, then parse the byte stream.

Parsing frames independently corrupts about **one message in six**, and the
damage lands on the `0xE0` pitch-bend — the value a host uses for jog timing.
Over the same 12,161 captured frames:

| | per-frame parse | stream parse |
|---|---|---|
| Resync errors | — | **0** |
| `B0 00` range | 0..**253** (impossible) | 0..**127** ✅ |
| Delta/message | incoherent | mean **1.984**, min −1, max 3 |
| CC : pitch-bend pairing | broken | **12124 : 12124** exact |

---

## Settled along the way

- **`0xE0` is a timestamp**, 2,822,400 Hz. Proven against the device's own
  position counter rather than jittery host arrival times: grouped by position
  delta, the pitch-bend delta has stdev **49** where random would be 4729, and
  works out at ~1409 units per encoder count. Raw values look random only
  because the 14-bit counter wraps every 5.8 ms.
- **The OEM does not decimate, smooth, or rate-limit.** Raw wire rate equals the
  published MIDI rate.
- **The driver does not widen or unwrap** the 7-bit counter.
- **OEM iso-OUT cadence: 200.0 URBs/s**, mixing 2652- and 2640-byte URBs for
  529,282 B/s — 0.004 % from the reference, confirming the fractional
  accumulator in `iso_pace()`. (AUDIO-CODEC.md's "~400 URBs/s" was wrong.)
- **Strip search: releasing sends `0`**, which is ambiguous with "finger at the
  bottom of the strip". See CONTROL-MAP.md.
- **Port names differ**: Windows `Numark V7 MIDI`, our CoreMIDI source
  `Numark V7`. Cheap to test by renaming.
- **Library trio corroborated**: `0x09` PREPARE, `0x0A` FILES, `0x0B` CRATES —
  measured here independently of the macOS run, same answer.

---

## What to do on the Mac

In order of value.

1. **Find the frame loss.** The device delivers 1000/s; the bridge sees 936/s.
   This is now a bug with a known target rather than a mystery. Instrument the
   control-IN path and find where the 6.4 % goes.
2. **Parse the control stream as a byte stream**, not per-frame, if it does not
   already. One message in six is at stake.
3. **X2 — replay the captured stream.** `captures/vdj/vdj-inbound-0x83.tsv.gz`
   holds 68,678 inbound frames with arrival timestamps, taken while the working
   system played and scratched. Replay it into CoreMIDI verbatim and listen:
   - clean → our transport is exonerated, the encoding is the fault
   - hiccups → the fault is downstream of the bytes, and the search moves to
     CoreMIDI delivery or VirtualDJ's macOS build
4. **Make VDJ command the motor** — or establish why the macOS definition does
   not. Compare `captures/vdj/controllers-windows.dat` byte-for-byte against the
   macOS copy; it is opaque binary with no readable strings, so a diff is the
   only available test.

---

## Captures kept

Originals were ~500 MB across the session and one file alone was 202 MB, past
GitHub's hard 100 MB limit. Filtered to control traffic, everything of value
fits in ~15 MB.

| Path | What |
|---|---|
| `captures/vdj/vdj-inbound-0x83.tsv.gz` | The X2 artifact — 68,678 frames with timestamps |
| `captures/vdj/vdj-outbound-0x04.tsv` | Everything VirtualDJ sent, 318 frames |
| `captures/vdj/vdj-control.pcap` | Both directions + EP0 while VDJ played |
| `captures/vdj/controllers-windows.dat` | VDJ's Windows device definitions |
| `captures/usb/idle-USBPcap1-control.pcap` | 12,161 platter frames, motor-driven |
| `captures/usb/platter-frames.tsv` | Extracted platter stream |
| `captures/usb/sweep-USBPcap3-control.pcap` | 996 out, 0 in — the device answers nothing |

`captures/raw/` holds the unfiltered originals and stays gitignored.

---

## If you ever do come back

Machine state: vendor driver v2.9.64, Wireshark 4.6.8, USBPcap 1.5.4.0, ffmpeg
(user scope), GitHub CLI authenticated. `tools/win/build.ps1` rebuilds the DLLs.

Nothing is outstanding. The only untested items are cosmetic — the deck-B LED
block (`0x1D`–`0x33`) and whether LED values are graded (they are not; binary
was measured). LEDs have never been a problem.

**Do not fuzz the vendor SysEx space** under manufacturer `00 01 3F`:
`v7_usb.sys` exports `writeUC3UserFlash` and has a firmware-updater path, so
guessing command bytes risks writing MCU flash on irreplaceable hardware.

Tooling gotchas, all commented where they bit: USBPcap binds as a USB **class**
`UpperFilters` entry and only attaches when a device stack is built, so
`enable-usbpcap.ps1` restarts the root hub rather than requiring a reboot; its
control devices can **exist but refuse to open**, so a probe must treat anything
other than "could not find file" as present; `dumpcap` refuses to run without
Npcap, which USB capture does not need; and VirtualDJ holds the MIDI port
exclusively, so capture at the USB layer while it runs.
