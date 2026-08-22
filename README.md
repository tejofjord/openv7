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
| **Audio** (the V7's built-in soundcard) | ⏳ not implemented — but the wire format is now known, see below |
| **Motor** command set (start/stop/brake/RPM/**reverse**/ramp/pitch-trim) | ✅ measured on hardware — [docs/PROTOCOL.md](docs/PROTOCOL.md) |
| Full per-control map (buttons, pads, faders, LEDs) | ✅ mapped, 🔬 hardware confirmation pending — [docs/CONTROL-MAP.md](docs/CONTROL-MAP.md) |

### Protocol coverage

The USB protocol is fully documented. Every area is either measured on this
hardware (✅) or mapped from a corroborating source and flagged as unconfirmed
(🔬):

| Area | |
|---|---|
| Endpoints, roles and exact data rates | ✅ measured to 0.02 % |
| Init handshake, incl. what the status bits mean | ✅ measured & decoded |
| Device identity + serial (SysEx inquiry) | ✅ measured |
| Control frame format, both directions | ✅ measured |
| Platter encoder (3600 counts/rev) and timestamp clock | ✅ measured |
| Motor command set (all 9, incl. reverse and pitch-trim law) | ✅ measured |
| Idle keepalive behaviour | ✅ measured — **there is none** |
| Recovery sequence | ✅ measured — abort pipes + `SET_CONFIGURATION` |
| Audio **output** encoding | ✅ decoded — plain 24-bit LE, **no codec needed** |
| Audio **input** frame layout | 🔬 mapped (bit-scatter, 1 bit/byte) |
| 89 control inputs / ~60 LED outputs | 🔬 mapped |

> **v1 is control-only.** The V7's motor, jog, and buttons work in your DJ app;
> for sound, point the app's audio output at your Mac's built-in output or any
> other interface. Native V7 audio is [on the roadmap](docs/ROADMAP.md).

## Install — the easy way (no Terminal)

1. Download **OpenV7.dmg** from the [Releases](../../releases) page.
2. Open it and drag **OpenV7** into **Applications**.
3. Double-click **OpenV7**. First launch only: right-click it ▸ **Open** ▸ **Open**
   (the build isn't notarized, so Gatekeeper asks once).
4. A **◉ V7** icon appears in the menu bar. Plug in the V7 — it shows *connected*.
5. Optional: menu ▸ **Open at Login** to start it automatically every boot.

No Homebrew, no Terminal, no kernel driver. `libusb` is bundled inside the app.
Now open your DJ app and pick **Numark V7** as a MIDI controller.

The menu-bar app runs the bridge in the background, shows connection status,
reconnects automatically on replug, and quits cleanly from its menu.

**Menu ▸ Open Tester…** (⌘T) opens a native window with a diagram of the V7:
press any control and it lights up, use **Learn mode** to map controls (then
**Export map** to the clipboard), drive the **motor** with the output-test
buttons, watch the raw MIDI log, and follow the **Calibration** walkthrough.

---

## Install — for technical users (Terminal)

Prefer the command line, or want to build from source so you don't have to trust
a prebuilt binary? Everything builds with `make`. The only build-time dependency
is `libusb`.

```sh
git clone https://github.com/tejofjord/openv7
cd openv7
brew install libusb

make                 # -> ./openv7   (the CLI bridge)
sudo make install    # optional: install openv7 to /usr/local/bin
make app             # optional: build build/OpenV7.app + OpenV7.dmg yourself
```

Run it (plug in and power on the V7 first):

```sh
openv7               # -v prints decoded MIDI, --learn maps controls
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

## Map your controls (`--learn`)

To discover exactly which MIDI message each control sends, run:

```sh
./openv7 --learn
```

Touch every control once — each new one prints as it's seen — then press
`Ctrl-C` for a catalog with value ranges. Use it to fill in the VirtualDJ
mapping and `docs/PROTOCOL.md`.

## Auto-start (optional)

To keep the bridge running automatically (and restart it on replug), install
the LaunchAgent:

```sh
make install
cp dist/launchd/com.openv7.bridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.openv7.bridge.plist
```

See the plist header for uninstall steps.

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

### Documentation

| Doc | Covers |
|---|---|
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | USB identity, endpoints, init handshake, platter reporting, the full motor command set, SysEx device identity |
| [docs/CONTROL-MAP.md](docs/CONTROL-MAP.md) | Every control in and every LED/motor command out, with per-row confidence |
| [docs/AUDIO-CODEC.md](docs/AUDIO-CODEC.md) | The Ploytec bit-interleaved format, packet framing, and why MIDI lives inside the audio packets |
| [docs/VENDOR-DRIVER.md](docs/VENDOR-DRIVER.md) | Static analysis of the stock Windows driver — the keepalive and recovery mechanisms |
| [docs/ROADMAP.md](docs/ROADMAP.md) | What is left |

`tools/win/` holds the Windows reverse-engineering harness used to measure the
motor set (see [docs/CONTROL-MAP.md](docs/CONTROL-MAP.md) for how to run it).

## Credits

- Protocol groundwork and the Ploytec vendor-request set were cross-referenced
  against the **[Ozzy](https://github.com/mischa85/Ozzy)** project (Marcel
  Bierling), which reverse-engineered the same Ploytec chipset for Allen &
  Heath Xone devices.
- The V7 control/MIDI map draws on the **[Mixxx](https://github.com/mixxxdj/mixxx)**
  community mapping.

## Trust & verification

OpenV7 is fully open source — read every line, and build it yourself so you
never have to trust a binary you didn't compile.

- **Build from source** (highest trust): `make` for the CLI, or `make app` for
  the GUI. The only external dependency is `libusb`, and the release app statically
  bundles it — no network calls, no phone-home, no background updater.
- **Verify a download**: each release ships a `SHA256SUMS.txt`. In the folder
  with the downloaded DMG:

  ```sh
  shasum -a 256 -c SHA256SUMS.txt
  ```

- **Code signing**: the released app is **ad-hoc signed but not Apple-notarized**
  (notarization requires a paid Apple Developer ID). Gatekeeper therefore prompts
  once on first launch — right-click ▸ **Open** ▸ **Open**. Building from source
  sidesteps this entirely.

## Legal

OpenV7 is an independent, clean-room interoperability driver for hardware you
own. Reverse engineering for interoperability is protected under **DMCA
§1201(f)** (US) and **Article 6 of Directive 2009/24/EC** (EU). It ships no
vendor firmware or driver binaries. Not affiliated with or endorsed by Numark /
inMusic. "Numark" and "V7" are trademarks of their respective owner, used here
only to identify the compatible hardware.

MIT licensed — see [LICENSE](LICENSE).
