# OpenV7 Tester

A visual, browser-based tester for the Numark V7 — it lights up controls as you
press them, logs raw MIDI, learns your control map, and walks you through the
hardware calibration procedure.

It talks to the V7 through the **Web MIDI API**, so it needs the OpenV7 bridge
running (which publishes the `Numark V7` MIDI device) and a Chromium browser
(Chrome/Edge/Brave — Safari and Firefox don't support Web MIDI).

## Run it

Web MIDI only works over `https://` or `http://localhost` (not `file://`), so
serve the folder locally:

```sh
cd tester
python3 -m http.server 8730
```

Then open **http://localhost:8730** in Chrome and allow MIDI access when asked.
(The OpenV7 app will grow an **Open Tester…** menu item that does this for you.)

## What you can do

- **Test** — press any control on the V7; its spot on the diagram flashes. The
  pitch fader, strip search, and platter animate.
- **Learn** — click *Learn mode*, click a control on the diagram, then press it
  on the hardware to bind its MIDI. Repeat for everything.
- **Export** — download a VirtualDJ `<map>` snippet of what you learned; the raw
  JSON is copied to your clipboard so you can update `docs/PROTOCOL.md`.
- **MIDI monitor** — every incoming message, with the idle heartbeat filtered.
- **Calibration** — the official Numark NS7/V7 procedure as a checklist. Note
  it's a *hardware* procedure done with USB unplugged; use the Tester afterward
  to confirm faders reach full travel and the strip search responds.

The diagram layout is approximate; contributions to refine positions and the
default map are welcome.
