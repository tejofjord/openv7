/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — Numark V7 userspace driver
 * Ploytec protocol constants for the Numark V7 (USB 15E4:0075, chip 0x33).
 *
 * All values reverse-engineered from the live device (descriptors + USB
 * traffic) and cross-referenced against the Ozzy project's Ploytec notes
 * (github.com/mischa85/Ozzy). See docs/PROTOCOL.md.
 */
#ifndef OPENV7_PLOYTEC_H
#define OPENV7_PLOYTEC_H

#include <stdint.h>

/* --- USB identity --- */
#define V7_VID              0x15E4   /* Numark */
#define V7_PID              0x0075   /* V7 */

/* --- Endpoints (from the captured config descriptor) ---
 * IF0 alt1: iso-OUT audio, bulk-IN control, bulk-OUT control
 * IF1 alt1: iso-IN audio (unused), bulk-IN audio-return
 */
#define V7_EP_AUDIO_OUT     0x02     /* iso OUT  — audio playback clock */
#define V7_EP_CTRL_IN       0x83     /* bulk IN  — control/MIDI from device */
#define V7_EP_CTRL_OUT      0x04     /* bulk OUT — control/MIDI to device (LEDs, motor) */
#define V7_EP_AUDIO_IN      0x81     /* iso IN   — audio return (unused) */
#define V7_EP_AUX_IN        0x86     /* bulk IN  — audio return (drained) */

#define V7_ISO_PKT_SIZE     156      /* wMaxPacketSize of the iso-OUT endpoint.
                                    * A CEILING, NOT A TARGET. The vendor driver never
                                    * fills it; see V7_ISO_* pacing constants below. */
#define V7_ISO_IN_PKT_SIZE  64       /* wMaxPacketSize of the iso-IN endpoint (must be drained) */

/* --- iso-OUT pacing (measured from the vendor driver, docs/AUDIO-CODEC.md) ---
 * The endpoint is serviced once per 125 us microframe (8000/s). At 44.1 kHz that
 * is 44100/8000 = 5.5125 audio frames per packet, so packet sizes alternate
 * 72 B (6 frames) / 60 B (5 frames) with an occasional extra 6 to make up the
 * fractional 0.0125. The vendor driver measures 529,303 B/s; a fixed 156 B every
 * microframe would be 1,248,000 B/s -- a 2.36x overfeed of a fixed-rate consumer.
 *
 * NOTE: a STRICT 72/60 alternation averages 5.5 frames = 44,000 Hz, which is
 * 0.23 % slow -- an order of magnitude worse than the 0.02 % the capture showed.
 * The rate is therefore held with a fractional accumulator, not by alternating.
 */
#define V7_ISO_FRAME_BYTES  12       /* 4 ch x 24-bit signed LE, interleaved (S24_3LE) */
#define V7_ISO_PKTS_PER_SEC 8000     /* one iso-OUT packet per 125 us microframe */
#define V7_ISO_FRAMES_MIN   5        /* 60 B packet */
#define V7_ISO_FRAMES_MAX   6        /* 72 B packet */
#define V7_ISO_PKT_MAX      (V7_ISO_FRAMES_MAX * V7_ISO_FRAME_BYTES)   /* 72 */
#define V7_NUM_INTERFACES   2
#define V7_ALT_SETTING      1

/* --- Ploytec vendor control requests --- */
#define PL_REQ_FIRMWARE     0x56     /* 'V' read, bmRequestType 0xC0, 15 bytes */
#define PL_REQ_STATUS       0x49     /* 'I' read (0xC0)/write (0x40), wIndex 0 */
#define PL_REQ_SET_RATE     0x01     /* SET_CUR,  bmRequestType 0x22, wValue 0x0100 */
#define PL_REQ_GET_RATE     0x81     /* GET_CUR,  bmRequestType 0xA2, wValue 0x0100 */

/* --- Stream framing --- */
#define V7_MIDI_IDLE        0xFD     /* filler byte in the control streams */
#define V7_OUT_FRAME_LEN    42       /* one MIDI message per 0xFD-padded frame */
#define V7_SAMPLE_RATE      44100

#endif /* OPENV7_PLOYTEC_H */
