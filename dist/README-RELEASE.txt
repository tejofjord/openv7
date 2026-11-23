OpenV7 @VERSION@ -- Numark V7 driver for macOS
================================================

What's in this zip
------------------
  OpenV7-@VERSION@.dmg                          the app, ready to install
  openv7-@VERSION@-source.zip                   full source tree
  openv7-@VERSION@-changes-since-1.0.3.patch    every change since 1.0.3, one patch
  SHA256SUMS                                    checksums for the files above

Install
-------
1. Open the DMG and drag OpenV7 into Applications (replace the old one).
2. Double-click OpenV7. The build is not notarized, so macOS blocks the first
   launch: System Settings > Privacy & Security > Open Anyway, then confirm.
3. A V7 icon appears in the menu bar. Power on the V7; it shows "connected".
4. For the deck's own audio outputs: V7 menu > Install Audio Device...
   (asks for your password). Then choose "Numark V7" as the audio output in
   your DJ app: channels 1-2 = DECK A, 3-4 = DECK B. The first time, macOS asks
   whether OpenV7 may use the microphone -- say yes. That is how OpenV7 receives
   the audio for the deck; nothing is recorded.
5. In VirtualDJ, pick "Numark V7" as the controller. Start the V7 and OpenV7
   before VirtualDJ.
6. Optional: V7 menu > Audio Latency. Normal is the default; Low and Lowest
   cut the delay to the deck's outputs, Safe adds slack. If a setting
   crackles, go one step up. Lower VirtualDJ's own buffer too.

Requires macOS 13 or later on Apple Silicon.

What changed since 1.0.3
------------------------
* Audio through the V7's own outputs: a 4-channel "Numark V7" sound device.
  The USB stream is paced by the deck's rate feedback (iso IN 0x81), which
  removed the burst of crackle every ~20 s.
* Fix: the 42nd byte of every inbound control frame is not a 0x00 terminator
  -- while audio plays it carries a byte of the audio. Parsed as MIDI it made
  the platters jerk (bogus pitch, strip and button messages, ~90 a second).
  It is now dropped by position. See docs/PROTOCOL.md.
* Strip search behaves like on Windows: no jump to before the track on
  release, deck select or load; a 50 ms delay line discards the roll-off and
  bounces around a touch; mapped to VirtualDJ's V7 window (10..115). Options:
  --strip-out 1,127 for other DJ apps, --strip-raw to turn it off.
  (Run the Numark strip calibration if your strip's ends are off.)
* The audio device is installed world-readable. coreaudiod skips a plug-in
  whose files only root can read, without logging why.
* Audio latency presets in the menu-bar app (V7 menu > Audio Latency).
* New tools: dist/release.sh (this package), tools/audio-diag.sh,
  tools/latency-sweep.sh, --raw-in FILE (hex dump of the control stream).

Details: README.md, docs/AUDIO.md, docs/PROTOCOL.md, docs/CONTROL-MAP.md.
