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
cp "Numark_V7.xml" ~/Documents/VirtualDJ/Devices/
```

Then restart VirtualDJ and select **Numark V7** under Controllers.

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
