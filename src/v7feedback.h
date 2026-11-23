/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — iso-OUT pacing from the V7's feedback endpoint (iso IN 0x81).
 *
 * The deck plays from its own 11.2896 MHz crystal (docs/HARDWARE.md), not from
 * the host's USB clock. Measured against the host it runs ~150-200 ppm fast:
 * the platter timestamp clock read 2,822,904 and 2,822,831 Hz for a nominal
 * 2,822,400, and the stock driver was captured sending 529,303 B/s for a
 * nominal 529,200. So a host that sends a perfect 44,100 frames per USB-second
 * -- what iso_pace() did -- starves the deck by ~8 frames a second. Its FIFO
 * drains, underruns, and the outputs screech until it recovers: heard as a
 * ~2 s burst of bit-crushed noise every ~20 s (first heard with --tone,
 * 2026-11-20).
 *
 * The deck tells the host what it actually played. Iso IN 0x81, the endpoint
 * the bridge used to drain and discard, carries one 3-byte packet per 1 ms
 * frame whose byte 0 is the number of frames the deck played in that
 * millisecond (44 or 45 at 44.1 kHz). The stock driver's strings name it
 * (`FEEDBACK FramePattern Locked`, `isocReadCompleteFeedback`), and the Ozzy
 * project (Marcel Bierling, MIT) documents the format for this Ploytec family,
 * V7 included -- see its common/isoc_feedback.h.
 *
 * So, like the stock driver: every OUT microframe carries exactly what the
 * deck played in one earlier microframe. Each feedback count is spread over
 * the 8 microframes of its millisecond and used exactly once, at a FIXED lag
 * behind the newest feedback. Rates then match exactly and the deck's FIFO
 * holds the level it started at, indefinitely.
 *
 * Why a fixed lag and not a ring read modulo its size: OUT packets are laid
 * out 40 at a time and feedback arrives 128 microframes at a time, so the
 * reader's position relative to the writer wobbles by ~170 microframes. Read
 * modulo the ring, a slot near the writer gets used twice or not at all as the
 * wobble crosses it, which is a random walk of the FIFO level. A fixed lag
 * bigger than the wobble uses every count exactly once.
 *
 * Portable, no I/O; single-threaded (both sides run on the libusb event
 * thread). tests/feedback_test.c simulates a fast deck against it.
 */
#ifndef OPENV7_V7FEEDBACK_H
#define OPENV7_V7FEEDBACK_H

#include <stdint.h>
#include <string.h>

#define V7FB_RING        2048   /* microframes of feedback kept (256 ms); power of two */
#define V7FB_UF_PER_PKT  8      /* one feedback packet per 1 ms = 8 microframes */
#define V7FB_PKT_LEN     3
#define V7FB_LO          42     /* plausible frames per ms at 44.1 kHz (44.1 +- 2), */
#define V7FB_HI          47     /* the range the stock driver accepts                */
#define V7FB_MARGIN      384    /* read this far behind the newest feedback (48 ms)  */
#define V7FB_RELATCH     2000   /* consecutive misses (250 ms) before re-latching    */
#define V7FB_MAX_FRAMES  6      /* per OUT packet: what the iso-OUT buffers are sized for */

typedef struct {
    uint8_t  ring[V7FB_RING];   /* frames per microframe, 0 = unknown */
    uint64_t wr;                /* feedback microframes received */
    uint64_t rd;                /* OUT microframes laid out */
    int64_t  lag;               /* OUT microframe m uses feedback microframe m - lag; 0 = not latched */
    unsigned nominal_acc;       /* 44100/8000 accumulator for when there is no feedback */
    unsigned miss_run;
    /* stats */
    uint64_t valid, bad, frames, misses, latches;
} v7fb;

static inline void v7fb_init(v7fb *f) {
    memset(f, 0, sizeof *f);
    f->nominal_acc = 4100;      /* first packet is a 72, like the capture's */
}

/* One feedback packet: `len` bytes received, `ok` = the packet's own status. */
static inline void v7fb_packet(v7fb *f, const uint8_t *p, int len, int ok) {
    int v = (ok && len == V7FB_PKT_LEN && p) ? p[0] : 0;
    int good = v >= V7FB_LO && v <= V7FB_HI;
    for (int k = 0; k < V7FB_UF_PER_PKT; k++)       /* spread over the millisecond: 44 -> 5,6,5,6,5,6,5,6 */
        f->ring[(f->wr + (uint64_t)k) & (V7FB_RING - 1)] =
            good ? (uint8_t)((v * (k + 1)) / V7FB_UF_PER_PKT - (v * k) / V7FB_UF_PER_PKT) : 0;
    f->wr += V7FB_UF_PER_PKT;
    if (good) { f->valid++; f->frames += (uint64_t)v; }
    else f->bad++;
}

/* Frames for the next OUT packet (one microframe). use_fb = 0 gives the old
   fixed 44,100/s pattern, for A/B testing. */
static inline int v7fb_next(v7fb *f, int use_fb) {
    int nominal = 5;
    f->nominal_acc += 4100;                         /* 44100 % 8000 */
    if (f->nominal_acc >= 8000) { nominal = 6; f->nominal_acc -= 8000; }
    uint64_t m = f->rd++;
    if (!use_fb || f->valid == 0) return nominal;

    if (f->lag == 0) {                              /* latch on the first usable feedback */
        f->lag = (int64_t)(m - f->wr) + V7FB_MARGIN;
        if (f->lag < V7FB_MARGIN) f->lag = V7FB_MARGIN;
        f->latches++;
        f->miss_run = 0;
    }
    int64_t j = (int64_t)m - f->lag;
    if (j < 0 || (uint64_t)j >= f->wr || f->wr - (uint64_t)j > V7FB_RING) {
        /* Feedback for that microframe is not here (yet), or already overwritten.
           A short run is startup; a long one means the IN stream lost time, so
           latch again rather than run on nominal forever. */
        f->misses++;
        if (++f->miss_run > V7FB_RELATCH) f->lag = 0;
        return nominal;
    }
    f->miss_run = 0;
    int n = f->ring[(uint64_t)j & (V7FB_RING - 1)];
    if (n == 0) return nominal;                     /* a bad packet: fill its millisecond at the nominal rate */
    return n > V7FB_MAX_FRAMES ? V7FB_MAX_FRAMES : n;
}

#endif /* OPENV7_V7FEEDBACK_H */
