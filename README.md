# OpenV7

**A userspace driver that brings the discontinued Numark V7 back to life on modern macOS.**

The [Numark V7](https://www.numark.com/product/v7) is a motorized 7″ turntable
DJ controller from ~2011. Its audio and control run over a proprietary
[Ploytec](https://www.ploytec.com/) USB protocol — *not* USB-class-compliant —
so it needs a vendor driver that was last updated for **macOS 10.12 Sierra
(2016)** and is x86-only. On Apple Silicon it's a brick.

OpenV7 replaces that dead driver with a small userspace program. It talks to
the V7 directly over `libusb`, performs the Ploytec handshake, runs the audio
clock, and re-exposes the controller as a standard **CoreMIDI** device that any
app — **VirtualDJ**, Mixxx, Ableton — sees as a normal MIDI controller.

No kernel extension. No system modification. Just a program you run.

```
  Numark V7 ──(USB, Ploytec)──►  openv7  ──► CoreMIDI "Numark V7" ──► VirtualDJ
            ◄──(motor, LEDs)───          ◄──                       ◄──
```

## Status — v1

| Platform | State |
|----------|-------|
| **macOS on Apple Silicon** | ✅ supported (this release) |
| macOS on Intel | should work (untested) |
| Linux / Windows | planned |

| Capability | State |
|------------|-------|
| Control **input** (jog, buttons, faders → MIDI) | ✅ working |
| Control **output** (LEDs, **motor** → device) | ✅ working (motor spins on command) |
| **Audio** (the V7's built-in 4-out soundcard) | ⏳ not yet — use any other audio output in your DJ app |
| Reverse-direction / full per-control map | 🔬 being verified — see [docs/PROTOCOL.md](docs/PROTOCOL.md) |

> **v1 is control-only.** The V7's motor, jog, and buttons work in your DJ app;
> for sound, point the app's audio output at your Mac's built-in output or any
> other interface. Native V7 audio is [on the roadmap](docs/ROADMAP.md).

## Build

Requires the Xcode command-line tools and `libusb`:

```sh
brew install libusb
make
```

This produces the `openv7` binary.

## Run

Plug in the V7, power it on, then:

```sh
./openv7            # add -v to watch decoded MIDI
```

You should see:

```
OpenV7: device claimed.
  V7 firmware: chip 0x33
OpenV7: handshake complete, device armed.
OpenV7: CoreMIDI device "Numark V7" is live.
OpenV7: running. Select "Numark V7" in your DJ app. Ctrl-C to stop.
```

Leave it running. A CoreMIDI device named **Numark V7** now appears in
*Audio MIDI Setup ▸ MIDI Studio* and in any DAW/DJ app.

## Use with VirtualDJ

1. Start `openv7` (leave it running).
2. Open VirtualDJ. It detects the **Numark V7** MIDI device.
3. Apply the mapping in [`mappers/virtualdj/`](mappers/virtualdj/) (or map
   controls yourself with MIDI-learn).
4. Set VirtualDJ's audio output to your preferred interface (built-in output is
   fine for v1).

See [`mappers/virtualdj/README.md`](mappers/virtualdj/README.md) for details.

## How it works

The V7 exposes two vendor-specific USB interfaces. OpenV7:

1. Runs the **Ploytec handshake** (firmware `'V'`, status `'I'`, sample-rate
   `SET_CUR`, status write-back) to arm the device.
2. Streams silence on the **isochronous OUT** endpoint as the audio clock —
   the chip only reports its controls while that clock runs.
3. Reads the **control-IN** bulk endpoint, strips the `0xFD` idle filler, and
   forwards the resulting MIDI to a CoreMIDI source.
4. Frames MIDI from apps back into the **control-OUT** bulk endpoint (LEDs, motor).

Full protocol details, endpoint map, and the motor command set are in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Credits

- Protocol groundwork and the Ploytec vendor-request set were cross-referenced
  against the **[Ozzy](https://github.com/mischa85/Ozzy)** project (Marcel
  Bierling), which reverse-engineered the same Ploytec chipset for Allen &
  Heath Xone devices.
- The V7 control/MIDI map draws on the **[Mixxx](https://github.com/mixxxdj/mixxx)**
  community mapping.

## Legal

OpenV7 is an independent, clean-room interoperability driver for hardware you
own. Reverse engineering for interoperability is protected under **DMCA
§1201(f)** (US) and **Article 6 of Directive 2009/24/EC** (EU). It ships no
vendor firmware or driver binaries. Not affiliated with or endorsed by Numark /
inMusic. "Numark" and "V7" are trademarks of their respective owner, used here
only to identify the compatible hardware.

MIT licensed — see [LICENSE](LICENSE).
