# OpenV7 — Windows USB-capture task (paste this into an AI assistant on the Windows PC)

You are helping me reverse-engineer the USB protocol of a **Numark V7** DJ controller. I'm
building an open-source userspace driver ("OpenV7") that revives this discontinued controller
on modern macOS. The Mac side already works, but has **two unsolved problems** that a capture
of the **original Windows vendor driver** will answer. Your job: help me install the vendor
driver on this Windows PC, capture its USB traffic during specific scenarios with
Wireshark + USBPcap, and optionally do a first-pass analysis.

## What the device is
- **Numark V7**, a Ploytec-based USB device. **VID `0x15E4`, PID `0x0075`**, Ploytec chip `0x33`.
  USB class `FF/FF/FF` (vendor-specific — NOT class-compliant; nothing enumerates as audio/MIDI
  without the vendor driver).
- Single-deck motorized DJ controller: motorized platter, pitch fader, SYNC/CUE/PLAY transport,
  hot-cue pads 1–5, loop + FX, browse encoder, strip search.
- Original Windows driver: **Ploytec / "Numark USB Audio" driver, ~v2.9** (x64).

## Why we're capturing (the two things I can't crack by trial-and-error)
1. **Control-stream watchdog.** The V7 stops reporting its controls (on **bulk IN `0x83`**) unless
   the host keeps feeding the **control-OUT pipe (bulk `0x04`)**. I found that sending idle
   `0xFD`-filled frames on `0x04` every ~25 ms keeps it alive through *short* pauses, **but it
   still stalls over a long idle**, and I don't know the exact keepalive the real driver uses.
2. **No software recovery.** Once stalled, only a physical power cycle reliably brings it back
   (a `libusb_reset_device` is a coin-flip). The real driver surely re-inits a stuck device
   cleanly — I need to see the exact sequence.

**A capture of the Windows driver sitting IDLE, and during an UNPLUG/REPLUG, answers both.**

## Known protocol (to sanity-check the capture against)
- Endpoints: **iso OUT `0x02`** (audio playback clock, 156-byte packets) · **bulk IN `0x83`**
  (control/MIDI from device) · **bulk OUT `0x04`** (control/MIDI to device — LEDs, motor) ·
  **iso IN `0x81`** (audio return, 64-byte) · **bulk IN `0x86`** (audio return).
- Init handshake (EP0 control transfers): firmware read `bmRequestType 0xC0 bRequest 0x56` (15 B →
  chip `0x33`); status read `0xC0 0x49` (1 B); GET rate `0xA2 0x81 wValue 0x0100`; SET rate
  `0x22 0x01 wValue 0x0100` (3-byte LE 44100) to several endpoint wIndex values; arm =
  status write `0x40 0x49 wValue=(status|0x20)`.
- Control MIDI on `0x83`: CC `0x00` = deck-A platter position, `0x02` = deck-B; `0xE0` = pitch-bend
  (platter timestamp / pitch fader); `0xFD` = idle filler byte.
- Motor commands on `0x04` (3 bytes `B0 cc vv`, padded with `0xFD` to a 42-byte frame): `0x41`
  instant-start · `0x42` instant-stop · `0x43` soft-start · `0x44` brake · `0x45` RPM (00=33, 01=45)
  · `0x46` direction.

## Task

### 1. Install the vendor driver
- Get it from **Serato support** ("Numark Hardware Drivers and Firmware") or the downloads on
  **numark.com/product/v7**. It's the **Numark/Ploytec USB Audio driver ~v2.9** (x64).
  Avoid random driver-aggregator sites (adware).
- If Win 11 blocks it for signature: reboot → **Advanced Startup → Troubleshoot → Advanced options
  → Startup Settings → Restart → press `7`** (Disable driver signature enforcement), then install.
- Plug in the V7; confirm it appears (Device Manager → Sound/Audio, or it works in Serato DJ /
  VirtualDJ).

### 2. Install capture tools
- Install **Wireshark**; during setup **check the box to also install USBPcap**. Reboot.

### 3. Capture (the important part)
Open Wireshark → pick the **USBPcap** interface the V7 is on (capture all USBPcap interfaces if
unsure) → Start. Then do these, in one session, jotting rough timestamps:
1. **Unplug and replug the V7** — captures the full init/handshake.
2. **~60 seconds doing NOTHING**, hands off — reveals the idle keepalive (the #1 unknown).
3. **Spin the platter ~10 s.**
3b. **Play audio to the V7 for ~10 s** — set `Speakers (Numark V7 Audio - WDM)`
   as the output device and play music. **This is now a high-priority scenario:**
   it decides which endpoint actually carries PCM. See the hypothesis in
   `docs/AUDIO-CODEC.md` that iso-OUT `0x02` is only a keepalive pipe and the
   real audio rides on bulk `0x04` / `0x86`.
4. **Stop the platter, wait 30–60 s untouched, then spin again** — does it keep reporting? What
   did the driver send during the wait?
5. **Press each button / pad / move each fader once** — full control map + any LED feedback the
   driver sends back.
6. If you can make it go silent/stall, **capture whatever brings it back** (in the DJ software,
   or an unplug/replug).
Stop → **File → Save As → `v7_vendor_capture.pcapng`**.

### 4. What to look for (start analyzing if you can)
- **During idle:** what does the driver send, on which endpoint (especially **bulk OUT `0x04`**),
  and how often (period in ms)? Is there periodic OUT traffic we're missing?
- **Init on plug-in:** the exact control-transfer sequence (anything beyond the list above).
- **Recovery:** the exact sequence when a stalled/re-init happens.
- **LED / 7-segment / display command bytes** on `0x04` when controls are pressed.
Wireshark display filter: `usb.idVendor == 0x15e4 && usb.idProduct == 0x0075` (or filter by the
device's bus/address once you spot it).

### 5. Send it back to the Mac
Save the `.pcapng` (plus any notes) and get it to my Mac (cloud drive / USB stick / email). It
goes in **`/Users/michaelhadida/dev/numarkv7/captures/`**, where I'll diff it against the OpenV7
bridge to fix the keepalive and add auto-recovery.

---
*Project repo (macOS): `/Users/michaelhadida/dev/numarkv7` — bridge is `src/main.c` (libusb →
CoreMIDI). Current status: streams control + drives motor when healthy; deep iso-OUT buffer +
0x04 idle keepalive added; long-idle stall + software recovery still open — that's what this
capture is for.*
