# Handoff — picking this up on Windows

Written at the end of a macOS session that fixed four real bugs and failed to
fix the one that matters: the platter makes VirtualDJ's audio hiccup. Six
hypotheses are still standing and the Mac cannot cheaply distinguish between
them.

This is the counterpart to [HANDOFF-MAC.md](HANDOFF-MAC.md), which went the
other way. Read that one for the protocol work; read
[PROTOCOL.md](PROTOCOL.md) §"The platter stream, as a consumer sees it" and
[HARDWARE.md](HARDWARE.md) for the platter specifically.

---

## 0. Why Windows, specifically — this is not a change of scenery

On macOS, **OpenV7 is the driver.** There is no reference implementation to
compare against. Every decision about how the platter should be presented to a
DJ application is ours, so when the result is wrong we can only guess *which*
decision was wrong. That is exactly why six hypotheses are still alive after a
month: the Mac can measure our own output to 6 µs, and still cannot tell us
what the output was supposed to be.

On Windows the V7 runs under the **stock Ploytec/Numark driver v2.9.64**, which
publishes a MIDI port named `NUMARK_V7_MIDI01`. That driver shipped with a
product Serato supported in 2010. Whatever it emits when you spin the platter
is, by construction, the encoding that every V7 mapping ever written was
written against.

**Windows holds the oracle. Go read it.**

| Open question | On the Mac | On Windows |
|---|---|---|
| Is `0xE0` a timestamp or a 14-bit position? | inferred from clock statistics, still ambiguous | read what the vendor driver publishes |
| Does anything disambiguate the 7-bit wrap? | we invented a rule and cannot grade it | see whether the OEM bothered |
| Does the host see raw 42-byte frames? | we build the frames, so we cannot know | USBPcap the wire, diff against the MIDI port |
| Is the hiccup inherent to the device? | unanswerable — no control group | **run VirtualDJ on the vendor driver** |

That last row is the whole ballgame and it costs fifteen minutes.

---

## 1. The bug

With OpenV7 bridging and VirtualDJ in vinyl mode, audio hiccups — audible
skips and pops, forward and backward — while the motorised platter drives the
deck. Turning vinyl mode **off** removes them. The motor runs at constant
speed; the platter itself has no mechanical hiccup. The user's phrasing that
best characterises it: *"these are big hiccups and the motor and platter do not
have hiccups in the motion"* and *"at least it's consistently wrong, that makes
me think it's solvable"*.

**Latency budget:** anything under 10 ms end to end is a success, 5 ms is the
engineering target.

---

## 2. Eliminated — do not spend a second re-testing these

Each was measured on hardware, not reasoned about.

| Ruled out | How it died |
|---|---|
| Fabricated `0xE0` messages | real bug, fixed (3.39% → 0.79%, chance 0.78%); hiccups persisted |
| Delivery clumping | 93% evenly spaced *during* the fault — same as healthy |
| CoreMIDI dropping messages | delivery is 1:1; the earlier "11%" was my parser reading one message per packet |
| Control-IN queue depth | 1 / 2 / 4 / 8 / 16 all identical |
| Keepalives | none needed, none help |
| Our release timing | `THREAD_TIME_CONSTRAINT_POLICY` got it to 6 µs; hiccups unchanged |
| Timestamp re-timing (`--pace`) | on vs off is indistinguishable by ear |
| Device clock instability | 2822 measured vs 2825 theoretical, p25/p75 within ±7 |
| Lost encoder ticks | impossible — the FPGA counts quadrature in hardware; summed deltas give exactly 33.34 RPM |
| Motor ramp (Serato's documented trigger) | motor held constant; still hiccups |
| Deck-B stream interference | 126,317 × `B0 00` against 1 × `B0 02` |

---

## 3. The six live hypotheses, and which ones Windows kills

| # | Hypothesis | Windows verdict route |
|---|---|---|
| **H1** | VirtualDJ binds `0xE0` as 14-bit **position**, not a timestamp | **W2** — read what the OEM driver calls it |
| **H2** | The 7-bit wrap is ambiguous (~1.3 steps ≥64 counts per second) and lands the playhead up to ⅓ revolution away | **W2/W3** — see whether the OEM disambiguates, and how |
| **H3** | The deck's ~17 ms reporting gaps are simply too long for any host | **W1** — if the OEM stack hiccups too, this is inherent |
| **H4** | Our iso-OUT pacing disturbs the deck's reporting | **W3** — compare the OEM's iso cadence on the wire |
| **H5** | VirtualDJ's V7 support is incomplete on macOS — it drives LEDs but **never** commands the motor | **W4** — does it command the motor on Windows? |
| **H6** | Not MIDI at all — VDJ buffer size / sample rate / CPU | **W1** controls for this too |

H1 has a built experiment on the Mac (`--e0-position`, live-toggled with
`SIGUSR1`) that was never run. If you get a decisive answer from **W2** you may
not need it.

---

## 4. The experiments, in the order they should be run

### W1 — the control experiment (~15 min, do this first)

Plug the V7 into Windows with the stock driver. Load VirtualDJ, the same track,
vinyl mode **on**, motor **on**. Listen.

This single test partitions the entire hypothesis space:

- **No hiccups** → the fault is in *our bridge*. H1, H2, H4 stay alive; H3 and
  H6 die. Everything downstream becomes "find the difference between us and the
  OEM", which is a tractable engineering problem instead of a search.
- **Same hiccups** → the fault is in the *device or the encoding*, H3 wins, and
  no amount of bridge work will fix it. Serato's own
  [known-issue article](https://support.serato.com/hc/en-us/articles/203682530)
  documenting track skipping on the V7/NS7/NS7II becomes the expected result
  rather than a curiosity, and the goal shifts from "fix" to "mitigate".

Either answer is worth more than anything measured on the Mac in the last
month. **Record which it is before doing anything else.**

### W2 — read the vendor driver's platter stream (~30 min)

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\win\build.ps1        # once
powershell -ExecutionPolicy Bypass -File .\tools\win\midi-live.ps1
```

Spin the platter slowly by hand, then run the motor. Answer, in order:

1. **Does `0xE0` appear on the MIDI port at all?** If the driver swallows it,
   H1 collapses immediately and every host has only ever seen `B0 00`.
2. **If it appears, do its two data bytes track the clock or the position?**
   Turn the platter slowly through one revolution while stopped. A *timestamp*
   keeps advancing when the platter is still. A *position* does not. This is a
   five-second observation and it is the crux of H1.
3. **Does `B0 00` still wrap at 7 bits, or has the driver widened it?**

Then a longer structured pass for the address set:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\win\midi-observe.ps1 -Seconds 60
```

### W3 — capture the wire and diff it against the port (~1 h)

This is the definitive "what does the driver actually do to the stream"
measurement: record the raw USB frames and the published MIDI simultaneously,
then compare.

```powershell
# ELEVATED — attaches the USBPcap filter without a reboot
powershell -ExecutionPolicy Bypass -File .\tools\win\enable-usbpcap.ps1
powershell -ExecutionPolicy Bypass -File .\tools\win\capture-sweep.ps1
```

What to extract:

- the raw 42-byte inbound frames (compare against the layout in PROTOCOL.md —
  `<MIDI> <0xFD padding> <0x00 terminator>`)
- **the transformation**: for each raw frame, what reached the MIDI port. Any
  smoothing, interpolation, wrap handling or rate limiting the OEM applies
  lives in exactly this gap, and it is the thing we have been trying to
  reinvent blind.
- the iso-OUT cadence, for H4

Note from the last Windows session: USBPcap's control devices disappear when
the driver unloads, and restarting both hubs renumbers them, so the scripts
probe `\\.\USBPcapN` directly rather than trusting `--extcap-interfaces`
(which returns empty on that machine even elevated).

### W4 — does VirtualDJ command the motor on Windows? (~10 min)

On macOS, VDJ drives the LEDs but **never** emits `B0 41` / `B0 42` / `B0 43`
— not once, across every capture. For a deck whose entire premise is a
motorised platter that is a conspicuous gap, and it is H5's whole basis.

Run `midi-live.ps1` with VDJ loaded and watch the *outbound* direction while
loading a track and hitting play. If Windows VDJ commands the motor and macOS
VDJ does not, H5 is confirmed and the fix is a mapping problem, not a timing
problem.

### W5 — Serato, if a licence is available

Serato is the platform the V7 was designed for. If Serato DJ drives this unit
cleanly on Windows, W3's diff against *that* stream is the highest-fidelity
reference we will ever get.

---

## 5. Repo state you are inheriting

Branch **`diag/jog-clock`** at `c715197`, ahead of `main`. It carries the
committed diagnostic and fix work:

```
c715197  Write down what the platter stream actually looks like
d61d250  Document the hardware, and keep the service manual with it
ef24151  Stop the stall detector resetting an idle deck
9d9fee8  Recover from a stalled control pipe instead of spinning on it forever
0b0df7e  Stop parsing the frame terminator as MIDI
db07be5  Test the parser against real 42-byte platter frames
d00a63d  Add --diag-jog: measure the platter timestamp clock
```

### ⚠️ `src/main.c` is dirty — 251 lines uncommitted

An experimental prototype, **not** committed and **not** shipped:

| Piece | What it is | Status |
|---|---|---|
| `--pace` + `pace_thread` | real-time re-timing thread, `THREAD_TIME_CONSTRAINT_POLICY` + `mach_wait_until`, 5 ms buffer, clock recovery | works to 6 µs, **audibly does nothing** |
| `STEP_SAFE 32` | 7-bit wrap disambiguation | never cleanly A/B'd — it only ever ran *with* pacing, which turned out to be a no-op |
| `--e0-position` | rewrites `0xE0`'s payload as real 14-bit position; `SIGUSR1` toggles it live | **built, never run** — this is H1's test |
| `--no-timestamps` | suppress `0xE0` entirely | kills the jog in VDJ outright |
| `batch_frame` / `SIGUSR2` | packet batching | superseded |

It compiles with unused-variable warnings (`g_pace_vel`, `g_pace_next_fill`,
`g_pace_cc`). **Decide its fate before it rots**: the honest options are commit
it to a `proto/` branch as a labelled dead end with the measurements attached,
or extract only `--e0-position` and `STEP_SAFE` (the two that still have live
hypotheses behind them) and discard the pacing thread. Do not merge it to
`main` as-is — it is 251 lines of machinery whose only measured effect is
nothing.

Other branches: `feat/red-icon` (`fbfdaf0`, unpushed, cosmetic),
`fix/audit-findings-1-17` (ahead 1), `main` at `2fe9a85` = shipped v1.0.1.

---

## 6. What does **not** port — do not try to build the bridge on Windows

`src/main.c` is macOS-native throughout. This is a diagnostic trip, not a port.

| Dependency | Used for | Windows equivalent (if you ever do port) |
|---|---|---|
| CoreMIDI (`MIDIReceived`, virtual source) | publishing the MIDI port | WinRT MIDI or a teVirtualMIDI-class driver — **there is no built-in virtual MIDI port on Windows** |
| `mach_absolute_time` / `mach_wait_until` | µs scheduling | `QueryPerformanceCounter` + waitable timers |
| `THREAD_TIME_CONSTRAINT_POLICY` | real-time thread | MMCSS |
| IOKit (`kIOMainPortDefault`), `src/nonap.m` | App Nap suppression | n/a |
| `app/OpenV7App.m` | menu-bar app | n/a |
| Mach-O `LC_BUILD_VERSION`, `tools/pick-sdk.sh`, `check-stamps.sh` | the whole SDK-stamp fix | n/a |

libusb is the one portable piece — and on Windows the stock driver owns the
device, so you would have to displace it with WinUSB/Zadig to use libusb at
all, which destroys the very oracle you came for. **Leave the vendor driver
bound.**

---

## 7. Things this session concluded and got wrong

Worth more than the findings. Every one of these was stated confidently and was
false; the pattern in all of them is *inference presented as measurement*.

| Claim | Why it was wrong |
|---|---|
| "Delivery clumping causes the jitter" | read off min/max, never plotted the distribution — which turned out to be 93% even |
| "VDJ sends the deck nothing" | sampled a quiet tail of the log; there were 3,158 messages |
| "Root cause confirmed: VDJ binds E0 as pitch bend" | confounded by a bridge restart. The user caught it: *"but that is because the controller stopped controlling the software"* |
| "Only 11% of messages are delivered" | my parser read one message per packet |
| "Queue depth 8 halves the loss" | measured the effect of my own `-v` logging |
| "The reset warning is wrong" | the encoder returns after a reset; the **motor does not** |
| "The reset left the encoder unarmed" | drawn from a hand-spin test the user never performed |
| "The control stream is DEAD" | an empty capture, because the cue was never seen |

**Two rules that came out of this, and they apply on Windows too:**

1. **An empty capture is not evidence.** The first hypothesis for any empty
   result is that the cue was missed or the test was never run. This produced
   two separate false conclusions.
2. **Never change two things between measurements.** The single most expensive
   error above was a restart that coincided with a flag change.

### Hardware cues

When a test needs hands on the V7, *cue it audibly* — on macOS that was
`afplay` + `say`. The Windows equivalent:

```powershell
[console]::beep(880,200)
(New-Object -ComObject SAPI.SpVoice).Speak('spin the platter')
```

Keep any hands-on action under five seconds, and drive the hardware by command
where possible — the motor runs over MIDI (`B0 41 00` start, `B0 42 00` stop,
`B0 45 00` for 33 RPM), so most tests need no human at all.

---

## 8. Machine setup

```powershell
git clone <repo>; cd numarkv7
powershell -ExecutionPolicy Bypass -File .\tools\win\build.ps1   # -> OpenV7Midi.dll (gitignored)
```

- `OpenV7Midi.dll` and `OpenV7Wasapi.dll` are build artifacts, both gitignored.
  A loaded assembly is locked, so "stale copy" just means another PowerShell
  session has it open.
- USBPcap must be installed for W3; `enable-usbpcap.ps1` must run **elevated**
  and briefly re-enumerates every USB device on the restarted hubs — keyboards
  and mice blink out for a second or two.
- The service manual is committed at
  [`docs/V7-Service-Manual-Rev1-2010.pdf`](V7-Service-Manual-Rev1-2010.pdf) and
  stays in the repo as a deliberate right-to-repair position. `tools/win/pdftext.ps1`
  extracts text from it.

Still-unverified items left over from the last Windows session are listed in
[HANDOFF-MAC.md](HANDOFF-MAC.md) §6 — strip-search release behaviour, the
`0x08`–`0x0B` panel labels, the deck-B LED block. All low priority next to W1.

---

## 9. What to bring back to the Mac

1. **The W1 verdict.** One bit, and it redirects the whole project.
2. **A raw capture of the vendor driver's platter stream**, committed under
   `captures/`, so the Mac side can be graded against it offline instead of by
   ear.
3. **The W3 diff** — raw frames in, MIDI out. Whatever transformation the OEM
   applies is the specification we have been guessing at.
4. Whether Windows VDJ commands the motor (H5).

Anything measured on Windows belongs in `docs/PROTOCOL.md` with a ✅, or in
`docs/VENDOR-DRIVER.md` if it came from the driver rather than the wire. The
legend there is deliberate: 🧩 means "from static analysis, not confirmed on the
wire". Do not promote a 🧩 to a ✅ without a capture.
