# Handoff — picking this up on the Mac

Written at the end of a Windows reverse-engineering session against the stock
Numark/Ploytec vendor driver (v2.9.64) with a physical V7 attached. The USB
protocol is now mapped end to end. **No code in `src/` was changed** — every
finding is written down instead, because the bridge can only be tested on the
Mac where the hardware is not bound to the Windows driver.

Read [PROTOCOL.md](PROTOCOL.md) and [CONTROL-MAP.md](CONTROL-MAP.md) for the
full detail. This file is the short version plus what to do next.

---

## 1. Do this first: fix the isochronous pacing

**This is the only open item that fixes a bug rather than documenting a fact,
and it is the prime suspect for the long-idle stall.**

`src/main.c` sends fixed 156-byte iso packets:

```c
#define ISO_NPKT   16
libusb_set_iso_packet_lengths(iso[i], V7_ISO_PKT_SIZE);   /* 156, every packet */
```

156 × 8000/s = **1,248,000 B/s**. The vendor driver sends **529,303 B/s** —
a **2.36× overfeed** of an endpoint whose consumer runs at a fixed 44.1 kHz.

The measured shape on the wire is:

- **40 isochronous packets per URB** (not 16)
- packet sizes **alternating 72 / 60 bytes** — never 156
- which is 6 and 5 audio frames alternately, averaging 5.5125 frames per 125 µs
  microframe = 44.1 kHz
- 12 bytes per audio frame (4 channels × 24-bit)

`wMaxPacketSize` really is 156, so the endpoint *allows* it — the driver simply
never fills it. OpenV7 has been treating the maximum as the target.

### Then delete both workarounds

The vendor driver does **neither** of these. Both were added empirically to stop
the control stream dying at ~24 s, so they look like compensation for the
overrun:

1. the 25 ms `0xFD` idle frame on bulk `0x04`
2. the 2 s EP0 `'I'`-status re-arm

**Prediction to test:** with the pacing corrected, the device survives a long
idle with both removed. If it does, the root cause is confirmed and two hacks
delete themselves. If it does not, the pacing is still correct — it now matches
the vendor driver — and the real cause is elsewhere.

A third prediction falls out: the `B0 7D` / `B0 6E` "heartbeat" the old notes
described should **stop appearing**, because the V7 emits nothing at all when
idle (10 minutes of untouched capture: zero messages). That chatter was almost
certainly a *response* to the re-arm, not something the device volunteers.

---

## 2. Replace the recovery path

Captured from the vendor driver by restarting its device node. The entire
recovery is four operations inside 2 ms:

```
ABORT_PIPE            iso IN  0x81   (x2)
ABORT_PIPE            iso OUT 0x02   (x2)
SELECT_CONFIGURATION  (SET_CONFIGURATION, bRequest 9, wLength 8)
-> streaming resumes
```

No vendor requests, no handshake replay, no device reset, no port cycle, and
the bulk endpoints are never touched.

libusb equivalent, which is far lighter than what OpenV7 does now:

1. cancel every outstanding iso transfer and wait for the cancellations
2. re-select the configuration / alt setting
3. resubmit the iso ring

`libusb_reset_device()` is strictly *stronger* — it invalidates the handle and
forces re-enumeration — which fits its observed coin-flip behaviour.

---

## 3. Native audio is far cheaper than the roadmap assumed

**There is no codec to write for output.** Captured with a known 441 Hz sine
played into the device:

```
1139cc 1139cc 000000 000000 | 88f6c9 88f6c9 000000 000000
  ch1    ch2    ch3    ch4  |   ch1    ch2    ch3    ch4
```

Plain interleaved **24-bit signed little-endian, 4 channels, 12 bytes per
frame**. The trough bottoms at `0xC00000` = −4,194,304 = exactly −0.5 × 2²³,
the amplitude requested — bit-exact, no transformation on the wire. Channels
1–2 are deck A, 3–4 deck B (matching the manual's "DECK A / DECK B OUTPUT").

The Ploytec bit-sliced format ROADMAP called "the main remaining work" belongs
to the Xone family's *bulk* PCM path, not the V7's isochronous output.

**Input: the V7 has none.** The manual's rear-panel list has outputs only. Bulk
IN `0x86` streams continuously at 2,822,685 B/s and carries **exact zeros**,
unmuted, at 100 % gain — it is a chipset artifact of the shared Ploytec WDM
driver, which registers a capture category the chipset supports and this product
never wired up. Treat `0x86` as a pipe to drain, not an audio source.

---

## 4. Traps that will cost you an afternoon

Each of these is measured, and each presents as "my code is broken":

- **Output must follow the A/B switch.** The device *silently ignores* the
  non-selected deck's block — no error, no stall, just no effect. With the
  switch on B, `B0 43 00` produced zero messages and no motion while `B0 4D 00`
  span the platter immediately. Track `B0 7D` (`00` = A, `01` = B) and address
  motor/LED commands to the live block.
- **Button releases are note-on with velocity 0**, never note-off `0x80`. Code
  watching for `0x80` misses every release.
- **Input and output CC numbers overlap without sharing meaning.** Input `0x45`
  is strip search; output `0x45` is motor RPM select. The map is not symmetric.
- **The device is silent when idle.** Any liveness check that waits for periodic
  input will wait forever.
- **Reverse needs latching while stopped:** `B0 42` (stop) → `B0 46 01` →
  `B0 43` (start). Setting direction on a spinning platter does nothing — this
  is why "reverse doesn't work" was in the docs for so long.
- **LEDs are binary.** `0x00` off, any non-zero fully on. No dimming.
- **SHIFT is not a firmware layer.** Holding it changes no addresses; the host
  must implement the shift layer itself.
- **Encoders are relative**, sending `0x01` / `0x7F` for direction — not
  absolute positions. Applies to browse (`B0 44`) and FX select (`B0 5A`/`5B`).

---

## 5. State of the map

| Area | State |
|---|---|
| Control inputs | **88 / 89** measured; the 89th (`90 7D`) is a phantom from the NS7 |
| Motor commands | **all, both decks** — including two (`0x41`/`0x42`) in no published mapping |
| LEDs | 44 located on the panel, behaviour known (binary) |
| Rear-panel switches | `90 55` DECK LOCATION, `90 58` MOTOR TORQUE — **found here, in no published mapping** |
| Platter encoder | 3600 counts/rev, one message per count, capped at the 1 kHz frame rate, silent when stopped |
| Timestamp clock | 2,822,400 Hz, verified to 0.02 % |
| Init handshake | measured, and the status bits decoded |
| Device identity | SysEx inquiry returns PID + 16-char serial (USB says `NO_SERIAL_NUMBER`) |
| Keepalive | **there is none** |
| Recovery | abort pipes + `SET_CONFIGURATION` |
| Audio output | decoded, plain 24-bit LE |
| Audio input | closed — the device has none |

---

## 6. If you go back to the Windows box

Unverified, none of it blocking. Tools are in `tools/win/`, all PowerShell:

| Item | How |
|---|---|
| Strip-search release behaviour | `strip-probe.ps1` — does lifting a finger send anything? |
| `0x09`/`0x0A`/`0x0B` → crates / prepare / files | `midi-observe.ps1 -Ordered` |
| `0x08`'s panel label | same |
| Deck-B LED block (`0x1D`–`0x33`), 23 addresses | `led-cam-probe.ps1`, camera aimed at the panel |
| The two shared-location LED clusters | camera |
| Deck-B audio ch3/ch4 | needs the driver's "4 channel out mode", never enabled |
| Whether the `0xE0` frame terminator matters | **Mac only** — the Windows driver builds the frame itself |

Setup notes for that machine: USBPcap attaches as a USB class `UpperFilters`
entry and only binds when a device stack is built, so `enable-usbpcap.ps1`
restarts the root hub instead of requiring a reboot. Its control devices
disappear when the driver unloads, and restarting both hubs renumbers them, so
the capture scripts probe `\\.\USBPcapN` directly rather than trusting
`--extcap-interfaces` (which returns empty on that machine even elevated).

---

## 7. Sources

- [Ozzy](https://github.com/mischa85/Ozzy) (MIT, Marcel Bierling) — Ploytec
  chipset RE; corroborated the keepalive architecture and supplied the 64-byte
  input frame layout.
- [Mixxx](https://github.com/mixxxdj/mixxx) community V7 mapping (Mike
  Bucceroni) — control addresses. Independently corroborated the motor set
  measured here. It also contains one phantom (`90 7D`), one mislabel (`0x12` is
  DELETE, not SHIFT), and omits the rear-panel switches entirely — a published
  mapping only contains what its author chose to map.
- *Numark V7 Quickstart Guide v1.2* — authoritative on the rear panel, and the
  reason the "V7 has inputs" claim was reverted.
