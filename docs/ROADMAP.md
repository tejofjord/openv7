# Roadmap

## v1 (this release)
- [x] Ploytec bring-up (handshake + iso clock) on Apple-Silicon macOS
- [x] Control-IN → CoreMIDI virtual source
- [x] CoreMIDI virtual destination → control-OUT (LEDs, motor)
- [x] VirtualDJ starter mapping
- [x] Document the full per-control map — see [CONTROL-MAP.md](CONTROL-MAP.md)
- [ ] Confirm the cross-referenced rows on hardware (`openv7 --learn`, or
      `tools/win/midi-learn.ps1` / `led-probe.ps1` on Windows). The platter and
      motor set are already measured; the buttons, pads, faders and LEDs are not.
- [x] Confirm platter reverse — `B0 46 01`, latched while stopped (PROTOCOL.md)
- [x] Confirm the whole motor command set incl. ramp times and pitch-trim law

## v1.x — polish
- [x] LED address map documented ([CONTROL-MAP.md](CONTROL-MAP.md)); still to
      be confirmed on hardware with `tools/win/led-probe.ps1`
- [ ] Motor "follow playback" via the `B0 49/69` pitch-trim, driven from the
      DJ app's playhead where available
- [ ] `launchd` plist so the bridge auto-starts on device plug-in
- [ ] Homebrew formula

## v2 — native audio
- [x] **Output format decoded — there is no codec to write.** Captured with a
      known sine: the V7's iso-OUT is plain interleaved **24-bit signed LE,
      4 channels, 12 bytes per frame**, not bit-sliced. See
      [AUDIO-CODEC.md](AUDIO-CODEC.md).
- [x] Packet geometry measured: 40 iso packets/URB, sizes alternating
      **72/60 bytes** (6 and 5 audio frames), ~529 kB/s.
- [x] **Fix the iso pacing** — done in `iso_pace()` (see HANDOFF-MAC.md §1).
- [x] Feed real PCM into the iso packets (no encoder needed) — `--audio`,
      `--tone`; see [AUDIO.md](AUDIO.md). 🔬 Not yet heard on a deck.
- [x] Input (`0x86`) frame layout documented — bit-scatter, one bit per byte
      across 24 bytes per channel ([AUDIO-CODEC.md](AUDIO-CODEC.md))
- [ ] Confirm the input layout on a V7 — the output diverged from the Xone, so
      the input may too. Needs a live source or an RCA loopback in the V7's
      inputs, then `tools/win/capture-audio.ps1`.
- [x] Expose a CoreAudio virtual device (AudioServerPlugin) so the V7's own
      outputs are selectable in any app — `driver/`, a 4-ch loopback the
      bridge records
- [x] Reconcile the device clock with the iso stream — done on the bridge
      side instead: a drift-steered resampler, bit-exact while the clocks agree
- [x] Tone on both decks — heard 2026-11-20; deck B needs no mode switch
- [x] Pace iso-OUT from the deck's feedback (iso IN `0x81`, 1 count/ms) — the
      deck's crystal runs ~195 ppm fast, and a fixed 44.1 kHz starved it into a
      screech every ~20 s. 🔬 Re-test on the deck.
- [ ] Confirm on hardware: no stall at iso depth 8, how low the depth can go
      ([AUDIO.md](AUDIO.md#still-to-confirm-on-a-v7))
- [ ] Re-test the two control keepalives with feedback pacing on: the old
      "control dies at ~24 s" looks like the same starved FIFO

## Beyond macOS
- [ ] **Linux** backend (ALSA / snd path; the V7 never had a Linux driver)
- [ ] **Windows** backend (WinUSB + a virtual MIDI/audio device)
- [ ] Share the transport/codec core across platforms (à la Ozzy)

## Other apps
- [x] VirtualDJ mapping
- [x] VirtualDJ on macOS commands the motor after all — when it is started
      AFTER the bridge (see mappers/virtualdj/README.md). It sends no SysEx, so
      the device-inquiry theory is ruled out (the bridge now forwards the
      inquiry and the deck's replies anyway, and logs every SysEx).
- [x] Strip search / deck flip / load putting the playhead before the audio
      (reported 2026-11-20): releases and the deck-switch dump report the strip
      as `01`, which VirtualDJ takes as a seek to ~0.8 %. `--strip-filter`
      normalises them to one `00` (CONTROL-MAP.md); confirmed for deck select
      and load. Default since 1.1.0 (`--strip-raw` turns it off).
- [x] Strip search ends (2026-11-20): VirtualDJ's V7 profile maps ~10.6..116.4
      onto the track (CONTROL-MAP.md). `--strip-out 10,115` plus the delay-line
      filter, confirmed on hardware 2026-11-21; default since 1.1.0.
- [ ] VirtualDJ sends `f0 00 20 7f 03 01 f7` when the port is named
      "Numark V7 MIDI" (Windows name). `00 20 7F` is Serato's manufacturer ID
      and `03 01` its documented "send me every control's current value"
      request (Mixxx wiki, Serato sysex). Dropped for now; forwarding it would
      match Windows if the deck answers it.
- [ ] Mixxx (a community `Numark V7.midi.xml` already exists; adapt for the
      bridge's virtual port)
- [ ] Serato — gated to supported hardware; likely out of scope
- [ ] Generic Traktor `.tsi`
