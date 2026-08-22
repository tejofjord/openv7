# Roadmap

## v1 (this release)
- [x] Ploytec bring-up (handshake + iso clock) on Apple-Silicon macOS
- [x] Control-IN → CoreMIDI virtual source
- [x] CoreMIDI virtual destination → control-OUT (LEDs, motor)
- [x] VirtualDJ starter mapping
- [ ] Confirm the full per-control MIDI map on hardware (run `openv7 --learn` and
      operate each control, or `tools/win/midi-learn.ps1` on Windows)
- [x] Confirm platter reverse — `B0 46 01`, latched while stopped (PROTOCOL.md)
- [x] Confirm the whole motor command set incl. ramp times and pitch-trim law

## v1.x — polish
- [ ] LED feedback mapping (VU meters, pad/button lights)
- [ ] Motor "follow playback" via the `B0 49/69` pitch-trim, driven from the
      DJ app's playhead where available
- [ ] `launchd` plist so the bridge auto-starts on device plug-in
- [ ] Homebrew formula

## v2 — native audio
- [ ] Decode/encode the Ploytec bit-sliced 24-bit/44.1k, 4-out codec
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
