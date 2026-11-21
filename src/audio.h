/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — native audio for the V7's built-in soundcard (ROADMAP v2).
 *
 * The V7's iso-OUT endpoint carries plain interleaved S24_3LE, 4 channels
 * (deck A L/R = ch 1/2, deck B L/R = ch 3/4), 12 bytes per frame -- see
 * docs/AUDIO-CODEC.md. Until now the bridge streamed zeros there purely as a
 * clock. This module decides what goes into those bytes instead:
 *
 *   --tone          a test tone generated right here (no CoreAudio involved):
 *                   440 Hz on deck A's output, 660 Hz on deck B's. Proves the
 *                   USB audio path on its own.
 *   --audio [DEV]   whatever plays into a CoreAudio device, normally the
 *                   "Numark V7" device from driver/ (a loopback: DJ apps play
 *                   to its output, the bridge records its input). Any other
 *                   loopback device works too, e.g. "BlackHole 16ch".
 *
 * audio_render() is called on the libusb event thread right before each
 * iso-OUT URB is submitted, with exactly the frame count iso_pace() chose for
 * it, so the rate on the wire stays 44,100 Hz by construction.
 */
#ifndef OPENV7_AUDIO_H
#define OPENV7_AUDIO_H

#include <stdint.h>
#include <stddef.h>

#define AUDIO_DEFAULT_DEVICE   "com.openv7.audio.NumarkV7"   /* UID of driver/'s device */
#define AUDIO_DEFAULT_NAME     "Numark V7"
#define AUDIO_DEFAULT_LATENCY_MS 12
#define AUDIO_DEFAULT_BUFFER     256   /* CoreAudio IO buffer for the loopback input, frames */

/* Start the built-in test tone. Always succeeds. */
int  audio_open_tone(void);

/* Capture from a CoreAudio device, matched by UID, then exact name, then
   case-insensitive name prefix. `map` is 4 zero-based source channels for
   V7 ch 1..4, or NULL for the default (1,2,3,4; a stereo source feeds both
   decks). `buffer_frames` is the IO buffer asked of CoreAudio; `urb_frames`
   the most the iso side pulls at once (the ring must cover both). Returns 0 on
   success, -1 if there is no such device or it cannot be started -- the
   caller carries on with silence, so control still works. */
int  audio_open_device(const char *want, int latency_ms, int buffer_frames, int urb_frames,
                       const int *map, int verbose);

/* The deck's real playback rate in frames per second, from its feedback.
   Fed forward into the resampler so it does not have to find it by letting
   the ring drift. Call about once a second; 0 = unknown. */
void audio_set_deck_rate(double frames_per_sec);

/* 1 once a tone or device is feeding the iso stream. */
int  audio_active(void);

/* Fill `frames` x 12 bytes. Only called when audio_active(). */
void audio_render(uint8_t *dst, int frames);

/* One-line health report for --diag. */
void audio_diag(char *buf, size_t n);

void audio_close(void);

#endif /* OPENV7_AUDIO_H */
