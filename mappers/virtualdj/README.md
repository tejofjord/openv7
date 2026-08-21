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

## Option B — starter definition file

[`Numark_V7.xml`](Numark_V7.xml) is a **starter** definition. It maps the parts
verified on hardware (the motorized platters) and leaves the rest as clearly
marked `TODO` entries to fill in with MIDI-learn or once the full map is
confirmed (see [../../docs/PROTOCOL.md](../../docs/PROTOCOL.md)).

Install it by copying to VirtualDJ's device folder:

```sh
cp "Numark_V7.xml" ~/Documents/VirtualDJ/Devices/
```

Then restart VirtualDJ and select **Numark V7** under Controllers.

> ⚠️ This file is a work in progress. The jog/platter and motor lines are based
> on captured traffic; the button/pad note numbers are placeholders. Please
> contribute confirmed values back — run `openv7 --learn`, note each control's
> message, and open a PR updating both this file and `docs/PROTOCOL.md`.

## Motor / LED output

VirtualDJ can drive the motor and lights by sending MIDI back to the **Numark
V7** destination. Output mappings (platter motor follow, VU meters, pad LEDs)
use the same MIDI messages documented in `docs/PROTOCOL.md` — e.g. `B0 43 00`
(motor start), `B0 45 01` (45 RPM). These are the next mapping to flesh out.
