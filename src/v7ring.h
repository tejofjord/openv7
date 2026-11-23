/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — audio ring buffer + drift-corrected reader for the V7's iso-OUT.
 *
 * Portable C11, no Apple headers: the whole audio path between "CoreAudio
 * handed us floats" and "bytes in an iso packet" lives here so it can be unit
 * tested on any machine (tests/audio_test.c).
 *
 *   producer (CoreAudio IO thread)        consumer (libusb event thread)
 *   v7r_write(float x 4ch) ──► ring ──► v7r_read_s24() ──► 12-byte V7 frames
 *
 * Two clocks meet here and they are not the same clock. The producer runs on
 * whatever device we capture from (a virtual loopback device, so the host
 * clock); the consumer runs at exactly 44,100 frames per USB-second, because
 * iso_pace() hands it 5 or 6 frames per 125 us microframe. Any difference
 * between the two, however small, eventually empties or overflows a plain FIFO.
 * So the reader resamples by a ratio a hair away from the nominal one, steered
 * by how full the ring is.
 *
 * At ratio 1.0 and a whole-sample phase the resampler is an exact copy
 * (the kernel at phase 0 is a unit impulse), so when the two clocks agree the
 * path is effectively bit-transparent down to the 24-bit conversion.
 */
#ifndef OPENV7_V7RING_H
#define OPENV7_V7RING_H

#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

#define V7R_CH       4                 /* V7 output: deck A L/R, deck B L/R   */
#define V7R_CAP      16384             /* ring capacity in frames (power of 2) */
#define V7R_TAPS     32                /* windowed-sinc length                 */
#define V7R_HALF     (V7R_TAPS / 2)
#define V7R_PHASES   1024              /* kernel table resolution              */

/* Steering. Proportional only: fill error (frames) * KP = fractional rate
   correction. 100 frames of error -> 200 ppm. The loop time constant is
   1 / (44100 * KP) ~= 11 s, far slower than the fill measurement's own
   smoothing, so it cannot oscillate. Clamp keeps any correction below ~2 cents
   of pitch, which nobody can hear. */
#define V7R_KP        2e-6
#define V7R_MAX_ADJ   1e-3
#define V7R_EMA_SEC   1.0
/* No steering inside +/- this many frames of the setpoint (or a quarter of the
   target, if that is smaller -- a low-latency ring cannot afford 96 frames of
   slack). When the two clocks genuinely agree the ratio then stays exactly
   1.0 and the copy stays exact. Outside it the correction grows smoothly. */
#define V7R_DEADBAND  96.0
/* After (re)priming, watch the fill for this long without steering and take
   its average as the setpoint. The fill saw-tooths by a whole producer chunk,
   so its mean sits well below the priming level; steering against the priming
   level instead would pull the ratio off 1.0 even when the clocks agree. */
#define V7R_SETTLE_SEC 3.0

typedef struct {
    /* shared */
    float             buf[V7R_CAP * V7R_CH];
    _Atomic uint64_t  wpos;        /* frames ever written (producer-owned)          */
    _Atomic uint64_t  rel;         /* frames the consumer no longer needs (consumer) */
    _Atomic uint64_t  overruns;    /* frames the producer had to drop                */

    /* consumer only */
    uint64_t rpos;                 /* integer read position                          */
    double   frac;                 /* fractional read position, [0,1)                */
    double   base_ratio;           /* src_rate / dst_rate                            */
    double   dst_rate;
    double   adj;                  /* current correction, fraction (1e-6 = 1 ppm)    */
    double   ff;                   /* feed-forward correction, from the deck's measured rate */
    double   deadband;             /* frames, see V7R_DEADBAND                       */
    double   fill_ema;
    int      ema_init;
    double   setpoint;             /* fill the steering holds (measured, see SETTLE) */
    long     settle;               /* frames left before steering starts             */
    int      target;               /* fill right after priming, frames               */
    int      running;              /* 0 = priming (emitting silence until full)      */
    float    table[(V7R_PHASES + 1) * V7R_TAPS];

    /* consumer stats (read by --diag on the same thread) */
    uint64_t underruns, primes, skips;
    float    peak;                 /* max |sample| since last v7r_take_peak()        */
} v7ring;

/* src_rate: rate of whatever we capture from. dst_rate: 44100.
   target_frames: fill to start from after priming. It has to cover the
   producer's chunk size plus the safety margin wanted, because the fill dips by
   a whole producer chunk between deliveries. */
void   v7r_init(v7ring *r, double src_rate, double dst_rate, int target_frames);

/* Feed-forward: the rate correction the consumer's clock is KNOWN to need
   (from the deck's own feedback), so the fill-steering only has to trim what
   is left. Without it a fast deck parks the fill (drift / KP) frames below the
   setpoint -- harmless in a deep ring, an underrun in a shallow one. */
static inline void v7r_set_ff(v7ring *r, double adj) {
    if (adj >  2e-3) adj =  2e-3;
    if (adj < -2e-3) adj = -2e-3;
    r->ff = adj;
}

/* Producer. `frames` is interleaved V7R_CH-channel float. Returns frames taken
   (fewer than n only on overrun, which is counted). Wait-free. */
int    v7r_write(v7ring *r, const float *frames, int n);

/* Consumer: render n frames as S24_3LE x 4 ch (12 bytes/frame) into dst.
   Emits silence while priming or after an underrun. Wait-free. */
void   v7r_read_s24(v7ring *r, uint8_t *dst, int n);

/* Same, but float output (for tests). */
void   v7r_read_f32(v7ring *r, float *dst, int n);

/* Current fill in frames as the consumer sees it. */
double v7r_fill(const v7ring *r);

/* Peak since the previous call, in dBFS (-inf -> -200). */
double v7r_take_peak_db(v7ring *r);

/* float [-1,1] -> S24_3LE, clipped. Exposed for the tone generator + tests. */
static inline void v7r_pack_s24(uint8_t *d, float x) {
    float s = x * 8388608.0f;
    int32_t v;
    if (s >= 8388607.0f) v = 8388607;
    else if (s <= -8388608.0f) v = -8388608;
    else v = (int32_t)(s < 0 ? s - 0.5f : s + 0.5f);
    d[0] = (uint8_t)(v & 0xFF);
    d[1] = (uint8_t)((v >> 8) & 0xFF);
    d[2] = (uint8_t)((v >> 16) & 0xFF);
}

#endif /* OPENV7_V7RING_H */
