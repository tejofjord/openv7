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

## 🧩 The 64-byte input frame layout

The V7's input frame size — 64 bytes at 44.1 kHz — matches Ozzy's
`PLOYTEC_IN_FRAME_SIZE` exactly, so its `ploytec_decode_frame` is very likely
the V7's layout. Reduced from that implementation (MIT, Marcel Bierling) to a
rule rather than 24 lines of shifts:

**Each channel occupies one bit position across 24 consecutive bytes, one bit
per byte, MSB of the sample first.**

| Bytes | Bit 0 | Bit 1 | Bit 2 | Bit 3 | Bits 4–7 |
|---|---|---|---|---|---|
| `0x00`–`0x17` | ch 1 | ch 3 | ch 5 | ch 7 | unused |
| `0x20`–`0x37` | ch 2 | ch 4 | ch 6 | ch 8 | unused |
| `0x18`–`0x1F`, `0x38`–`0x3F` | — | — | — | — | **entirely unused** |

So to recover channel *n*'s 24-bit sample: walk the 24 bytes of its half in
order, take the bit at its position from each, and shift them in MSB-first —
byte `0x00` carries the sample's most significant bit, byte `0x17` its least.

Two consequences worth noting:

- **16 of the 64 bytes are padding.** Only 48 bytes carry data (24 per half),
  and only the low 4 bits of each. The frame is 8 channels × 24 bits = 192
  bits inside a 512-bit frame.
- **This is a genuine bit-scatter**, unlike the V7's output. A byte-wise
  deinterleave of the input will produce noise.

> ⚠️ **Inferred, not confirmed on a V7.** The frame-size match is strong
> evidence, but caution is warranted precisely because the V7's *output* turned
> out **not** to follow Ozzy's Xone layout — the Xone encodes output into
> 48-byte bit-interleaved frames on bulk, while the V7 sends plain 24-bit PCM
> over isochronous. Having diverged on one direction, it may diverge on the
> other. The V7 also has fewer channels than 8, so it probably populates only
> the first one or two bit positions per half.

### Why it could not be confirmed here

Bulk IN `0x86` carried **all zeros** during both the tone and the silence, so
there was no signal to check the layout against.

Two software explanations for that silence were tested and both eliminated:

1. **ADC gated until something opens the input?** No. A WASAPI capture stream
   on the `Line In (Numark V7 Audio)` endpoint delivered **220,059 frames at
   44,011/s — a real, running stream — with zero non-zero bytes**.
2. **Endpoint muted or at zero gain?** No. `IAudioEndpointVolume` reports
   **mute=0, master 100 %, both channels 100 %**, with `QueryHardwareSupport`
   = `0x0` (a pure software endpoint with no hardware mute/gain to clear).

So the pipe is open, unmuted, streaming at full rate, and carrying exact
zeros — there is simply no signal at the converters.

**This one is hard-blocked on physical cabling.** Determining the input
encoding requires an actual signal at the V7's rear inputs — either a source
plugged in, or an RCA loopback from the V7's own outputs back to its inputs,
with a capture running while audio plays. `tools/win/capture-audio.ps1` already
does everything else; with a loopback in place it would resolve this in one
run. Everything else about the input is already measured.

> There is one remaining *software* avenue, deliberately not taken. Ozzy
> documents bit `0x02` of vendor register `'I'` as **input routing / source
> select**, and `v7_usb.sys` has a `WRITE INPUT SELECT` path — so the input
> source may well be switchable, conceivably to an internal loopback. Reaching
> it means sending vendor control requests, which the Windows vendor driver
> owns exclusively; the only way in is to unbind it and attach WinUSB instead
> (Zadig or similar). That would break the working driver every other result
> here depends on, and is not reversible with one click, so it should be a
> deliberate decision rather than a side effect of chasing this last field.

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
