# Handoff — the Windows machine is the working reference

**Status: the control experiment is done, and Windows won.**

Windows 11 + VirtualDJ + the stock Ploytec/Numark driver drives this V7 with
**zero hiccups**. The same deck, the same application, on Apple Silicon through
the OpenV7 bridge, hiccups audibly in vinyl mode.

That single result is worth more than everything measured on the Mac in the
last month, because it converts an open-ended search into a **diff**. Something
in the Windows path is sufficient to make VirtualDJ happy. We now go and find
out what.

Read [PROTOCOL.md](PROTOCOL.md) §"The platter stream, as a consumer sees it"
and [HARDWARE.md](HARDWARE.md) for the platter. [HANDOFF-MAC.md](HANDOFF-MAC.md)
covers the protocol work that got us here.

---

## 1. What the Windows result killed, and what it did not

| # | Hypothesis | Verdict |
|---|---|---|
| H3 | The deck's ~17 ms reporting gaps are too long for any host | **DEAD.** Same deck, same gaps, no hiccups |
| H6 | Not MIDI at all — VDJ buffer size / sample rate / CPU | **DEAD.** Same application, clean |
| H1 | VDJ binds `0xE0` as 14-bit position, not a timestamp | **alive** |
| H2 | The 7-bit wrap is ambiguous (~1.3 steps ≥64 counts/s) | **alive** |
| H4 | Our iso-OUT pacing disturbs the deck's reporting | **alive** |
| H5 | VDJ's V7 support is incomplete on macOS (never commands the motor) | **alive** |

Serato's [known-issue article](https://support.serato.com/hc/en-us/articles/203682530)
on V7/NS7 track skipping is now a red herring for our purposes — whatever it
describes, it is not what we have, because the OEM stack is clean on this unit.

### ⚠️ But "Windows works" narrows the fault to *one of four* differences

Resist the temptation to read the result as "our bridge is wrong." Four things
change at once between the two configurations, and only an experiment that
holds three constant can name the fourth.

| | Windows — **clean** | macOS — **hiccups** |
|---|---|---|
| Driver | Ploytec/Numark v2.9.64 | OpenV7 bridge |
| MIDI transport | WDM (`NUMARK_V7_MIDI01`) | CoreMIDI virtual source `Numark V7` |
| VirtualDJ build | Windows x64 | Apple Silicon arm64 |
| Audio path | WDM / ASIO | CoreAudio |

The experiments in §3 are ordered to separate exactly these.

---

## 2. Two findings from the Mac side that reframe the search

Both were verified on this machine today, and both were assumed otherwise
before.

### 2a. VirtualDJ is using its own built-in V7 definition — not ours

`~/Library/Application Support/VirtualDJ/Devices/` contains **only**
`controllers.dat`, a packed binary. The repo's
[`mappers/virtualdj/Numark_V7.xml`](../mappers/virtualdj/Numark_V7.xml) is
**not installed** — and `mappers/virtualdj/README.md` tells you to copy it to
`~/Documents/VirtualDJ/Devices/`, **a path that does not exist on this Mac**.
`settings.xml` records `Controller: V7, Gpu: Apple M1 Pro`, so VirtualDJ
recognised the deck natively.

*(Inferred, not proven: that recognition comes from a V7 definition inside
`controllers.dat`. The file is packed, so this has not been read directly.
Windows has the same file and the same question.)*

This matters enormously. VirtualDJ's native V7 definition **was written against
the OEM driver's stream.** We are feeding a definition we have never read with a
stream we built ourselves, and hoping the shapes match.

### 2b. Our own mapping file contradicts observed behaviour

`Numark_V7.xml` maps the jog as:

```xml
<map value="0xB0 0x00" name="jog"       deck="1" />
<map value="0xB0 0x02" name="jog"       deck="2" />
```

`0xE0` is **not mapped at all**. Yet suppressing `0xE0` on the bridge kills the
jog in VirtualDJ outright while `B0 00` keeps streaming at ~960/s. Both cannot
be true of the same consumer — which is independent confirmation that the
definition actually in force is the built-in one, and that it **does** consume
`0xE0` for something. What, is H1.

---

## 3. The experiments, in order

### X1 — Extract the OEM's transformation (the headline experiment)

Record the raw USB frames and the published MIDI **simultaneously**, then, for
each raw 42-byte frame, determine what reached the MIDI port. That gap is a
working specification for a stream VirtualDJ demonstrably accepts, and it is
precisely what we have spent a month trying to reinvent blind.

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\win\build.ps1        # once -> OpenV7Midi.dll
# ELEVATED — attaches the USBPcap filter without a reboot
powershell -ExecutionPolicy Bypass -File .\tools\win\enable-usbpcap.ps1
powershell -ExecutionPolicy Bypass -File .\tools\win\capture-sweep.ps1
```

Answer these in order. Each maps to a live hypothesis:

1. **Does `0xE0` reach the MIDI port at all?** If the driver swallows it, H1
   collapses and every host has only ever seen `B0 00`.
2. **If it does — timestamp, or position?** Turn the platter slowly by hand
   *while the motor is stopped*. A timestamp keeps advancing when the platter
   is still; a position does not. Five seconds, and it settles H1.
3. **Does the OEM emit ~936 msg/s like the raw wire, or does it decimate,
   smooth, or rate-limit?** Ours forwards essentially everything.
4. **Does `B0 00` still wrap at 7 bits, or has the driver widened or
   unwrapped it?** (H2 — this is where OEM wrap handling would live.)
5. **What is the OEM's iso-OUT cadence?** Ours runs 200/s. (H4)

Then the address-set sweep:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\win\midi-live.ps1
powershell -ExecutionPolicy Bypass -File .\tools\win\midi-observe.ps1 -Seconds 60
```

**Capture note from the last Windows session:** USBPcap's control devices
disappear when the driver unloads, and restarting both hubs renumbers them, so
the scripts probe `\\.\USBPcapN` directly rather than trusting
`--extcap-interfaces`, which returns empty on that machine even elevated.

### X2 — Replay the Windows stream into macOS VirtualDJ

**This is the experiment that separates the four confounds**, and it is the one
worth building code for.

Take the MIDI stream recorded in X1, bring the file back, and have the bridge
replay it into CoreMIDI verbatim — no device attached, no USB, no timing
decisions of ours. Then listen in VirtualDJ on the Mac.

- **Clean** → a stream Windows liked is also fine on macOS. Our *transport* is
  exonerated and our **encoding** is the fault. Fix = adopt the OEM's
  transformation from X1.
- **Hiccups** → the identical stream fails on macOS. The fault is downstream of
  the bytes: CoreMIDI delivery, VirtualDJ's macOS build, or its definition
  binding. Nothing we do to the encoding will help, and the search moves to X3.

This needs a `--replay <file>` mode in `src/main.c`: parse timestamped MIDI,
emit via `MIDIReceived` on the existing virtual source. Perhaps 80 lines, and
it reuses the packet path already there. **It is the highest-value code to
write next**, and unlike everything in the current dirty tree it produces a
falsifiable answer either way.

Record X1's capture with **arrival timestamps**, not just bytes, or the replay
cannot reproduce the cadence and the experiment is worthless.

### X3 — Does the port name or definition binding matter?

VirtualDJ's built-in definition may key on an exact port name, or on a
USB VID/PID it can only see through the OEM driver. On Windows the port is
`NUMARK_V7_MIDI01`; on macOS our virtual source is `Numark V7`.

1. Confirm the exact Windows port string (`midi-live.ps1` prints the device
   list; `MidiEnum::ListAll()` gives all of them).
2. Check whether Windows VirtualDJ shows the V7 under a different device name
   or definition than macOS does in **Settings ▸ Controllers**.
3. If the strings differ, rename the CoreMIDI source to match and retest. Cheap,
   and it directly probes H5.

Also worth grabbing while you are there: **`controllers.dat` from the Windows
install.** If the two platforms ship different V7 definitions, that alone could
be the whole bug.

### X4 — Does Windows VirtualDJ command the motor? (H5)

On macOS, VDJ drives the LEDs but **never** emits `B0 41` / `B0 42` / `B0 43`
— not once, across every capture. For a deck whose entire premise is a
motorised platter, that is a conspicuous gap.

Watch the **outbound** direction in `midi-live.ps1` while loading a track and
pressing play. If Windows commands the motor and macOS does not, H5 is
confirmed and this is a mapping problem, not a timing problem.

### X5 — Compare the arrival-time distributions

Ours is 93% evenly spaced, with ~17 ms gaps. Measure the same distribution on
Windows. If the OEM's is materially smoother, X1 question 3 explains why, and
we copy it. Report a histogram, **not** min/max — reading min/max instead of the
distribution produced one of the false conclusions in §6.

---

## 4. What to bring back

Commit these under `captures/`. The point is to grade the Mac side **offline
and numerically** instead of by ear — the ear has been the measurement
instrument all month and it is a poor one.

1. **A timestamped recording of the OEM's platter MIDI stream** — the input to
   X2, and the reference for everything else.
2. **The raw-frame ↔ published-MIDI diff** from X1. This is the specification.
3. **`controllers.dat`** from the Windows VirtualDJ install (X3).
4. The exact Windows MIDI port name (X3).
5. Whether Windows VDJ commands the motor (X4).
6. An arrival-time histogram (X5).

Findings from the wire go in [PROTOCOL.md](PROTOCOL.md) with a ✅; findings from
the driver binary go in [VENDOR-DRIVER.md](VENDOR-DRIVER.md). That file's
legend is deliberate — 🧩 means "from static analysis, not confirmed on the
wire". **Do not promote a 🧩 to a ✅ without a capture.**

---

## 5. Repo state you are inheriting

Branch **`diag/jog-clock`**, ahead of `main` (v1.0.1 shipped at `2fe9a85`).
Other branches: `feat/red-icon` (unpushed, cosmetic), `fix/audit-findings-1-17`
(ahead 1).

### ⚠️ `src/main.c` is dirty — 251 uncommitted lines

An experimental prototype, not committed and not shipped:

| Piece | What it is | Status |
|---|---|---|
| `--pace` + `pace_thread` | real-time re-timing, `THREAD_TIME_CONSTRAINT_POLICY` + `mach_wait_until` | works to 6 µs, **audibly does nothing** |
| `STEP_SAFE 32` | 7-bit wrap disambiguation | never cleanly A/B'd — only ever ran *with* pacing, which was a no-op |
| `--e0-position` | rewrites `0xE0`'s payload as 14-bit position; `SIGUSR1` toggles it live | **built, never run** — H1's Mac-side test |
| `--no-timestamps` | suppress `0xE0` entirely | kills the jog in VDJ outright |
| `batch_frame` / `SIGUSR2` | packet batching | superseded |

Compiles with unused-variable warnings (`g_pace_vel`, `g_pace_next_fill`,
`g_pace_cc`). **Decide its fate before it rots.** Given X1 will hand us the
OEM's actual transformation, the pacing thread is very likely dead weight —
keep `--e0-position` and `STEP_SAFE`, which still have live hypotheses behind
them, and retire the rest to a labelled `proto/` branch with its measurements
attached. Do not merge it to `main` as-is: 251 lines whose only measured effect
is nothing.

### A documentation bug worth fixing

`mappers/virtualdj/README.md` gives the install path as
`~/Documents/VirtualDJ/Devices/`. On this Mac the real path is
`~/Library/Application Support/VirtualDJ/Devices/`. Confirm the Windows path
while you are there and correct both.

---

## 6. What does **not** port — do not try to build the bridge on Windows

`src/main.c` is macOS-native throughout. This is a measurement trip.

| Dependency | Used for | Windows equivalent |
|---|---|---|
| CoreMIDI (`MIDIReceived`, virtual source) | publishing the port | WinRT MIDI or a teVirtualMIDI-class driver — **Windows has no built-in virtual MIDI port** |
| `mach_absolute_time` / `mach_wait_until` | µs scheduling | `QueryPerformanceCounter` + waitable timers |
| `THREAD_TIME_CONSTRAINT_POLICY` | real-time thread | MMCSS |
| IOKit (`kIOMainPortDefault`), `src/nonap.m` | App Nap suppression | n/a |
| `app/OpenV7App.m` | menu-bar app | n/a |
| Mach-O `LC_BUILD_VERSION`, `tools/pick-sdk.sh` | the SDK-stamp fix | n/a |

libusb is the one portable piece — but on Windows the stock driver owns the
device, and displacing it with WinUSB/Zadig would destroy the very reference
you came for. **Leave the vendor driver bound.**

---

## 7. Eight conclusions this session reached and got wrong

Worth more than the findings. Every one was stated confidently and was false.
The pattern in all of them is **inference presented as measurement**.

| Claim | Why it was wrong |
|---|---|
| "Delivery clumping causes the jitter" | read off min/max, never plotted the distribution — which was 93% even |
| "VDJ sends the deck nothing" | sampled a quiet tail of the log; there were 3,158 messages |
| "Root cause confirmed: VDJ binds E0 as pitch bend" | confounded by a bridge restart. The user caught it: *"but that is because the controller stopped controlling the software"* |
| "Only 11% of messages are delivered" | my parser read one message per packet |
| "Queue depth 8 halves the loss" | measured the effect of my own `-v` logging |
| "The reset warning is wrong" | the encoder returns after a reset; the **motor does not** |
| "The reset left the encoder unarmed" | drawn from a hand-spin test that was never performed |
| "The control stream is DEAD" | an empty capture, because the cue was never seen |

**Three rules that came out of it, all of which apply on Windows:**

1. **An empty capture is not evidence.** The first hypothesis for any empty
   result is that the cue was missed or the test never ran. This produced two
   separate false conclusions.
2. **Never change two things between measurements.** The single most expensive
   error above was a restart that coincided with a flag change.
3. **Report distributions, not extremes.** Min/max hid the answer twice.

### Hardware cues

When a test needs hands on the deck, cue it audibly rather than writing it in a
message:

```powershell
[console]::beep(880,200)
(New-Object -ComObject SAPI.SpVoice).Speak('spin the platter')
```

Keep any hands-on action under five seconds. Drive the hardware by command
where you can — the motor runs over MIDI (`B0 41 00` start, `B0 42 00` stop,
`B0 45 00` for 33 RPM), so most tests need no human at all.

---

## 8. Machine setup

```powershell
git clone <repo>; cd numarkv7
powershell -ExecutionPolicy Bypass -File .\tools\win\build.ps1   # -> OpenV7Midi.dll (gitignored)
```

- `OpenV7Midi.dll` / `OpenV7Wasapi.dll` are build artifacts, both gitignored. A
  loaded assembly is locked, so "stale copy" means another PowerShell session
  has it open.
- USBPcap is required for X1. `enable-usbpcap.ps1` must run **elevated** and
  briefly re-enumerates every USB device on the restarted hubs — keyboards and
  mice blink out for a second or two.
- The service manual is committed at
  [`V7-Service-Manual-Rev1-2010.pdf`](V7-Service-Manual-Rev1-2010.pdf) and stays
  in the repo as a deliberate right-to-repair position; `tools/win/pdftext.ps1`
  extracts text from it.

Lower-priority leftovers from the previous Windows session are in
[HANDOFF-MAC.md](HANDOFF-MAC.md) §6 — strip-search release behaviour, the
`0x08`–`0x0B` panel labels, the deck-B LED block. All of it is noise next to X1
and X2.
