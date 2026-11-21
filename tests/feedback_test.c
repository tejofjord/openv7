/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — tests for feedback-paced iso-OUT (src/v7feedback.h).
 *
 * Simulates the USB bus microframe by microframe: a deck whose crystal runs
 * fast against the host (as the V7's measurably does), a FIFO between USB and
 * its DAC, the 1 ms feedback packets it sends on 0x81, and the host's OUT and
 * IN rings with their real URB sizes and some completion jitter. The thing
 * under test is the deck's FIFO level: it must stay put for ten minutes.
 * Without feedback it must drain -- that is the bug being fixed, and the test
 * proves the simulation can see it. Portable: `make feedbacktest`.
 */
#include "../src/v7feedback.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (cond) { printf("  ok   "); printf(__VA_ARGS__); printf("\n"); } \
                              else { fails++; printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)

#define OUT_PKTS   40          /* iso-OUT URB: 40 microframes */
#define IN_PKTS    16          /* iso-IN URB: 16 x 1 ms */
#define IN_UF      (IN_PKTS * 8)
#define SCHED      (1 << 16)   /* future OUT schedule, microframes */

static uint32_t rng = 1;
static unsigned rnd(unsigned n) { rng = rng * 1664525u + 1013904223u; return (rng >> 8) % n; }

typedef struct {
    double fifo_min, fifo_max, fifo_end;
    int    underflow, max_pkt;
    v7fb   fb;
} result;

/* ppm: deck clock vs USB. depth: OUT URBs in flight. drop_in_at: seconds at
   which one IN URB's feedback is lost (<0 = never). */
static result run(double ppm, int use_fb, int depth, double seconds, double drop_in_at) {
    result R = { 1e9, -1e9, 0, 0, 0, {{0}, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0} };
    v7fb_init(&R.fb);
    static uint8_t sched[SCHED];
    memset(sched, 0, sizeof sched);

    const long total = (long)(seconds * 8000);
    const double per_uf = 44100.0 * (1.0 + ppm * 1e-6) / 8000.0;   /* deck consumption */
    long out_next = 0;         /* next OUT microframe to lay out */
    long out_due[64];          /* completion time of each in-flight OUT URB */
    int  nout = 0;
    for (int i = 0; i < depth; i++) {
        for (int k = 0; k < OUT_PKTS; k++) {
            int f = v7fb_next(&R.fb, use_fb);
            if (f > R.max_pkt) R.max_pkt = f;
            sched[(out_next + k) & (SCHED - 1)] = (uint8_t)f;
        }
        out_next += OUT_PKTS;
        out_due[nout++] = out_next + (long)rnd(40);     /* completes after its last microframe, plus jitter */
    }
    double fifo = 0, acc = 0;
    int ms_count = 0;
    uint8_t in_pkts[IN_PKTS], in_done[IN_PKTS]; int nin = 0;
    long in_due = -1;
    int playing = 0;
    int dropped = 0;

    for (long t = 0; t < total; t++) {
        /* USB delivers this microframe's OUT packet into the deck */
        fifo += sched[t & (SCHED - 1)];
        sched[t & (SCHED - 1)] = 0;
        if (!playing && fifo >= 64) playing = 1;        /* the DAC starts once there is a cushion */
        /* the DAC plays at the deck's own rate */
        if (playing) {
            acc += per_uf;
            int n = (int)acc; acc -= n;
            fifo -= n; ms_count += n;
            if (fifo < 0) { R.underflow++; fifo = 0; }
        }
        if (t > 8000L * 30) {                            /* after settling */
            if (fifo < R.fifo_min) R.fifo_min = fifo;
            if (fifo > R.fifo_max) R.fifo_max = fifo;
        }
        /* every 1 ms the deck reports what it played */
        if ((t & 7) == 7) {
            in_pkts[nin++] = (uint8_t)ms_count; ms_count = 0;
            if (nin == IN_PKTS) { memcpy(in_done, in_pkts, sizeof in_done); in_due = t + 1 + (long)rnd(80); nin = 0; }
        }
        /* host: an IN URB completes (16 ms of feedback at once) */
        if (in_due >= 0 && t >= in_due) {
            if (drop_in_at >= 0 && !dropped && t > drop_in_at * 8000) dropped = 1;   /* lost: never processed */
            else for (int i = 0; i < IN_PKTS; i++) { uint8_t p[3] = { in_done[i], 0, 0 }; v7fb_packet(&R.fb, p, 3, 1); }
            in_due = -1;
        }
        /* host: OUT URBs complete -> lay out the next one at the end of the queue */
        for (int i = 0; i < nout; i++) {
            if (t >= out_due[i]) {
                for (int k = 0; k < OUT_PKTS; k++) {
                    int f = v7fb_next(&R.fb, use_fb);
                    if (f > R.max_pkt) R.max_pkt = f;
                    sched[(out_next + k) & (SCHED - 1)] = (uint8_t)f;
                }
                out_next += OUT_PKTS;
                out_due[i] = out_next + (long)rnd(40);
            }
        }
    }
    R.fifo_end = fifo;
    return R;
}

int main(void) {
    printf("deck 195 ppm fast (as measured), OLD fixed 44.1 kHz pacing\n");
    result a = run(195, 0, 8, 120, -1);
    CHECK(a.underflow > 0, "the deck's FIFO runs dry -- the simulation reproduces the screech (%d underflowing microframes)", a.underflow);

    printf("deck 195 ppm fast, feedback pacing, 10 minutes\n");
    result b = run(195, 1, 8, 600, -1);
    CHECK(b.underflow == 0, "FIFO never runs dry (%d)", b.underflow);
    CHECK(b.fifo_max - b.fifo_min < 24, "FIFO level holds: %.0f..%.0f frames over 10 min", b.fifo_min, b.fifo_max);
    CHECK(b.fb.latches == 1, "latched once (%llu)", (unsigned long long)b.fb.latches);
    CHECK(b.max_pkt <= V7FB_MAX_FRAMES, "no packet exceeds %d frames (max %d)", V7FB_MAX_FRAMES, b.max_pkt);
    double rate = (double)b.fb.frames / ((double)b.fb.valid / 1000.0);
    CHECK(fabs(rate - 44108.6) < 1.0, "feedback reads the deck's real rate: %.1f frames/s", rate);

    printf("deck 300 ppm SLOW, feedback pacing (FIFO must not overflow either)\n");
    result c = run(-300, 1, 8, 300, -1);
    CHECK(c.underflow == 0 && c.fifo_max - c.fifo_min < 24, "FIFO level holds: %.0f..%.0f", c.fifo_min, c.fifo_max);

    printf("iso-OUT depth 16 (no-audio default) and 3 (low latency)\n");
    result d = run(195, 1, 16, 120, -1);
    CHECK(d.underflow == 0 && d.fifo_max - d.fifo_min < 24, "depth 16: %.0f..%.0f", d.fifo_min, d.fifo_max);
    result e = run(195, 1, 3, 120, -1);
    CHECK(e.underflow == 0 && e.fifo_max - e.fifo_min < 24, "depth 3: %.0f..%.0f", e.fifo_min, e.fifo_max);

    printf("one feedback URB (16 ms) lost at t=60 s\n");
    result f = run(195, 1, 8, 300, 60);
    CHECK(f.underflow == 0 && f.fifo_max - f.fifo_min < 24, "FIFO still holds: %.0f..%.0f", f.fifo_min, f.fifo_max);

    printf("bad packets are ignored\n");
    v7fb g; v7fb_init(&g);
    uint8_t junk[3] = { 200, 0, 0 }, ok[3] = { 44, 0, 0 };
    v7fb_packet(&g, junk, 3, 1); v7fb_packet(&g, ok, 2, 1); v7fb_packet(&g, ok, 3, 0);
    CHECK(g.valid == 0 && g.bad == 3, "out-of-range, short and failed packets rejected");
    v7fb_packet(&g, ok, 3, 1);
    int s44 = 0; for (int k = 0; k < 8; k++) s44 += g.ring[(24 + k) & (V7FB_RING - 1)];
    CHECK(s44 == 44, "a count of 44 is spread to exactly 44 frames over 8 microframes");

    printf(fails ? "\n%d FAILED\n" : "\nall feedback tests passed\n", fails);
    return fails ? 1 : 0;
}
