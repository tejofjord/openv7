# Native audio (v2)

> **Status (2026-11-20):** ✅ **heard on a V7** — `--tone` played 440 Hz from
> DECK A's outputs and 660 Hz from DECK B's, so channels 3/4 need no mode
> switch. That first run also exposed the deck's own clock: a ~2 s burst of
> bit-crushed noise every ~20 s on both outputs, fixed by pacing iso-OUT from the
> deck's feedback (see [The deck's clock](#the-decks-clock)). 🔬 The fix is
> covered by a simulation (`make feedbacktest`) and awaits a re-run on the deck.
> The CoreAudio device has not been tried on hardware yet.

The V7's built-in soundcard is four channels out — DECK A L/R on channels 1/2,
DECK B L/R on 3/4 — carried on the same isochronous endpoint OpenV7 has always
streamed silence into as a clock. v2 puts real PCM in those bytes.

```text
  DJ app ──► "Numark V7" output ─┐   driver/NumarkV7.driver (CoreAudio plug-in, a loopback)
                                  └─► "Numark V7" input ──► openv7 --audio ──► iso-OUT 0x02 ──► V7 RCA outs
                                                                 │
                                         src/v7ring.c: ring + drift-corrected resampler
```

Two pieces:

| Piece | What it does |
|---|---|
| `driver/` | A CoreAudio device called **Numark V7**: 4 ch, 44.1 kHz, float. Apps play into its output; whatever they play comes back on its input. It never touches USB. |
| `src/audio.c`, `src/v7ring.c` | The bridge records that input and renders it into each iso URB as `S24_3LE`, exactly as many frames as `iso_pace()` gave the URB, so the rate on the wire stays 44,100 Hz by construction. |

The bridge keeps sole ownership of the deck (MIDI, motor, LEDs and audio), and
CoreAudio itself is the pipe between the plug-in and the bridge — no private IPC,
nothing running as root.

## Try it

### 1. Prove the USB audio path (no driver needed)

Quit OpenV7 from its menu-bar icon first — only one process can hold the deck.
Turn the mixer down, then:

```sh
./openv7 --tone --diag
```

| Expect | Means |
|---|---|
| 440 Hz from the **DECK A** RCA outputs | PCM in the iso stream works; the decoded format is right ✅ |
| 660 Hz from the **DECK B** outputs | channels 3/4 work without any extra mode switch ✅ |
| no burst of noise, however long you listen | the pacing follows the deck's clock |
| `[diag] … deck=44108/s fb-ok=1000/s … audio=tone peak=-18.1dBFS` | the deck's feedback is arriving and being used |

Leave it running for a few minutes: the fault this test caught first only
showed up every ~20 s.

### 2. Install the audio device

From the DMG: V7 menu-bar icon ▸ **Install Audio Device…** (1.1.0 and later
carry the device inside the app). From source:

```sh
./install.sh --audio-driver
```

It builds and tests the plug-in, copies it to `/Library/Audio/Plug-Ins/HAL`
(your password), and restarts CoreAudio (every app's audio blips once). The
menu-bar app always starts the bridge with `--audio`, so from then on it plays
the device automatically. The first time, macOS asks whether **OpenV7** may use
the microphone: say yes. That is the Numark V7 loopback, not a real microphone,
and while the bridge records it macOS shows its orange microphone dot.

### 3. Play

Pick **Numark V7** as the audio output in your DJ app. Channels 1-2 go to DECK A's
outputs and 3-4 to DECK B's, so for two decks into an external mixer, use the app's
external-mixer layout with deck 1 on channels 1-2 and deck 2 on 3-4.

## Without the driver

Any loopback device works, for example BlackHole:

```sh
./openv7 --audio "BlackHole 16ch" --diag            # channels 1,2 -> A, 3,4 -> B
./openv7 --audio "BlackHole 2ch"                    # stereo: both decks get 1,2
./openv7 --audio "BlackHole 16ch" --audio-map 5,6,7,8
```

## Latency

**In the app:** V7 menu ▸ **Audio Latency** — Safe (512), Normal (256, the
default), Low (128, 2 ms USB transfers), Lowest (64, 1 ms transfers). Picking
one restarts the bridge; the DJ app sees the deck reconnect. If a lower setting
crackles, go one step up. The DJ app's own buffer adds to whatever is chosen
here, so lower that too for the full effect.

Under the menu, four queues add up; all are tunable from the command line:

| Stage | Default | Low-latency example | Flag |
|---|---|---|---|
| iso-OUT queue to the deck | 8 URBs × 40 packets = 40 ms | 4 × 8 = 4 ms | `--iso-urb PACKETS` (8-40), `--iso-depth N` (2-16) |
| ring kept ahead of the reader | 12 ms + one IO buffer + one URB | 2 ms + 64 + 48 frames | `--audio-latency MS` |
| the bridge's CoreAudio IO buffer | 256 frames | 64 | `--audio-buffer FRAMES` |
| the loopback itself | about two of the DJ app's IO buffers | 2 × 64 | the app's buffer size |

Roughly 60-70 ms at the defaults, deliberately conservative. The iso queue is
the big one. The old "4 × 16-packet URBs (8 ms) crashed" result predates both
the pacing fix and the feedback, so it is being re-measured rather than
trusted:

```sh
tools/latency-sweep.sh        # quit OpenV7 first, mixer down
```

It plays the tone through 40, 16, 8, 6, 4, 3 and 2 ms of queue, 20 s each, says
each step out loud through the Mac's speakers, and writes one verdict line per
step to `build/latency-sweep.log`. Listen for the first step that clicks; the
one before it is the floor on this Mac. With audio on, the USB thread runs as a
real-time thread (`--no-rt` turns that off), and the resampler is told the
deck's measured rate (`ff` in `--diag`) so even a ring a few milliseconds deep
stays centred.

## The deck's clock

The V7 plays from its own 11.2896 MHz crystal ([HARDWARE.md](HARDWARE.md)), not
from the USB clock, and against the host it runs fast: the platter's timestamp
clock measured +153 and +179 ppm, and the stock driver was captured sending
+195 ppm more audio than a nominal 44.1 kHz. OpenV7 used to send exactly
44,100 frames per USB-second, so it starved the deck of ~8.6 frames a second.
With silence that was inaudible. With the tone it was a ~2 s screech every
~20 s: the deck's FIFO running dry, then recovering.

The deck reports what it actually plays. Iso IN `0x81` — drained and thrown
away until now — carries one 3-byte packet per millisecond whose first byte is
the number of frames played in it (44 or 45). The stock driver's strings name
it (`FEEDBACK FramePattern Locked`), and the
[Ozzy](https://github.com/mischa85/Ozzy) project documents the format for this
Ploytec family, V7 included. `src/v7feedback.h` does what the stock driver does:
every OUT microframe carries what the deck played in one earlier microframe,
each count used exactly once at a fixed lag, so the deck's FIFO keeps the level
it started at. `--no-feedback` brings the old fixed rate back for A/B.

This is probably also what the control stream's old "dies at ~24 s" was: the
same FIFO running dry with nothing audible to give it away, papered over by the
2 s status re-arm. Worth re-testing the keepalives now.

## Two clocks (host and deck)

The plug-in's clock is the Mac's host clock at a nominal 44.1 kHz; the deck now
takes frames at its own rate, ~195 ppm faster. A plain FIFO between them would
empty within seconds. So the bridge reads the ring through a 32-tap
Kaiser-windowed sinc resampler whose ratio is steered by how full the ring is:

- for 3 s after (re)priming it only watches, then takes the average fill as its
  setpoint;
- inside ±96 frames of the setpoint the ratio is **exactly 1.0** and the kernel
  is a unit impulse, so the copy is bit-exact (the tests check this). Against
  the V7's fast crystal that will not happen in practice: expect `adj` to settle
  near −195 ppm, a constant sub-sample stretch nobody can hear;
- outside it, the correction grows smoothly (100 frames off → 200 ppm), clamped
  at ±1000 ppm — under 2 cents of pitch;
- a 48 kHz source is converted to 44.1 kHz by the same reader.

## Reading `--diag`

```text
[diag] iso-out/s=200 iso-in/s=62 ... audio in/s=44100 fill=742 adj=+0.0ppm peak=-14.2dBFS u=0 o=0
```

| Field | Healthy | If not |
|---|---|---|
| `audio in/s` | ≈ 44100 | `0`: CoreAudio is not delivering. Microphone permission is the usual cause (System Settings ▸ Privacy & Security ▸ Microphone) |
| `peak` | rises when the app plays | stuck at `-200.0` while playing: the app is not playing into Numark V7, or permission was denied (CoreAudio then delivers zeros) |
| `deck` | ≈ 44100 (the V7 tested reads ~44108) | `0` with `fb-ok=0/s`: no usable feedback. The `[diag] feedback 0x81` line printed after ~1 s shows what the deck sent instead |
| `miss` | a few hundred from startup, then constant | climbing: feedback is arriving late or not at all |
| `adj` | steady, near −195 ppm on the V7 | pinned at ±1000 ppm: the clocks disagree far more than they should |
| `u` / `o` | 0 after start | rising: the ring under/overran. Raise `--audio-latency` |

## Uninstall

```sh
./install.sh --uninstall-audio-driver
```

Control keeps working; the bridge just logs that the device is missing.

## Still to confirm on a V7

- ✅ The tone test above, both decks.
- The tone test after the feedback fix: minutes without a burst.
- No long-idle stall with real audio flowing at iso depth 8.
- How low `--iso-depth` can go.
- Whether macOS loads an ad-hoc-signed HAL plug-in on every version in use. If
  it does not, `DEVELOPER_ID="Developer ID Application: …" ./install.sh --audio-driver`
  signs it properly.
