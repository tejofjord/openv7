# VirtualDJ mapping for the Numark V7 (via OpenV7)

With `openv7` running, VirtualDJ sees a MIDI device called **Numark V7**. There
are two ways to map it.

## Option A — MIDI-learn (works today, no files)

The most reliable path while the full control map is still being verified:

1. Run `./openv7` and open VirtualDJ.
2. Go to **Settings ▸ Controllers**. Select **Numark V7**.
3. Click **+** / **Edit mapping**, then **Learn**: touch a control on the V7,
   pick the VirtualDJ action to bind, repeat for each control.
4. VirtualDJ saves your mapping automatically.

Tip: run `./openv7 --learn`, touch every control once, and press Ctrl-C for a
catalog of each control's MIDI message — the fastest way to confirm what to map.

## Option B — definition file

[`Numark_V7.xml`](Numark_V7.xml) now carries the full control map rather than
`TODO` placeholders. Two confidence levels apply, and the file marks which is
which:

- the platter and the entire motor command set are **measured on hardware**;
- the buttons, pads, faders and LEDs are **cross-referenced** from the
  community Mixxx mapping and corroborated wherever they overlap with the
  measured set, but are not yet confirmed on a physical unit.

See [../../docs/CONTROL-MAP.md](../../docs/CONTROL-MAP.md) for the full address
table and how to verify the unconfirmed rows.

Install it by copying to VirtualDJ's device folder:

```sh
# macOS -- verified on VirtualDJ 2025, Apple Silicon
cp "Numark_V7.xml" ~/Library/Application\ Support/VirtualDJ/Devices/

# Windows
copy Numark_V7.xml "%USERPROFILE%\Documents\VirtualDJ\Devices\"
```

Then restart VirtualDJ and select **Numark V7** under Controllers.

> Earlier revisions of this file gave `~/Documents/VirtualDJ/Devices/` for
> macOS. That path does not exist there, so the copy silently went nowhere and
> the mapping was never actually loaded.

## ⚠️ VirtualDJ ships its own V7 definition, and it wins

VirtualDJ recognises this deck natively — `settings.xml` records
`Controller: V7` — from definitions packed into
`Devices/controllers.dat`. That file is **byte-identical on macOS and Windows**
(`sha256 2c9e2dec…`, compared directly), so both platforms carry the same
built-in V7 definition, and it takes precedence over anything here.

Two consequences worth knowing before debugging a mapping:

- The built-in definition **consumes `0xE0`**. Suppressing the pitch-bend on the
  bridge kills the jog outright even though `0xB0 0x00` keeps streaming — while
  this file does not map `0xE0` at all. If both were in force that could not be
  true, which is how we know the built-in one is running.
- On Windows it **commands the motor**, sending `b0 41 7f` on play and
  `b0 42 7f` on stop (captured from a working system —
  `captures/vdj/vdj-outbound-0x04.tsv`). On macOS it has never been observed
  sending `B0 41`/`0x42`/`0x43` in any capture, though it does drive the LEDs.
  Same definition, different behaviour, so the gap is in how VirtualDJ binds our
  CoreMIDI source rather than in what it knows about the deck.

> ⚠️ The button/pad/LED rows are cross-referenced, not yet confirmed on a
> physical unit. If a control misbehaves, please contribute the corrected value
> back — run `openv7 --learn` (or `tools/win/midi-learn.ps1` on Windows), note
> each control's message, and open a PR updating this file and
> `docs/CONTROL-MAP.md`.

## Motor / LED output

VirtualDJ can drive the motor and lights by sending MIDI back to the **Numark
V7** destination. Output mappings (platter motor follow, VU meters, pad LEDs)
use the same MIDI messages documented in `docs/PROTOCOL.md` — e.g. `B0 43 00`
(motor start), `B0 45 01` (45 RPM). These are the next mapping to flesh out.
