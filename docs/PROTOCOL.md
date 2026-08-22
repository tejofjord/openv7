# Numark V7 — USB Protocol Notes

Reverse-engineered from a physical Numark V7 (USB `15E4:0075`, firmware chip
`0x33`) on Apple-Silicon macOS with no vendor driver installed. Cross-referenced
against the [Ozzy](https://github.com/mischa85/Ozzy) Ploytec notes and the
[Mixxx](https://github.com/mixxxdj/mixxx) community mapping.

Legend: ✅ verified on hardware · 🔬 documented, needs on-device confirmation.

## USB device

- ✅ `idVendor 0x15E4` (Numark), `idProduct 0x0075`, `bcdDevice 0x0100`.
- ✅ `bDeviceClass/SubClass/Protocol = 0xFF/0xFF/0xFF` — **vendor-specific**;
  no OS class driver binds. USB 2.0, self-powered (0 mA from USB; it has mains
  power), 1 configuration, 2 interfaces.
- ✅ Openable from userspace with no kext and no special entitlement.

## Endpoints (config descriptor)

| Interface / alt | Endpoint | Type | Direction | Purpose |
|---|---|---|---|---|
| IF0 alt1 | `0x02` | isochronous | OUT | audio playback (also the clock) — 156 B/packet |
| IF0 alt1 | `0x83` | bulk | IN  | control / MIDI from device |
| IF0 alt1 | `0x04` | bulk | OUT | control / MIDI to device (LEDs, motor) |
| IF1 alt1 | `0x81` | isochronous | IN  | audio return — near-empty (3 kB/s), but must be drained |
| IF1 alt1 | `0x86` | bulk | IN  | audio return / high-rate (drained) |

Both interfaces have a zero-bandwidth `alt0`; select `alt1` to stream.

> **On the "input" — the endpoint is probably vestigial.** The Windows vendor
> driver registers `KSCATEGORY_CAPTURE` and Windows enumerates a
> `Line In (Numark V7 Audio - WDM 2.9.64)` endpoint, and bulk IN `0x86` really
> does stream continuously at 2,822,685 B/s. On that basis this file briefly
> claimed the original "V7 has no inputs" note was wrong.
>
> That claim was wrong. The official *V7 Quickstart Guide v1.2* lists the rear
> panel in full — POWER IN, POWER SWITCH, USB, **DECK A / DECK B OUTPUT (RCA)**,
> MOTOR TORQUE, REMOTE (reserved), LINK CONNECTION, DECK LOCATION SWITCH
> (reserved) — and the manual contains **no mic or line input anywhere**. The
> V7 has audio outputs only.
>
> The capture endpoint exists because `v7_wdm.sys` is the generic Ploytec WDM
> driver shared across the whole OEM family (TEAC, Allen & Heath, Elektron — see
> [VENDOR-DRIVER.md](VENDOR-DRIVER.md)): it registers a capture category because
> the *chipset* supports one, not because this *product* wires one up. That fits
> every observation — the pipe streams at full rate, unmuted, at 100 % gain, and
> carries **exact zeros**, because there are no converters behind it.
>
> So `0x86` is a chipset artifact the host must drain, not an audio source. The
> original "no inputs" note was right.

> **The four output channels are Deck A + Deck B.** The manual's
> "DECK A / DECK B OUTPUT (RCA)" — two stereo pairs — matches the measured
> 4-channel iso-OUT exactly, and the capture confirms the assignment: a tone
> played to the Windows endpoint landed on channels 1–2 with 3–4 silent.

> **The control stream does not need an audio client.** With the vendor driver
> loaded and nothing playing, the V7 streams control data continuously — 9 892
> messages in 5 s of platter motion with no audio application open.

## ✅ What actually keeps the device alive (measured)

A 90-second USBPcap capture of the **stock Windows driver**, idle except for a
scripted motor burst, settles this. Over the whole capture the driver sent:

| Direction | Traffic |
|---|---|
| iso OUT `0x02` | continuous, 529 kB/s, never pauses |
| bulk OUT `0x04` | **10 packets total** — and all 10 were the 5 motor commands the script itself sent |
| EP0 control transfers | **zero** |

So, during 75 s of genuine idle the vendor driver sent **nothing at all** on
bulk `0x04` and issued **no control transfers whatsoever**. There is no idle
keepalive on the control-OUT pipe and no periodic status re-arm.

**The only thing sustaining the device is a correctly-paced isochronous OUT
stream.** That matches the driver's internals — the keepalive is armed from the
iso write-completion callback (`isocWriteCompleteKeepAlive`, see
[VENDOR-DRIVER.md](VENDOR-DRIVER.md)) — but the practical point is that
"keepalive" means *keep the iso stream correctly fed*, not *send filler on
`0x04`*.

### ⚠️ Implication for OpenV7's long-idle stall

`src/main.c` currently:

1. sends **fixed 156-byte** iso packets — 156 × 8000 = **1,248,000 B/s**, versus
   the vendor driver's **529,303 B/s**. That is a **2.36× overfeed** of an
   endpoint whose consumer runs at a fixed 44.1 kHz. The correct shape is
   packets alternating **72 / 60 bytes** (6 and 5 audio frames of 4 ch × 24-bit),
   40 packets per URB — see [AUDIO-CODEC.md](AUDIO-CODEC.md);
2. sends a `0xFD` idle frame on `0x04` every 25 ms — the vendor driver never
   does this;
3. re-reads and re-writes the `'I'` status every 2 s — the vendor driver never
   does this either.

Items 2 and 3 were added empirically to stop the control stream dying at ~24 s.
Since the real driver needs neither, the likely root cause is item 1: the device
is being fed 2.36× more audio data than it consumes, and the resulting overrun
is what silences the control stream. Worth testing by correcting the iso pacing
first and then removing the two workarounds.

This is a hypothesis about the *cause*; items 1–3 and the vendor driver's
behaviour are all measured.

## ✅ Recovery — what the driver actually does (measured)

Captured by restarting the V7's device node under USBPcap
(`tools/win/capture-init.ps1`), which makes the vendor driver tear its stack
down and rebuild it. The entire sequence is four operations inside 2 ms:

```
t+0.000   ABORT_PIPE           iso IN  0x81      (x2)
t+0.000   ABORT_PIPE           iso OUT 0x02      (x2)
t+0.000   SELECT_CONFIGURATION (SET_CONFIGURATION, bRequest 9, wLength 8)
t+0.002   completion  ->  streaming resumes
```

**No vendor requests, no re-run of the Ploytec handshake, no USB device reset,
and no port cycle.** The driver aborts the isochronous pipes, re-selects the
configuration, and starts streaming again. The bulk endpoints were never
touched.

The libusb equivalent is therefore much lighter than `libusb_reset_device()`:

1. cancel every outstanding iso transfer and wait for the cancellations,
2. re-select the configuration / alt setting,
3. resubmit the iso ring.

Note `libusb_reset_device()` is a *stronger* operation than any of this, which
fits its observed coin-flip behaviour — it invalidates the device handle and
forces re-enumeration, where the vendor driver only re-selects a configuration
it already has.

> Scope: this is the driver's **soft** recovery, the one it uses when its own
> stack restarts. `v7_usb.sys` also contains a harder path ending in
> `IOCTL_INTERNAL_USB_CYCLE_PORT` (see [VENDOR-DRIVER.md](VENDOR-DRIVER.md))
> for a genuinely wedged device; that path was not exercised by this capture,
> because nothing was actually stuck.

### Bulk read sizing, incidentally

The driver reads PCM from bulk IN `0x86` in **131,072-byte (128 KB)** transfers,
issued roughly every 46 ms — which is the 2.82 MB/s input rate. OpenV7 drains
this endpoint with much smaller reads.

## Bring-up handshake

Ploytec vendor + USB-audio control requests, in order (all ✅):

1. `0xC0 0x56 (‘V’)` wValue 0, wIndex 0, len 15 — firmware. Byte 0 = chip ID (`0x33`).
2. `0xC0 0x49 (‘I’)` wValue 0, wIndex 0, len 1 — status read (observed `0x12`).
3. `0xA2 0x81` wValue 0x0100, wIndex 0, len 3 — GET_CUR sample rate (`44100`).
4. `0x22 0x01` wValue 0x0100, wIndex = endpoint, len 3 — SET_CUR rate, 3-byte LE
   (`44 AC 00`). Sent to the streaming endpoints.
5. `0xC0 0x49` — re-read status.
6. `0x40 0x49` wValue = `(int16)(int8)(status | 0x20)`, wIndex 0 — status
   **write-back; arms the device for streaming.**

Then submit isochronous OUT packets on `0x02` (silence is fine). **The device
sends nothing on the control-IN endpoint until this clock is running.**

### What the status byte actually means

Steps 2/5/6 above are not magic. Vendor request `'I'` (`0x49`) addresses
**hardware control registers** selected by `wIndex` — `0` = AJ input selector /
digital status, `1` = mixer / CPLD config, `2` = digital output selector
(write-only). The status byte decodes as:

| Bit | Meaning |
|---|---|
| `0x01` | USB1 mode |
| `0x02` | clock source select (internal / external) |
| `0x04` | **digital signal lock** |
| `0x10` | StreamingArmed |
| `0x20` | LegacyActive — **this is the bit the confirm write-back sets** |
| `0x08`, `0x40`, `0x80` | device-dependent mode/config |

So the V7's observed `0x12` is `0x10` (StreamingArmed) + `0x02` (clock source),
and the arm step rewrites it as `0x32`. The Allen & Heath Xone DB2 — a sibling
Ploytec device — powers up with the *same* `0x12` and confirms to the same
`0x32`, so OpenV7's `(status | 0x20)` is the general Ploytec handshake rather
than a V7 quirk.

**Always read-modify-write this register, never blindly overwrite it** — most of
the bits are stateful device configuration, and the driver masks rather than
replaces. Note also that `wValue` on the write is *sign-extended from a byte*
(`(short)(char)b`), so the high byte is `0xFF` whenever bit 7 is set.

Source for the bit meanings: [Ozzy](https://github.com/mischa85/Ozzy)'s Ploytec
RE notes, which cross-confirm the Windows and macOS vendor drivers. See
[AUDIO-CODEC.md](AUDIO-CODEC.md).

Byte 2 of the firmware response (step 1) is a decimal-encoded version:
`v1.{b/10}.{b%10}` — OpenV7 currently reads only byte 0.

## Control stream framing

- ✅ Control data is **standard MIDI** wrapped in the bulk stream, padded with
  `0xFD` idle bytes. Strip `0xFD` and parse normally.
- ✅ **Inbound frame layout** (bulk IN `0x83`), captured verbatim while the
  platter was turning:

  ```
  b0 00 7e   e0 71 75   FD x35   00
  |________| |________| |_____|  |_|
   CC 0x00    pitch-bend padding  terminator
   platter    timestamp
   position
  ```

  Also **42 bytes**, one frame per USB frame (1 kHz), carrying **two MIDI
  messages per frame** — the platter position and its paired timestamp. The
  terminator is `0x00` inbound, versus `0xE0` outbound.

  Successive frames stepped `7E → 00 → 02 → 04 → 06 → 08`, i.e. +2 counts per
  millisecond, which matches the 2.095 counts/sample measured independently
  through the MIDI port at 33⅓ RPM.
- ✅ **Input** example: platter motion → `B0 00 vv` (deck A, CC `0x00`) /
  `B0 02 vv` (deck B, CC `0x02`), a wrapping 7-bit position counter, paired
  1:1 with a `0xE0` pitch-bend timestamp for velocity.
- ✅ **There is no heartbeat.** `B0 7D` / `B0 6E` were previously recorded here
  as idle chatter. They are **state reports**: `B0 7D` carries the deck-select
  position (`00` = A, `01` = B) and fires the instant the switch moves, with
  `B0 6E` observed arriving paired with it.

  Tested directly — **10 minutes of untouched idle produced exactly zero
  messages**, and a 45-second USB-level capture shows zero packets on bulk IN
  `0x83`. The device says nothing at all unless a control moves or the host
  asks. Any liveness check built on expecting periodic input from the V7 will
  wait forever.

  That does not mean the earlier macOS observation was imagined — OpenV7 does
  two things the vendor driver never does (a 25 ms `0xFD` frame on `0x04` and a
  2 s EP0 status re-arm), and the "heartbeat" is most likely a *response* to
  those rather than something the device emits on its own. Worth re-checking on
  the Mac once the iso pacing is corrected and those workarounds are removed.

### Platter reporting — measured

- ✅ **3600 counts per revolution.** With pitch trim explicitly zeroed the
  platter runs at 2000.3 counts/sec at the 33⅓ setting; 2000 / (33⅓ / 60) =
  3600.5. Beware: measuring with a stale non-zero pitch trim gives ~3767,
  because the trim scales the speed and not the encoder.
- ✅ **One message per encoder count, coalesced at the USB frame rate.** Below
  ~17 RPM the message rate tracks the count rate exactly (398 msg/s at 6.67 RPM,
  790 at 13.2); above that it saturates at ~998.7/s — one message per 1 ms USB
  frame — and each message carries a multi-count delta instead.
- ✅ **A stationary platter reports nothing at all.** Silence is the "stopped"
  signal, not a dropped stream. Any decoder that infers speed from message
  *count* rather than from counts-per-wall-clock-second will read slow speeds
  as much faster than they are.
- ✅ **`0xE0` timestamp clock = 2,822,400 Hz confirmed** (44100 × 64). Measured
  2,822,904 and 2,822,831 units/sec in two independent runs — within 0.02 %.
- ✅ **Output**: send one MIDI message per 42-byte frame on bulk `0x04`. The
  exact frame the vendor driver puts on the wire is:

  ```
  B0 43 00  FD x38  E0        <- soft-start, captured verbatim
  |_______|  |____|  |_|
   3-byte    padding  terminator
   MIDI
  ```

  i.e. **3 bytes of MIDI, 38 × `0xFD` padding, then a trailing `0xE0`**. The
  `0xE0` terminator was not previously documented here. OpenV7 currently pads
  the whole frame with `0xFD` (`src/main.c`, the `memset` before the `memcpy`),
  so its last byte is `0xFD` rather than `0xE0`. The device accepts both — the
  motor responds either way — but the vendor driver is consistent about it.

## Device identity — SysEx inquiry ✅

The V7 answers the **MIDI Universal Non-Realtime Device Inquiry** with a
vendor-format reply. This is the only way to get a unique identifier out of the
unit: its USB descriptor reports `NO_SERIAL_NUMBER`.

```
host   F0 7E <dev> 06 01 F7            # <dev> = 00, 01 or 7F, all work
device F0 00 01 3F 7F 75 07 00 02 04 01 00 02 08
       30 4E 31 31 30 30 31 31 38 38 31 30 33 34 32 38 F7
```

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | `F0` | SysEx start |
| 1–3 | `00 01 3F` | 3-byte extended manufacturer ID |
| 4 | `7F` | device ID (echoed as broadcast regardless of what was sent) |
| 5 | `75` | product — matches USB PID `0x0075` |
| 6–13 | `07 00 02 04 01 00 02 08` | header / version field, not yet decoded |
| 14–29 | ASCII | **serial number**, here `0N11001188103428` |
| 30 | `F7` | SysEx end |

The reply is byte-identical for `<dev>` = `00`, `01` and `7F`. Note the reply is
**not** in the standard `F0 7E .. 06 02 ..` identity-reply format — it is a
vendor frame, so a generic MIDI identity parser will not recognise it.

> ⚠️ **Do not fuzz the vendor SysEx space.** `v7_usb.sys` exports
> `writeUC3UserFlash` and has a firmware-updater path (see
> [VENDOR-DRIVER.md](VENDOR-DRIVER.md)), so blind-sweeping commands under
> manufacturer `00 01 3F` risks writing MCU flash or entering a bootloader on
> hardware that is discontinued and unreplaceable. Map this space from a
> **capture of the vendor driver** doing it, not by guessing.

A CC and note-on sweep of the entire `0x00`–`0x7F` range produced **no** device
replies, so there is no simple CC-based query channel — the inquiry above is
the only request/response path found so far.

## Motor command set (host → device, on bulk `0x04`)

Status byte `0xB0`, deck A shown. **All ✅ — measured on hardware** by using the
platter's own position counter as a tachometer (see
[tools/win/motor-probe.ps1](../tools/win/motor-probe.ps1)).

| Function | Message | Measured behaviour |
|---|---|---|
| Instant start | `B0 41 00` | ✅ reaches speed in ~700 ms |
| Instant stop | `B0 42 00` | ✅ stops immediately |
| Soft-start (ramp) | `B0 43 00` | ✅ ramps up, duration set by `0x47` |
| Brake (ramp stop) | `B0 44 00` | ✅ ramps down, duration set by `0x48` |
| RPM select | `B0 45 vv` | ✅ `00` → **33.29 RPM**, `01` → **45.00 RPM** |
| Direction | `B0 46 vv` | ✅ `00` fwd, `01` **reverse** (−33.38 RPM) |
| Start / brake ramp time | `B0 47 vv` / `B0 48 vv` | ✅ higher = slower: `00` → 0.7 s, `20` → 2.7 s, `40` → 4.5 s |
| Pitch trim | `B0 49 msb` + `B0 69 lsb` | ✅ signed 14-bit, see below |

### Direction — the reverse gotcha (previously an open item)

`B0 46 01` **does** reverse the platter, at full speed. The earlier failure was
one of sequencing, not of the command: the direction latch is only sampled when
the motor starts. It must be issued **while the platter is stopped**:

```
B0 42 00      # instant stop  (must actually be stopped)
B0 46 01      # latch reverse
B0 43 00      # soft start -> runs backwards
```

Setting `0x46` on an already-spinning platter does nothing, which is why a
brake-then-soft-start sequence appeared to ignore it.

### Pitch trim — `B0 49` / `B0 69`

A **signed 14-bit two's-complement** value split MSB/LSB across the standard
MIDI pair (`0x69` = `0x49` + 32):

```
v14 = (msb << 7) | lsb          # 0 .. 16383
s   = v14 < 8192 ? v14 : v14 - 16384
speed = nominal_rpm * (1 + s / 10000)
```

Confirmed across `s` = −8000 … +7000 against a 33⅓ nominal, worst-case error
0.32 RPM and typically under 0.1:

| `s` | predicted RPM | measured RPM |
|---|---|---|
| −8000 | 6.67 | 6.67 |
| −4000 | 20.01 | 19.92 |
| 0 | 33.34 | 33.34 |
| +4000 | 46.67 | 46.67 |
| +5190 | 50.64 | 50.58 |

So one unit = 0.01 % of nominal speed, and the community note that Serato maps
rate ±0.519 → ±5190 is exactly right: ±51.9 %.

Negative trim slows the platter but does **not** reverse it — it bottoms out at
a stop. Reverse is `0x46`.

## Audio codec (not yet implemented)

The V7's audio is a Ploytec **bit-interleaved** format (channels spread across
the packet at the bit level), 24-bit / 44.1 kHz. The iso-OUT packet is 156 bytes.
Decoding/encoding this is the main remaining work for native audio support.

**See [AUDIO-CODEC.md](AUDIO-CODEC.md)** for the codec structure, the packet
framing (including why the `0xFD` control padding is really the MIDI slots of
the audio packet layout), and what still has to be measured on a V7.

Note the "no inputs" claim in earlier revisions of this file was wrong — the
vendor driver exposes a capture endpoint. Channel count for the V7 specifically
is not established; the Ploytec codec core is 8-channel.
