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
| IF1 alt1 | `0x81` | isochronous | IN  | audio return (unused; V7 has no inputs) |
| IF1 alt1 | `0x86` | bulk | IN  | audio return / high-rate (drained) |

Both interfaces have a zero-bandwidth `alt0`; select `alt1` to stream.

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

## Control stream framing

- ✅ Control data is **standard MIDI** wrapped in the bulk stream, padded with
  `0xFD` idle bytes. Strip `0xFD` and parse normally.
- ✅ **Input** example: platter motion → `B0 00 vv` (deck A, CC `0x00`) /
  `B0 02 vv` (deck B, CC `0x02`), a wrapping 7-bit position counter, paired with
  a `0xE0` pitch-bend timestamp for velocity (3600 ticks/rev, clock 2,822,400 Hz).
- ✅ `B0 7D xx` / `B0 6E xx` appear at ~idle rate — device heartbeat/status.
- ✅ **Output**: send one MIDI message per 42-byte frame, `0xFD`-padded, on bulk
  `0x04`.

## Motor command set (host → device, on bulk `0x04`)

Status byte `0xB0`, deck A shown. From the Mixxx/community map; ✅ = confirmed
to move the platter on this unit.

| Function | Message | Notes |
|---|---|---|
| Soft-start (ramp) | `B0 43 00` | ✅ platter spins up |
| Brake (ramp stop) | `B0 44 00` | ✅ platter stops |
| Instant start | `B0 41 00` | ✅ |
| Instant stop | `B0 42 00` | 🔬 |
| RPM select | `B0 45 vv` | ✅ `00` = 33⅓, `01` = 45 (speed changes live) |
| Direction | `B0 46 vv` | 🔬 `00` fwd / `01` reverse — reverse not yet confirmed on hardware |
| Ramp times | `B0 47/48 vv` | 🔬 start / brake ramp speed |
| Pitch trim (follow playback) | `B0 49 msb` + `B0 69 lsb` | 🔬 signed; Serato maps rate ±0.519 → ±5190 |

**Open item — reverse.** `B0 46 01` did not visibly reverse the platter with a
soft-start after braking. Candidate fixes to verify: full instant-stop + latch
before an instant-start, or driving reverse via negative pitch-trim
(`B0 49`/`B0 69`) the way Serato produces backspins.

## Audio codec (not yet implemented)

The V7's audio is a Ploytec **bit-sliced** format (channels interleaved at the
bit level), 24-bit / 44.1 kHz, 4 output channels (deck A + deck B stereo), no
inputs. The iso-OUT packet is 156 bytes. Decoding/encoding this is the main
remaining work for native audio support — see [ROADMAP.md](ROADMAP.md).
