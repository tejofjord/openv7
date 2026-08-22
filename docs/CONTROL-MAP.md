# Numark V7 — control map

Full two-way map of the V7's control surface: every control the device reports,
and every LED / motor command the host can send.

## Provenance and confidence

Two independent sources, marked per row:

- ✅ **Measured on this hardware** — confirmed by OpenV7 through the Windows
  vendor driver's MIDI port, using the platter position counter as a
  tachometer. See [PROTOCOL.md](PROTOCOL.md).
- 🔬 **Cross-referenced, not yet confirmed on hardware** — addresses extracted
  from the community Mixxx mapping for the V7
  (`res/controllers/Numark V7.midi.xml` and `Numark-V7-scripts.js`, by Mike
  Bucceroni, GPL-2.0). Only the factual MIDI addresses are reproduced here; no
  code was copied.

**The two sources agree everywhere they overlap.** Every motor command OpenV7
measured independently — `0x43` start, `0x44` stop, `0x45` RPM select, `0x46`
reverse, `0x47`/`0x48` ramp times, `0x49`+`0x69` pitch trim — appears in the
Mixxx map with the same meaning. That mutual corroboration is the main reason
to trust the 🔬 rows, but they are still unverified on a physical unit.

Caveat: the Mixxx mapping has internal inconsistencies (several deck-B handlers
are bound to `[Channel1]`), so treat its *deck assignment* with more suspicion
than its *addresses*.

## Structural rules

The address space is laid out in regular blocks, which is the fastest way to
sanity-check any single row:

| Block | Deck A | Deck B | Offset |
|---|---|---|---|
| Buttons (device → host, note-on) | `0x0F`–`0x2B` | `0x30`–`0x4C` | **+0x21** |
| LEDs (host → device, CC) | `0x07`–`0x1C` | `0x1D`–`0x33` | **+0x16** |
| Motor (host → device, CC) | `0x43`–`0x49` | `0x4D`–`0x53` | **+0x0A** |

Continuous controls use the standard MIDI 14-bit convention — **coarse on CC
`n`, fine on CC `n+32`** — which is the same pairing the motor pitch trim uses
(`0x49` / `0x69`).

---

## Input — device → host (bulk IN `0x83`)

### Platter and continuous controls (CC, status `0xB0`)

| CC A | CC B | Control | Confidence |
|---|---|---|---|
| `0x00` | `0x02` | **Platter position** — 7-bit wrapping counter, 3600 counts/rev | ✅ |
| `0x04` + `0x24` | `0x05` + `0x25` | **Pitch fader** (coarse + fine, 14-bit) | 🔬 |
| `0x45` | `0x4D` | **Strip search** (needle strip) | 🔬 |
| `0x46` | `0x4E` | **Motor START TIME knob** | 🔬 |
| `0x47` | `0x4F` | **Motor STOP TIME knob** | 🔬 |
| `0x44` | — | **Browse / track select knob** | 🔬 |
| `0x56`, `0x58` | | FX parameter | 🔬 |
| `0x57` + `0x77` | `0x59` + `0x79` | FX slider (coarse + fine) | 🔬 |
| `0x5A`, `0x5B` | | FX select | 🔬 |

Each platter position message is paired 1:1 with a `0xE0` pitch-bend carrying a
14-bit timestamp on a **2,822,400 Hz** clock ✅ — that pairing is what yields
velocity. A stationary platter sends nothing at all ✅.

> ⚠️ **Input and output CC numbers overlap and do not mean the same thing.**
> Input CC `0x45` is the deck-A strip search; output CC `0x45` is motor RPM
> select. Input `0x46`/`0x47` are the start/stop-time knobs; output `0x46` is
> motor direction and `0x47`/`0x48` are the ramp times. Direction disambiguates
> them — a bridge must not treat the control map as symmetric.

### Buttons (note-on, status `0x90`)

Deck B = deck A + `0x21`. Mixxx key names given as the primary data; the
"likely control" column is inference from those names and is **not** authoritative.

| Note A | Note B | Mixxx key | Likely control |
|---|---|---|---|
| `0x0F` | `0x30` | `beatsync` | SYNC |
| `0x10` | `0x31` | `cue_default` | CUE |
| `0x11` | `0x32` | `Play` | PLAY / PAUSE |
| `0x12` | `0x33` | `Shift` | SHIFT |
| `0x13`–`0x17` | `0x34`–`0x38` | `Hot1`–`Hot5` | **HOT CUE 1–5** |
| `0x18` | `0x39` | `rate_temp_down` | PITCH BEND − |
| `0x19` | `0x3A` | `rate_temp_up` | PITCH BEND + |
| `0x1A` | `0x3B` | `RateRange` | PITCH RANGE |
| `0x1B` | `0x3C` | `keylock` | KEY LOCK |
| `0x1C`, `0x1D` | `0x3D`, `0x3E` | `Reverse` | REVERSE / CENSOR |
| `0x1E` | `0x3F` | `bpm_tap` | TAP |
| `0x21` | `0x42` | `MotorOffButton` | MOTOR ON/OFF |
| `0x22` | `0x43` | `loop_halve` | LOOP ½ |
| `0x23` | `0x44` | `loop_double` | LOOP ×2 |
| `0x24` | `0x45` | `reloop_exit` | RELOOP / EXIT |
| `0x25` | `0x46` | `LoopShiftDown` | LOOP SHIFT ◀ |
| `0x26` | `0x47` | `LoopShiftUp` | LOOP SHIFT ▶ |
| `0x27` | `0x48` | `LoopMode` | LOOP MODE |
| `0x28` | `0x49` | `loop_in` | LOOP IN |
| `0x29` | `0x4A` | `loop_out` | LOOP OUT |
| `0x2A` | `0x4B` | `Select` | SELECT |
| `0x2B` | `0x4C` | `Reloop` | RELOOP |

Non-deck buttons:

| Note | Mixxx key | Likely control |
|---|---|---|
| `0x06` / `0x07` | `SelectPrev/NextPlaylist` | BACK / FWD (browse) |
| `0x08`, `0x0D` | `LoadSelectedIntoFirstStopped` | LOAD |
| `0x0C` / `0x0E` | `LoadSelectedTrack` ch1 / ch2 | LOAD A / LOAD B |
| `0x52` / `0x59` | `flanger` ch1 / ch2 | FX ON A / B |
| `0x53` / `0x5A` | `FxSelect` | FX SELECT |
| `0x54` / `0x5B` | `MasterL` / `MasterR` | MASTER L / R |
| `0x5C` / `0x7D` | `DeckSelectL` / `DeckSelectR` | DECK SELECT L / R |

---

## Output — host → device (bulk OUT `0x04`)

All output is **CC on status `0xB0`** — note-on does *not* drive the LEDs. Send
one MIDI message per 42-byte `0xFD`-padded frame.

### LEDs

Deck B = deck A + `0x16`. Values are `0x00` = off, `0x01` = on unless noted.

| CC A | CC B | Lights | Confidence |
|---|---|---|---|
| `0x07` | `0x1D` | SYNC | 🔬 |
| `0x08` | `0x1E` | CUE | 🔬 |
| `0x09` | `0x1F` | PLAY | 🔬 |
| `0x0A`–`0x0F` | `0x20`–`0x25` | Shift-layer LEDs (6) | 🔬 |
| `0x10` | `0x27` | KEY LOCK | 🔬 |
| `0x11` | `0x28` | TAP | 🔬 |
| `0x12` | `0x29` | MOTOR OFF | 🔬 |
| `0x13` | `0x2A` | LOOP ½ | 🔬 |
| `0x14` | `0x2B` | LOOP ×2 | 🔬 |
| `0x15` | `0x2C` | LOOP ON/OFF | 🔬 |
| `0x16` | `0x2D` | LOOP SHIFT ◀ | 🔬 |
| `0x17` | `0x2E` | LOOP SHIFT ▶ | 🔬 |
| `0x18`–`0x1C` | `0x2F`–`0x33` | LOOP MODE (5) | 🔬 |
| `0x37` | `0x38` | **Pitch-at-zero indicator** — verified *not* a motor command ✅ | ✅/🔬 |
| `0x3C` | `0x3D` | FX button | 🔬 |

Global / shared:

| CC | Function | Confidence |
|---|---|---|
| `0x03` / `0x04` / `0x05` | PREPARE / FILES / CRATES browse LEDs | 🔬 |
| `0x34`, `0x35`, `0x36` | **Numeric display / ring** — values `0x00`–`0x0C`, driven as a group of three | 🔬 |
| `0x39` | **All-LED flash / all-off** | 🔬 |

`0x34`/`0x35`/`0x36` take a small ordinal (0–12) rather than an on/off, and the
Mixxx script drives all three together — consistent with a segmented display or
a 12-position indicator ring rather than discrete lamps.

### Motor (deck B = deck A + `0x0A`)

| CC A | CC B | Function | Confidence |
|---|---|---|---|
| `0x41` | `0x4B` | **Instant start** | ✅ (absent from the Mixxx map) |
| `0x42` | `0x4C` | **Instant stop** | ✅ (absent from the Mixxx map) |
| `0x43` | `0x4D` | Soft start | ✅ |
| `0x44` | `0x4E` | Brake | ✅ |
| `0x45` | `0x4F` | RPM select — `00` = 33⅓, `01` = 45 | ✅ |
| `0x46` | `0x50` | Direction — `01` = reverse, latched while stopped | ✅ |
| `0x47` | `0x51` | Start ramp time | ✅ |
| `0x48` | `0x52` | Brake ramp time | ✅ |
| `0x49`+`0x69` | `0x53`+`0x73` | Pitch trim, signed 14-bit | ✅ |

OpenV7's hardware testing found `0x41` / `0x42` (instant start/stop), which the
community mapping does not contain. Deck-B addresses for those are inferred
from the +`0x0A` block offset and are unverified.

Full semantics for the motor commands — including the reverse latching gotcha
and the pitch-trim law — are in [PROTOCOL.md](PROTOCOL.md).

---

## Confirming the 🔬 rows

Both directions can be verified on hardware with the Windows tooling:

```
powershell -ExecutionPolicy Bypass -File .\tools\win\midi-learn.ps1   # inputs
powershell -ExecutionPolicy Bypass -File .\tools\win\led-probe.ps1    # outputs
```

`midi-learn` watches for a control gesture and asks what it was; `led-probe`
sweeps every output while you tap SPACE at whatever lights up. Both write their
results to `captures/`.
