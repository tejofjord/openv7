# VirtualDJ reference capture — the working system

Windows 11 + VirtualDJ + the stock Ploytec/Numark driver v2.9.64, driving this
V7 **with no hiccups**. Captured while actually playing a track and scratching,
so this is a working system doing the real job — not a synthetic test.

This is the reference the macOS side should be diffed against.

## Files

| File | What |
|---|---|
| `vdj-inbound-0x83.tsv.gz` | **The X2 artifact.** 68,678 inbound control frames with arrival timestamps, 90 s. This is what to replay into CoreMIDI on the Mac |
| `vdj-outbound-0x04.tsv` | Everything VirtualDJ sent to the deck, 318 frames |
| `vdj-control.pcap` | Both directions plus EP0, filtered from a 202 MB original |
| `controllers-windows.dat` | VirtualDJ's device definitions, Windows build. Opaque binary — compare byte-for-byte against the macOS copy |

The unfiltered 202 MB original is not kept; `tools/win/capture-vdj.ps1`
reproduces it.

## X4 — VirtualDJ **does** command the motor ✅

```
b0 41 7f  x3    MOTOR instant start
b0 42 7f  x2    MOTOR instant stop
```

Confirmed by eye as well: the platter spins up on PLAY.

On macOS, VirtualDJ has **never** been observed emitting `B0 41`/`42`/`43`
across any capture, while it does drive the LEDs. So **H5 is confirmed** — this
is a mapping/definition difference, not a timing problem.

Two details worth carrying:

- It uses **`0x41`/`0x42`** (instant start/stop), a pair that appears in **no
  published mapping**. They were found here by hardware probing; the community
  Mixxx map does not contain them. VirtualDJ's Windows definition knows commands
  the community never documented.
- It sends value **`0x7F`**. Probing used `0x00` and the motor obeyed both, so
  the value is likely ignored — but `0x7F` is what the working system sends.

The rest of the outbound traffic is LED feedback: `B0 07` x256 (SYNC,
beat-flashing), `B0 09` x53 (PLAY), plus `0x37` (pitch-at-zero), `0x04`, `0x05`.
At **idle** with a track loaded but stopped, VirtualDJ sends only the PLAY LED
blinking at a 500 ms period and nothing else.

## X5 — the inbound rate is a clean 1 kHz ✅

Per-second frame counts while playing and scratching:

```
t=1..t=12   1000, 1000, 1000, 1000, 1000, 999, 1001, 1000, 1000, 1000, 1000, 1000
t=13..t=26  (platter stopped - paused)
t=27..t=40  956, 1001, 1000, 1000, 1000, ...
```

The working system holds **exactly one frame per USB frame** under real load.
Combined with the earlier motor-only capture (max inter-frame gap 1.675 ms, zero
gaps >= 5 ms), this establishes that the ~936/s and ~17 ms bursts seen on macOS
are **not** the deck's behaviour. See `docs/PROTOCOL.md`.

## X3 — the port names differ

| | Port name |
|---|---|
| Windows (winmm) | `Numark V7 MIDI` |
| macOS (our virtual source) | `Numark V7` |

If VirtualDJ's definition keys on the exact string, renaming the CoreMIDI source
is a cheap thing to try. `controllers-windows.dat` is kept for a byte comparison
against the macOS copy; it is compressed or encrypted, with no readable strings,
so it cannot be decoded here.
