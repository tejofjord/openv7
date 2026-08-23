# Handoff — picking this up on the Mac

Written at the end of a Windows reverse-engineering session against the stock
Numark/Ploytec vendor driver (v2.9.64) with a physical V7 attached. The USB
protocol is now mapped end to end. **No code in `src/` was changed** — every
finding is written down instead, because the bridge can only be tested on the
Mac where the hardware is not bound to the Windows driver.

Read [PROTOCOL.md](PROTOCOL.md) and [CONTROL-MAP.md](CONTROL-MAP.md) for the
full detail. This file is the short version plus what to do next.

---

## 0. ✅ FIXED — unplug/replug, and the four ways bring-up failed silently

**Reported as:** "sometimes the tester does not handshake properly on startup"
and "no GUI updates as the platter spins and buttons are pressed". Both were the
same fault wearing two hats, and it is now fixed and verified on hardware.

**What actually happened.** `arm_bulk()` retried *every* submit failure forever,
including `LIBUSB_ERROR_NO_DEVICE`. That error is not transient — it means the
handle names an enumeration that no longer exists — so unplugging the V7 wedged
the bridge instead of ending it. Caught live on this machine after an 11-hour
unplug:

```text
OpenV7: handshake complete, device armed.        <- clean bring-up
OpenV7: control-IN submit failed (LIBUSB_ERROR_PIPE) — retrying      x4
OpenV7: control-IN submit failed (LIBUSB_ERROR_NO_DEVICE) — retrying x37,946
```

37,946 retry lines, 2.7 MB of log, 5m36s of CPU — and the process still
"running". Because the app only relaunches the bridge when the **process**
exits, that wedged bridge was never replaced, so on replug the device was never
re-opened and never re-handshaked. Meanwhile the menu bar stayed green
(`_task.isRunning`) and the tester said "connected" (an endpoint named
`Numark V7` was still published), with `rxCount` frozen. Every health signal was
a proxy; none of them asked whether data was moving.

**Four independent defects, all of which present as "it didn't handshake".**

| # | Defect | Why it was invisible |
|---|---|---|
| 1 | `NO_DEVICE` retried forever in `arm_bulk()` | process stays alive, so the supervisor never restarts it |
| 2 | iso resubmits discarded their return value | a failed submit drops that transfer from the ring with no callback to notice; drain all 16 and the 44.1 kHz clock stops, silencing the control surface while the bulk pipes still look armed |
| 3 | `ploytec_handshake()` returned 0 unconditionally | six of seven requests had their result discarded, and a failed final status read armed from a fabricated `st = 0` |
| 4 | `libusb_claim_interface()` result discarded | printed "device claimed." even on `ERROR_BUSY`/`ERROR_ACCESS` |

Defect 2 is notable: it is the *exact* bug that was found and fixed on the bulk
pipes, and the iso ring never got the same treatment. Both rings now share the
same shape — a live flag, a checked submit, and a main-loop watchdog that
re-arms anything not in flight.

**Two supporting races, both observed:**

- `stopBridge` called `[NSTask terminate]` and cleared `_task` immediately, but
  terminate only *delivers* the signal. The old bridge was still inside its
  ~600 ms graceful teardown while `restart:` launched the replacement into that
  window, where it lost the interface claim. It now waits for the exit
  (2 s cap, then SIGKILL).
- Force-quitting or crashing the app orphaned the bridge, which kept both USB
  interfaces claimed; every later launch was then refused with
  `LIBUSB_ERROR_ACCESS`. Reproduced here — five consecutive launches refused
  3 s apart until the orphan died. macOS has no `PDEATHSIG`, so the bridge takes
  `--supervised` (passed by the app) and exits when `getppid()` changes.

**Hardware verification — re-run this after touching any of it.**

1. `open build/OpenV7.app`, then `cat /tmp/openv7_bridge.log` — expect a clean
   `device claimed` / `chip 0x33` / `device armed`.
2. Power the V7 **off**. Within ~2 s `pgrep -f openv7-bridge` must return
   nothing: the bridge has to *exit*, not spin. Anything else is defect 1 back.
3. Power it **on**. Within ~8 s a new bridge appears with a full fresh
   handshake. Measured here: off at t=12 s, on at t=18 s, armed at t=20 s.
4. Spin the platter and watch `rxCount` climb in `/tmp/openv7_gui.log`.
   Measured: 3,091 → 13,824 over 40 s of handling.
5. `./openv7 --diag` should hold `iso-out/s=200 iso-in/s=62 in-armed=4/4
   iso-armed=32/32`. **`iso-armed` is new** and is the counter that would have
   made defect 2 visible — if it drifts below 32/32, the ring is draining.

The bridge log is now **appended** rather than truncated per launch, and each
launch is stamped, because the automatic relaunch used to erase the record of
why the previous one died. One generation is rolled at 1 MB. That change paid
for itself immediately: it is what exposed the orphan/`ERROR_ACCESS` race above.

---

## 1. ✅ DONE — isochronous pacing fixed and measured on hardware

> **Status: implemented in `src/main.c` (`iso_pace()`) and verified on the real
> V7.** 75 s continuous run, both workarounds disabled: iso-OUT held **200/s**
> and iso-IN **62/s**, dead steady, no stall, clean shutdown. The rate on the
> wire is now 44,100 frames/s exactly (529,200 B/s) against the vendor driver's
> measured 529,303 B/s.
>
> Two refinements to what was written below, both measured:
> - The alternation is **not strict**. A perfect 6/5 averages 5.5 frames =
>   44,000 Hz, 0.23 % slow, and gives 528,000 B/s — 10× further from the capture
>   than the accumulator, which lands on 529,200. The fractional remainder is
>   carried instead; the URB is therefore sometimes 2652 B, not always 2640.
> - `~400 URBs/s` in AUDIO-CODEC.md was wrong and self-contradictory
>   (400 × 2640 = 1,056,000 B/s ≠ 529,303). It is **200 URBs/s**. Corrected there.
>
> ⚠️ **REVERSED — the keepalives are back ON by default.** The 75 s and 120 s
> runs below did survive a long idle with both off, but that was over-concluded
> from a handful of runs: every one of them touched the deck within ~10 s of
> arming, so none actually exercised a long cold idle before the first input. In
> use the control stream then intermittently delivered **nothing at all** from
> launch — zero bytes even to an independent CoreMIDI listener, while the bridge
> logged a clean handshake. A 45 s-idle A/B failed to reproduce it in either
> direction (no-keepalive 10,574 msgs, keepalive 20,193 msgs), so **the trigger
> is still unknown** and restoring them is defensive, not a proven fix. Disable
> with `--no-keepalive` only for A/B work, and only with a test that idles well
> past 24 s before first input and repeats enough to catch an intermittent fault.
>
> The pacing fix itself is unaffected and still correct — it matches the vendor
> driver's measured byte rate, which is true independently of this.
>
> **Still needs a human hand on the hardware:** the 75 s run proves the *iso*
> stream survives, but the V7 is silent when idle, so it cannot prove the
> *control* stream (bulk `0x83`) survives. Run `./openv7 --diag -v`, leave it
> untouched for 60 s, **then spin the platter**. Frames appearing = the overfeed
> was the root cause and both workarounds stay deleted. Nothing appearing =
> re-run with `--legacy-keepalive` and the real cause is elsewhere.
>
> Partial corroboration already in hand: `B0 7D` / `B0 6E` appeared **only once
> at startup** and never again across 75 s. That confirms the prediction below —
> the "heartbeat" was a response to the re-arm, not something the V7 volunteers.

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

> **How this was actually done:** both workarounds are **disabled by default but
> not deleted** — they are gated behind `--legacy-keepalive`. They are the
> control arm of the experiment above, so removing them outright would destroy
> the ability to A/B the very prediction this section asks for. Delete them once
> the platter test passes.

A third prediction falls out: the `B0 7D` / `B0 6E` "heartbeat" the old notes
described should **stop appearing**, because the V7 emits nothing at all when
idle (10 minutes of untouched capture: zero messages). That chatter was almost
certainly a *response* to the re-arm, not something the device volunteers.

---

## 2. Replace the recovery path

Captured from the vendor driver by restarting its device node. The entire
recovery is four operations inside 2 ms:

```text
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

```text
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
