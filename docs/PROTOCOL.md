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
| IF1 alt1 | `0x81` | isochronous | IN  | audio return — the V7 **does** have an input (see note) |
| IF1 alt1 | `0x86` | bulk | IN  | audio return / high-rate (drained) |

Both interfaces have a zero-bandwidth `alt0`; select `alt1` to stream.

> **Input correction.** The Windows vendor driver registers `KSCATEGORY_CAPTURE`
> and Windows enumerates a `Line In (Numark V7 Audio - WDM 2.9.64)` endpoint
> alongside the `Speakers` one. The earlier "V7 has no inputs" note here was
> wrong. Whether the input is line-only or line/phono is still unestablished —
> see [VENDOR-DRIVER.md](VENDOR-DRIVER.md).

> **The control stream does not need an audio client.** With the vendor driver
> loaded and nothing playing, the V7 streams control data continuously — 9 892
> messages in 5 s of platter motion with no audio application open. The driver
> sustains this itself with a dedicated frame-locked keepalive; see
> [VENDOR-DRIVER.md](VENDOR-DRIVER.md).

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
- ✅ **Input** example: platter motion → `B0 00 vv` (deck A, CC `0x00`) /
  `B0 02 vv` (deck B, CC `0x02`), a wrapping 7-bit position counter, paired
  1:1 with a `0xE0` pitch-bend timestamp for velocity.
- ✅ `B0 7D xx` / `B0 6E xx` appear at ~idle rate — device heartbeat/status.

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
- ✅ **Output**: send one MIDI message per 42-byte frame, `0xFD`-padded, on bulk
  `0x04`.

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
