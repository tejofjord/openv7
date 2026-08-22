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
- [ ] **Fix the iso pacing** — OpenV7 sends fixed 156-byte packets, a 2.36×
      overfeed, and the prime suspect for the long-idle stall. Do this first.
- [ ] Feed real PCM into the iso packets (no encoder needed)
- [ ] Input (`0x86`) encoding — rate known (64 B/frame), format unconfirmed;
      needs a capture with a live source in the V7's inputs
- [ ] Expose a CoreAudio virtual device (AudioServerPlugin) so the V7's own
      outputs are selectable in any app
- [ ] Sync the audio device clock to the iso stream

## Beyond macOS
- [ ] **Linux** backend (ALSA / snd path; the V7 never had a Linux driver)
- [ ] **Windows** backend (WinUSB + a virtual MIDI/audio device)
- [ ] Share the transport/codec core across platforms (à la Ozzy)

## Other apps
- [x] VirtualDJ mapping
- [ ] Mixxx (a community `Numark V7.midi.xml` already exists; adapt for the
      bridge's virtual port)
- [ ] Serato — gated to supported hardware; likely out of scope
- [ ] Generic Traktor `.tsi`
