# Ploytec audio codec and packet framing

Notes toward native audio support (ROADMAP v2). The V7's audio is a Ploytec
**bit-interleaved** format — channels are spread across the packet at the bit
level rather than being byte-packed — which is the main reason OpenV7 currently
streams silence rather than real audio.

## Source and applicability

Almost everything here comes from the [Ozzy](https://github.com/mischa85/Ozzy)
project (MIT, Marcel Bierling), which reverse-engineered the Ploytec chipset for
the Allen & Heath Xone family, cross-referencing the Windows and macOS vendor
drivers.

> ⚠️ **Ozzy's constants are for the Xone family, not the V7.** Ozzy targets
> VID `0x0A4A` with PCM on endpoints `0x05`/`0x06` and MIDI on `0x03`. The V7 is
> VID `0x15E4` — absent from Ozzy's device table — and has a different endpoint
> topology (iso OUT `0x02`, bulk IN `0x83`, bulk OUT `0x04`, iso IN `0x81`,
> bulk IN `0x86`). Treat the **mechanism** below as transferable and every
> **number** as needing confirmation against a V7 capture.
>
> One concrete mismatch: PROTOCOL.md records the V7's iso-OUT packet as 156
> bytes, which is not a multiple of Ozzy's 48-byte output frame. The V7's packet
> geometry is genuinely different and is not yet derived.

## ✅ Measured: the real packet geometry

An earlier revision of this file hypothesised that iso-OUT `0x02` was only a
keepalive pipe and that PCM rode on the bulk endpoints. **A USB capture of the
vendor driver disproved that.** `0x02` is the PCM output pipe, exactly as
PROTOCOL.md originally said. The numbers below replace that hypothesis.

Captured with USBPcap on Windows, 90 s, device idle except for a scripted motor
burst (`tools/win/capture-idle.ps1`). No audio was playing — the vendor driver
streams silence continuously regardless.

| Endpoint | Type | Measured rate | Interpretation |
|---|---|---|---|
| iso OUT `0x02` | isoc | **529,303 B/s** | **PCM OUT** — 4 ch × 24-bit × 44.1 kHz = 529,200 B/s (**0.02 %**) |
| bulk IN `0x86` | bulk | **2,822,685 B/s** | **PCM IN** — 64 B/frame × 44,100 = 2,822,400 B/s (**0.01 %**) |
| bulk IN `0x83` | bulk | 37,807 B/s active, **13 B/s idle** | control / MIDI |
| iso IN `0x81` | isoc | 3,000 B/s | near-empty, but must be drained |
| bulk OUT `0x04` | bulk | **~0** | control only, and only when something is sent |

Both audio rates land within 0.02 % of a clean theoretical figure, and the
input frame size is **exactly** Ozzy's `PLOYTEC_IN_FRAME_SIZE` of 64 bytes.

### iso-OUT packet layout ✅

From the URB structure in the capture:

- **40 isochronous packets per URB**, 2640 bytes total, ~400 URBs/s.
- Individual packet sizes **alternate `0x48` (72 B) and `0x3C` (60 B)**.
- At 12 bytes per audio frame (4 ch × 3 B) that is **6 and 5 audio frames**
  alternating — averaging 5.5 frames per 125 µs microframe, i.e. ~44.1 kHz
  (the exact ratio is 44100/8000 = 5.5125).
- `wMaxPacketSize` is 156, so the endpoint has headroom; the driver does **not**
  fill it.

So the V7 is a **4-channel 24-bit output** device, not the 8-channel/48-byte
Ploytec junction layout Ozzy documents for the Xone family. The Xone frame
sizes do not apply to the V7's output. The *input* frame size (64 B) does.

## ✅ The output encoding — decoded, and it is NOT bit-interleaved

Captured with a 441 Hz sine at amplitude 0.5 rendered straight into the V7's
own endpoint via WASAPI (`tools/win/capture-audio.ps1`), so the payload is a
known signal. The iso-OUT bytes come out as:

```
1139cc 1139cc 000000 000000 | 88f6c9 88f6c9 000000 000000 | 98eac7 98eac7 000000 000000
  ch1    ch2    ch3    ch4  |   ch1    ch2    ch3    ch4  |   ch1    ch2    ch3    ch4
```

**Plain interleaved `S24_3LE`: 4 channels × 24-bit signed little-endian,
12 bytes per audio frame.** Nothing is scattered, nothing is bit-sliced.

Decoding the successive ch1 values as signed 24-bit LE traces a clean sine
trough and bottoms out at `00 00 c0` = `0xC00000` = **−4,194,304**, which is
exactly **−0.5 × 2²³** — precisely the amplitude requested. Values then rise
back symmetrically. The waveform is reproduced exactly, so there is no
transformation on the wire at all.

Channel assignment: the tone was played to the `Speakers (Numark V7 Audio)`
endpoint and landed on **channels 1 and 2**, with **3 and 4** silent — deck A
and deck B stereo pairs respectively.

> **This overturns the project's central audio assumption.** ROADMAP.md called
> decoding the Ploytec bit-sliced format "the main remaining work" for native
> audio. For the V7's *output* there is no such format to decode — writing
> ordinary interleaved 24-bit PCM into the iso packets is sufficient. The
> bit-interleaved codec Ozzy documents belongs to the Xone family's bulk PCM
> path, not to the V7's isochronous output.

### The input side is still unknown

Bulk IN `0x86` carried **all zeros** during both the tone and the silence,
because nothing was connected to the V7's line input. Its *rate* is pinned
(64 B/frame × 44.1 kHz) and that frame size matches Ozzy's
`PLOYTEC_IN_FRAME_SIZE` exactly, which is suggestive of the 64-byte
bit-per-byte input layout — but with no signal present this capture cannot
confirm it. Determining the input encoding needs a capture with a live source
plugged into the V7's inputs.

## The codec

8 channels of 24-bit audio, converted between standard `S24_3LE` interleaved
audio and the device format:

| Direction | Device frame | Host frame |
|---|---|---|
| Output (host → device) | **48 bytes** | 24 bytes (8 ch × 3 B) |
| Input (device → host) | **64 bytes** | 24 bytes |

Two structural facts about the scatter pattern:

- **Output**: odd channels (1, 3, 5, 7) occupy the first 24 output bytes; even
  channels (2, 4, 6, 8) occupy the second 24.
- **Input**: a bit-per-byte layout — each byte carries one bit per channel, so
  decoding is a gather across all 64 bytes rather than a per-channel slice.

This is why a naive byte-deinterleave produces noise: no channel is ever
contiguous in the packet.

## Packet framing — where MIDI lives

The chipset interleaves **MIDI bytes between groups of audio frames** in the
same packet. This is the missing piece that explains the V7's control framing:
the `0xFD` idle byte and the fixed-size control frame are not a separate
protocol, they are the MIDI slots of the audio packet layout.

Bulk output packet (2048 bytes) — 4 groups of 10 audio frames, each followed by
a 1-byte MIDI slot:

| Group | Frames | Audio at offset | MIDI byte at |
|---|---|---|---|
| 0 | 0–9 | 0 | 480 |
| 1 | 10–19 | 512 | 992 |
| 2 | 20–29 | 1024 | 1504 |
| 3 | 30–39 | 1536 | 2016 |

Interrupt output packet (1928 bytes) uses 5 uneven groups with **2-byte** MIDI
slots at 432, 914, 1396 and 1878.

`0xFD` is the MIDI idle/sync byte, emitted when no MIDI is pending ✅ — this
matches what OpenV7 already observed on the V7's bulk `0x04`.

This also explains two strings in the Windows driver (see
[VENDOR-DRIVER.md](VENDOR-DRIVER.md)):

```
USBMidiPattern::initForBulk sr:%d rtsBulkOutFramesPerBlock:%d
ALERT mRtsBulkOutFramesPerBlock==0
```

— "frames per block" is exactly the group size in the table above, and it is
computed from the sample rate rather than hardcoded.

## Sample rate

3-byte little-endian, both directions:

```
GET_CUR   bmRequestType 0xA2  bRequest 0x81  wValue 0x0100  wLength 3
SET_CUR   bmRequestType 0x22  bRequest 0x01  wValue 0x0100  wLength 3
```

The official driver sends SET_CUR **five times**, alternating between the two
streaming endpoints (3× to the IN endpoint, 2× to the OUT endpoint). OpenV7
currently sends it to "several endpoint wIndex values" — worth matching the
exact repetition, since it may matter for reliable locking.

## Firmware version — request `'V'` (0x56)

15-byte response. OpenV7 already reads byte 0 (chip ID, `0x33` on the V7).
Ozzy decodes one more field:

| Byte | Meaning |
|---|---|
| 0 | chip ID |
| 2 | version, decimal-encoded: `v1.{b/10}.{b%10}` |

## Format ID

The vendor driver derives a codec selector from bit depth:

```
format_id = (resolution_bits - 16) / 4     # 16→0, 20→1, 24→2, 32→4
```

Input and output resolutions are independent.

## Implementation order

Much shorter than previously thought, now that the output format is known:

1. **Fix the iso pacing first** — OpenV7 sends fixed 156-byte packets where the
   vendor driver alternates 72/60. That is a 2.36× overfeed and is the prime
   suspect for the long-idle stall (see
   [PROTOCOL.md](PROTOCOL.md#️-implication-for-openv7s-long-idle-stall)).
   Getting this right is worth doing on its own, before any audio work.
2. **Write PCM into the iso packets** as plain interleaved 24-bit LE,
   4 channels, 12 bytes per frame, 6 and 5 frames in alternating packets. No
   codec required.
3. Expose it as a CoreAudio device.
4. Input (`0x86`) only once there is a reason to — its encoding is still
   unconfirmed and the V7 is primarily an output device.

The MIDI-slot framing described above belongs to the Ploytec **bulk** PCM path.
The V7 sends control on its own bulk endpoints, separate from the isochronous
audio, so that interleaving does not apply here.
