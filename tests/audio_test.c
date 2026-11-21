/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — tests for the audio ring / drift-corrected reader (src/v7ring.c).
 *
 * Portable: no Apple headers, runs anywhere with a C11 compiler. `make audiotest`.
 *
 * The producer/consumer timing below is a simulation of the real thing: the
 * producer delivers CoreAudio-sized chunks (256/512 frames) on its own clock,
 * the consumer pulls one iso URB at a time (40 packets of 5 or 6 frames, paced
 * by the same 4100/8000 accumulator as iso_pace) on the USB clock.
 */
#include "../src/v7ring.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <time.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static int fails = 0;
#define CHECK(cond, ...) do { if (cond) { printf("  ok   "); printf(__VA_ARGS__); printf("\n"); } \
                              else { fails++; printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* iso_pace's accumulator, reproduced: frames per URB of g_urb packets. */
static unsigned g_acc = 4100;
static int g_urb = 40;
static int urb_frames(void) {
    int f = 0;
    for (int i = 0; i < g_urb; i++) {
        int fr = 5; g_acc += 4100;
        if (g_acc >= 8000) { fr = 6; g_acc -= 8000; }
        f += fr;
    }
    return f;
}

/* Deterministic noise in [-0.9, 0.9]. */
static uint32_t g_rng = 12345;
static float noise(void) { g_rng = g_rng * 1664525u + 1013904223u; return ((g_rng >> 8) / 16777216.0f) * 1.8f - 0.9f; }

typedef struct {
    double src_rate;      /* producer clock, frames per (simulated) second */
    int    chunk;         /* producer chunk size */
    double t_next;        /* next producer delivery time */
    long   produced;
    int    kind;          /* 0 noise, 1 sine */
    double sine_hz;
} producer;

static float *g_src_log;  /* everything the producer emitted (channel 0), for exactness */
static long   g_src_cap;

static void produce_until(v7ring *r, producer *p, double t) {
    float buf[1024 * V7R_CH];
    while (p->t_next <= t) {
        for (int i = 0; i < p->chunk; i++) {
            float v;
            if (p->kind == 0) v = noise();
            else v = (float)(0.5 * sin(2 * M_PI * p->sine_hz * (double)(p->produced + i) / p->src_rate));
            for (int c = 0; c < V7R_CH; c++) buf[i * V7R_CH + c] = c == 0 ? v : v * 0.5f;
            if (g_src_log && p->produced + i < g_src_cap) g_src_log[p->produced + i] = v;
        }
        v7r_write(r, buf, p->chunk);
        p->produced += p->chunk;
        p->t_next += p->chunk / p->src_rate;
    }
}

/* ---- 1. exact copy when the clocks agree ---- */
static void test_exact(void) {
    printf("exact copy at ratio 1.0\n");
    v7ring *r = calloc(1, sizeof *r);
    v7r_init(r, 44100, 44100, 882);
    long n_total = 44100 * 20;
    g_src_cap = n_total + 4096; g_src_log = calloc((size_t)g_src_cap, sizeof(float));
    float *out = calloc((size_t)n_total + 512, sizeof(float) * V7R_CH);
    producer p = { 44100.0, 512, 0, 0, 0, 0 };
    g_acc = 4100;
    long got = 0; double t = 0;
    while (got < n_total) {
        int f = urb_frames();
        t += f / 44100.0;               /* USB clock == producer clock here */
        produce_until(r, &p, t);
        v7r_read_f32(r, &out[got * V7R_CH], f);
        got += f;
    }
    /* Find the first output frame that matches the source exactly, then demand
       every following frame matches with a constant delay. */
    long first = -1;
    for (long i = 0; i < got; i++) if (out[i * V7R_CH] != 0.0f) { first = i; break; }
    long src0 = -1;
    for (long j = 0; j < p.produced && first >= 0; j++) if (g_src_log[j] == out[first * V7R_CH]) { src0 = j; break; }
    long mism = 0;
    for (long i = first; i >= 0 && src0 >= 0 && i < got; i++)
        if (out[i * V7R_CH] != g_src_log[src0 + (i - first)]) mism++;
    CHECK(first >= 0 && src0 >= 0, "audio arrives");
    CHECK(mism == 0, "bit-exact copy over 20 s (%ld mismatched frames)", mism);
    CHECK(r->underruns == 0 && atomic_load(&r->overruns) == 0, "no underruns (%llu) / overruns (%llu)",
          (unsigned long long)r->underruns, (unsigned long long)atomic_load(&r->overruns));
    CHECK(r->adj == 0.0, "ratio stays exactly 1.0 (adj=%g)", r->adj);
    free(out); free(g_src_log); g_src_log = NULL; free(r);
}

/* ---- 2. clock drift is absorbed ---- */
static void test_drift(double ppm, int chunk) {
    printf("drift %+g ppm, producer chunk %d\n", ppm, chunk);
    v7ring *r = calloc(1, sizeof *r);
    v7r_init(r, 44100, 44100, 882);
    producer p = { 44100.0 * (1.0 + ppm * 1e-6), chunk, 0, 0, 1, 997.0 };
    g_acc = 4100;
    double t = 0; double fmin = 1e9, fmax = -1e9, adj_sum = 0; long adj_n = 0;
    float out[300 * V7R_CH];
    for (long urb = 0; urb < 200L * 600; urb++) {         /* 10 simulated minutes */
        int f = urb_frames();
        t += f / 44100.0;
        produce_until(r, &p, t);
        v7r_read_f32(r, out, f);
        if (urb > 200L * 60) { double fl = v7r_fill(r); if (fl < fmin) fmin = fl; if (fl > fmax) fmax = fl; }
        if (urb > 200L * 540) { adj_sum += r->adj; adj_n++; }   /* average over the last minute */
    }
    r->adj = adj_sum / adj_n;
    CHECK(r->underruns == 0 && atomic_load(&r->overruns) == 0 && r->primes == 1,
          "10 min, no underrun/overrun/re-prime (u=%llu o=%llu primes=%llu)",
          (unsigned long long)r->underruns, (unsigned long long)atomic_load(&r->overruns), (unsigned long long)r->primes);
    CHECK(fabs(r->adj * 1e6 - ppm) < 5.0, "correction converged: %.1f ppm (want %.1f)", r->adj * 1e6, ppm);
    CHECK(fmin > V7R_HALF + 1 && fmax < 4000, "fill stayed bounded after settling: %.0f..%.0f frames", fmin, fmax);
    free(r);
}

/* ---- 2b. low latency: 64-frame producer, 8-packet URBs, a ~4.5 ms ring,
   a deck 90 ppm fast (as measured on the V7) -- with the feed-forward set
   from its feedback, and with it set 15 ppm wrong. ---- */
static void test_lowlat(double ff_err_ppm) {
    const double deck_ppm = 90.0;
    printf("low latency (64-frame buffer, 1 ms URBs, ~4.5 ms ring), deck +%g ppm, feed-forward off by %+g ppm\n",
           deck_ppm, ff_err_ppm);
    v7ring *r = calloc(1, sizeof *r);
    int target = (int)(2 * 44.1) + 64 + 45;            /* 2 ms + one producer chunk + one URB */
    v7r_init(r, 44100, 44100, target);
    /* the consumer (deck) runs fast, i.e. the producer is slow relative to it */
    producer p = { 44100.0 / (1.0 + deck_ppm * 1e-6), 64, 0, 0, 1, 997.0 };
    v7r_set_ff(r, (-deck_ppm + ff_err_ppm) * 1e-6);
    g_acc = 4100; g_urb = 8;
    double t = 0, fmin = 1e9; float out[64 * V7R_CH];
    for (long urb = 0; urb < 1000L * 600; urb++) {     /* 10 minutes of 1 ms URBs */
        int f = urb_frames();
        t += f / 44100.0;
        produce_until(r, &p, t);
        v7r_read_f32(r, out, f);
        if (urb > 1000L * 10) { double fl = v7r_fill(r); if (fl < fmin) fmin = fl; }
    }
    g_urb = 40;
    CHECK(r->underruns == 0 && atomic_load(&r->overruns) == 0 && r->primes == 1,
          "10 min, no underrun/overrun/re-prime (u=%llu o=%llu primes=%llu)",
          (unsigned long long)r->underruns, (unsigned long long)atomic_load(&r->overruns), (unsigned long long)r->primes);
    CHECK(fmin > V7R_HALF + 1, "fill never came near empty (min %.0f frames, need > %d)", fmin, V7R_HALF + 1);
    free(r);
}

/* ---- 3. 48 kHz source is converted, not mangled ---- */
static void test_48k(void) {
    printf("48 kHz source -> 44.1 kHz\n");
    v7ring *r = calloc(1, sizeof *r);
    v7r_init(r, 48000, 44100, 882);
    producer p = { 48000.0, 512, 0, 0, 1, 1000.0 };
    g_acc = 4100;
    long n = 44100 * 4; float *out = calloc((size_t)n + 512, sizeof(float) * V7R_CH);
    long got = 0; double t = 0;
    while (got < n) { int f = urb_frames(); t += f / 44100.0; produce_until(r, &p, t); v7r_read_f32(r, &out[got * V7R_CH], f); got += f; }
    /* measure over the last 2 s: zero crossings -> frequency, peak -> amplitude */
    long a = got - 44100 * 2, zc = 0; float pk = 0;
    for (long i = a + 1; i < got; i++) {
        if ((out[(i - 1) * V7R_CH] < 0) != (out[i * V7R_CH] < 0)) zc++;
        if (fabsf(out[i * V7R_CH]) > pk) pk = fabsf(out[i * V7R_CH]);
    }
    double hz = zc / 2.0 / 2.0;
    CHECK(fabs(hz - 1000.0) < 2.0, "1 kHz in -> %.1f Hz out", hz);
    CHECK(fabs(pk - 0.5f) < 0.01f, "amplitude preserved: %.4f (want 0.5)", pk);
    CHECK(r->underruns == 0, "no underruns (%llu)", (unsigned long long)r->underruns);
    free(out); free(r);
}

/* ---- 4. interpolation kernel: flat at the worst phase ---- */
static void test_kernel(void) {
    printf("kernel response at the half-sample phase (worst case)\n");
    v7ring *r = calloc(1, sizeof *r);
    v7r_init(r, 44100, 44100, 882);
    const float *c = &r->table[(V7R_PHASES / 2) * V7R_TAPS];
    double worst = 0; double worst_f = 0;
    double fs[] = { 100, 1000, 5000, 10000, 15000, 18000, 20000 };
    for (unsigned i = 0; i < sizeof fs / sizeof fs[0]; i++) {
        double w = 2 * M_PI * fs[i] / 44100.0, re = 0, im = 0;
        for (int k = 0; k < V7R_TAPS; k++) { re += c[k] * cos(w * k); im -= c[k] * sin(w * k); }
        double db = 20 * log10(sqrt(re * re + im * im));
        printf("       %6.0f Hz  %+.3f dB\n", fs[i], db);
        if (fs[i] <= 18000 && fabs(db) > worst) { worst = fabs(db); worst_f = fs[i]; }
    }
    CHECK(worst < 0.1, "within 0.1 dB to 18 kHz (worst %.3f dB at %.0f Hz)", worst, worst_f);
    /* phase 0 must be an exact impulse */
    int imp = 1;
    for (int k = 0; k < V7R_TAPS; k++) if (r->table[k] != (k == V7R_HALF - 1 ? 1.0f : 0.0f)) imp = 0;
    CHECK(imp, "phase 0 is an exact unit impulse");
    free(r);
}

/* ---- 5. S24 packing ---- */
static void test_pack(void) {
    printf("S24_3LE packing\n");
    uint8_t b[3];
    v7r_pack_s24(b, -0.5f); CHECK(b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xC0, "-0.5 -> 00 00 c0 (the capture's trough)");
    v7r_pack_s24(b,  1.5f); CHECK(b[0] == 0xFF && b[1] == 0xFF && b[2] == 0x7F, "+1.5 clips to 7fffff");
    v7r_pack_s24(b, -1.5f); CHECK(b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x80, "-1.5 clips to 800000");
    v7r_pack_s24(b,  0.0f); CHECK(b[0] == 0 && b[1] == 0 && b[2] == 0, "0 -> 000000");
}

/* ---- 6. producer stops, then comes back ---- */
static void test_gap(void) {
    printf("producer stops for 2 s, then resumes\n");
    v7ring *r = calloc(1, sizeof *r);
    v7r_init(r, 44100, 44100, 882);
    producer p = { 44100.0, 512, 0, 0, 1, 440.0 };
    g_acc = 4100;
    float out[300 * V7R_CH]; double t = 0; int nonzero_in_gap = 0;
    for (long urb = 0; urb < 200L * 8; urb++) {
        int f = urb_frames(); t += f / 44100.0;
        if (t < 3.0 || t > 5.0) produce_until(r, &p, t);
        else p.t_next = t + 0.0;           /* producer silent: keep its clock with the wall */
        v7r_read_f32(r, out, f);
        if (t > 3.2 && t < 4.9) for (int i = 0; i < f * V7R_CH; i++) if (out[i] != 0) nonzero_in_gap = 1;
    }
    CHECK(r->underruns == 1, "one underrun when the source stopped (%llu)", (unsigned long long)r->underruns);
    CHECK(!nonzero_in_gap, "silence (not stale audio) while the source is gone");
    CHECK(r->primes == 2 && r->running, "re-primed and running again after it came back (primes=%llu)", (unsigned long long)r->primes);
    free(r);
}


/* ---- 7. real threads: the ring is lock-free SPSC; check it under a weak
   memory model (run this on arm64) with the producer and consumer racing. ---- */
static v7ring *g_tr;
static volatile int g_tdone;
static void sleep_us(long us) { struct timespec ts = { us / 1000000, (us % 1000000) * 1000 }; nanosleep(&ts, NULL); }
static void *producer_thread(void *arg) {
    (void)arg;
    float buf[256 * V7R_CH]; float v = 1.0f;
    while (!g_tdone) {
        for (int i = 0; i < 256; i++, v += 1.0f) {           /* a counter: exact in float to 2^24 */
            if (v > 16000000.0f) v = 1.0f;
            for (int c = 0; c < V7R_CH; c++) buf[i * V7R_CH + c] = v;
        }
        int done = 0;
        while (done < 256 && !g_tdone) { done += v7r_write(g_tr, buf + done * V7R_CH, 256 - done); if (done < 256) sleep_us(200); }
        sleep_us(5805);                                      /* ~256 frames at 44.1 kHz */
    }
    return NULL;
}
static void test_threads(void) {
    printf("two threads racing (SPSC memory ordering)\n");
    g_tr = calloc(1, sizeof *g_tr);
    v7r_init(g_tr, 44100, 44100, 2048);
    g_tdone = 0;
    pthread_t th; pthread_create(&th, NULL, producer_thread, NULL);
    float out[221 * V7R_CH]; float last = -1; long breaks = 0, torn = 0, frames = 0;
    for (int urb = 0; urb < 600; urb++) {                     /* ~3 s; steering is still settling, ratio 1.0 */
        int f = urb_frames();
        v7r_read_f32(g_tr, out, f);
        for (int i = 0; i < f; i++) {
            float x = out[i * V7R_CH];
            for (int c = 1; c < V7R_CH; c++) if (out[i * V7R_CH + c] != x) torn++;
            if (x == 0.0f) { last = -1; continue; }
            if (last > 0 && x != last + 1.0f) breaks++;
            last = x; frames++;
        }
        sleep_us(5000);
    }
    g_tdone = 1; pthread_join(th, NULL);
    CHECK(frames > 44100, "streamed %ld frames", frames);
    CHECK(torn == 0, "no torn frames (%ld)", torn);
    CHECK(breaks == 0, "every frame arrives in order (breaks=%ld, underruns=%llu)",
          breaks, (unsigned long long)g_tr->underruns);
    free(g_tr);
}

int main(void) {
    test_pack();
    test_kernel();
    test_exact();
    test_drift(+100, 512);
    test_drift(-250, 256);
    test_drift(+20, 471);
    test_lowlat(0);
    test_lowlat(+15);
    test_lowlat(-15);
    test_48k();
    test_gap();
    test_threads();
    printf(fails ? "\n%d FAILED\n" : "\nall audio tests passed\n", fails);
    return fails ? 1 : 0;
}
