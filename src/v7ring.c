/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — audio ring buffer + drift-corrected reader. See v7ring.h.
 */
#include "v7ring.h"
#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define MASK (V7R_CAP - 1)

/* Kaiser shape. 7.0 keeps the passband within ~0.1 dB to 18 kHz at the worst
   (half-sample) phase with 32 taps -- measured by tests/audio_test.c, which
   fails if a change here makes it worse. */
#define V7R_KAISER_BETA 7.0

static double bessel_i0(double x) {
    double sum = 1.0, term = 1.0, q = x * x / 4.0;
    for (int k = 1; k < 64; k++) {
        term *= q / ((double)k * (double)k);
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

static void build_table(v7ring *r) {
    const double cutoff = r->base_ratio > 1.0 ? 0.97 / r->base_ratio : 1.0;
    const double i0b = bessel_i0(V7R_KAISER_BETA);
    for (int j = 0; j <= V7R_PHASES; j++) {
        const double frac = (double)j / V7R_PHASES;
        double h[V7R_TAPS], sum = 0.0;
        for (int k = 0; k < V7R_TAPS; k++) {
            double t = (double)(k - (V7R_HALF - 1)) - frac;   /* distance in source samples */
            double v;
            if (cutoff == 1.0 && fabs(t - nearbyint(t)) < 1e-12) {
                /* Whole-sample phase: exact impulse, so ratio 1.0 is a pure copy. */
                v = (nearbyint(t) == 0.0) ? 1.0 : 0.0;
            } else {
                double x = M_PI * cutoff * t;
                double sinc = (fabs(x) < 1e-12) ? 1.0 : sin(x) / x;
                double u = t / (double)V7R_HALF;
                double w = (fabs(u) >= 1.0) ? 0.0 : bessel_i0(V7R_KAISER_BETA * sqrt(1.0 - u * u)) / i0b;
                v = cutoff * sinc * w;
            }
            h[k] = v; sum += v;
        }
        for (int k = 0; k < V7R_TAPS; k++)          /* unity DC gain at every phase */
            r->table[j * V7R_TAPS + k] = (float)(h[k] / sum);
    }
}

void v7r_init(v7ring *r, double src_rate, double dst_rate, int target_frames) {
    memset(r, 0, sizeof *r);
    atomic_init(&r->wpos, 0);
    atomic_init(&r->rel, 0);
    atomic_init(&r->overruns, 0);
    r->dst_rate   = dst_rate;
    r->base_ratio = src_rate / dst_rate;
    if (target_frames < 2 * V7R_HALF) target_frames = 2 * V7R_HALF;
    if (target_frames > V7R_CAP / 2)  target_frames = V7R_CAP / 2;
    r->target = target_frames;
    r->fill_ema = r->setpoint = target_frames;
    r->deadband = target_frames / 4.0 < V7R_DEADBAND ? target_frames / 4.0 : V7R_DEADBAND;
    build_table(r);
}

int v7r_write(v7ring *r, const float *frames, int n) {
    if (n <= 0) return 0;
    uint64_t w   = atomic_load_explicit(&r->wpos, memory_order_relaxed);
    uint64_t rel = atomic_load_explicit(&r->rel,  memory_order_acquire);
    uint64_t space = V7R_CAP - (w - rel);
    if ((uint64_t)n > space) {
        atomic_fetch_add_explicit(&r->overruns, (uint64_t)n - space, memory_order_relaxed);
        n = (int)space;
    }
    for (int i = 0; i < n; i++)
        memcpy(&r->buf[((w + (uint64_t)i) & MASK) * V7R_CH], &frames[i * V7R_CH], sizeof(float) * V7R_CH);
    atomic_store_explicit(&r->wpos, w + (uint64_t)n, memory_order_release);
    return n;
}

double v7r_fill(const v7ring *r) {
    uint64_t w = atomic_load_explicit((_Atomic uint64_t *)&r->wpos, memory_order_acquire);
    return (double)(int64_t)(w - r->rpos) - r->frac;
}

double v7r_take_peak_db(v7ring *r) {
    float p = r->peak; r->peak = 0.0f;
    return p > 0.0f ? 20.0 * log10((double)p) : -200.0;
}

static void publish_release(v7ring *r) {
    uint64_t keep = r->rpos >= (uint64_t)(V7R_HALF - 1) ? r->rpos - (uint64_t)(V7R_HALF - 1) : 0;
    atomic_store_explicit(&r->rel, keep, memory_order_release);
}

/* Core: render n frames as float into out (interleaved V7R_CH). */
static void render(v7ring *r, float *out, int n) {
    uint64_t w = atomic_load_explicit(&r->wpos, memory_order_acquire);
    int i = 0;

    if (!r->running) {
        /* Prime: wait for target + the kernel's look-ahead, then start exactly
           `target` behind the write head with a whole-sample phase. */
        if (w - r->rpos >= (uint64_t)(r->target + V7R_HALF) && w >= (uint64_t)(r->target + V7R_HALF)) {
            r->rpos = w - (uint64_t)r->target;
            r->frac = 0.0;
            r->adj = 0.0;
            r->ema_init = 0;
            r->settle = (long)(r->dst_rate * V7R_SETTLE_SEC);
            r->running = 1;
            r->primes++;
        } else {
            memset(out, 0, sizeof(float) * V7R_CH * (size_t)n);
            publish_release(r);
            return;
        }
    }

    double fill = (double)(int64_t)(w - r->rpos) - r->frac;
    if (fill > (double)(r->target + V7R_CAP / 2)) {
        /* The consumer stalled long enough to fall half a ring behind. Steering
           would take minutes to drain that; jump instead. */
        r->rpos = w - (uint64_t)r->target;
        r->frac = 0.0;
        fill = r->target;
        r->ema_init = 0;
        r->settle = (long)(r->dst_rate * V7R_SETTLE_SEC);
        r->skips++;
    }

    /* Steer. The fill saw-tooths with both sides' chunk sizes, so it is
       averaged over ~1 s before it is allowed to move the ratio. */
    double alpha = (double)n / (r->dst_rate * V7R_EMA_SEC);
    if (alpha > 1.0) alpha = 1.0;
    if (!r->ema_init) { r->fill_ema = fill; r->ema_init = 1; }
    else r->fill_ema += alpha * (fill - r->fill_ema);
    double adj = 0.0;
    if (r->settle > 0) {
        r->settle -= n;
        if (r->settle <= 0) r->setpoint = r->fill_ema;
    } else {
        double err = r->fill_ema - r->setpoint;
        if (err >  r->deadband) adj = V7R_KP * (err - r->deadband);
        if (err < -r->deadband) adj = V7R_KP * (err + r->deadband);
    }
    if (adj >  V7R_MAX_ADJ) adj =  V7R_MAX_ADJ;
    if (adj < -V7R_MAX_ADJ) adj = -V7R_MAX_ADJ;
    adj += r->ff;
    r->adj = adj;
    const double ratio = r->base_ratio * (1.0 + adj);

    for (; i < n; i++) {
        if (w - r->rpos < (uint64_t)(V7R_HALF + 1)) {         /* not enough look-ahead */
            memset(&out[i * V7R_CH], 0, sizeof(float) * V7R_CH * (size_t)(n - i));
            r->running = 0;
            r->underruns++;
            break;
        }
        double p  = r->frac * V7R_PHASES;
        int    ip = (int)p;
        float  t  = (float)(p - ip);
        const float *c0 = &r->table[ip * V7R_TAPS];
        const float *c1 = c0 + V7R_TAPS;
        uint64_t base = r->rpos - (uint64_t)(V7R_HALF - 1);
        float a0 = 0, a1 = 0, a2 = 0, a3 = 0;
        for (int k = 0; k < V7R_TAPS; k++) {
            float c = c0[k] + t * (c1[k] - c0[k]);
            const float *s = &r->buf[((base + (uint64_t)k) & MASK) * V7R_CH];
            a0 += c * s[0]; a1 += c * s[1]; a2 += c * s[2]; a3 += c * s[3];
        }
        float *o = &out[i * V7R_CH];
        o[0] = a0; o[1] = a1; o[2] = a2; o[3] = a3;

        r->frac += ratio;
        uint64_t adv = (uint64_t)r->frac;
        r->rpos += adv;
        r->frac -= (double)adv;
    }
    publish_release(r);

    for (int k = 0; k < n * V7R_CH; k++) {
        float a = fabsf(out[k]);
        if (a > r->peak) r->peak = a;
    }
}

void v7r_read_f32(v7ring *r, float *dst, int n) {
    render(r, dst, n);
}

void v7r_read_s24(v7ring *r, uint8_t *dst, int n) {
    float tmp[64 * V7R_CH];
    while (n > 0) {
        int c = n > 64 ? 64 : n;
        render(r, tmp, c);
        for (int i = 0; i < c * V7R_CH; i++) v7r_pack_s24(&dst[i * 3], tmp[i]);
        dst += c * V7R_CH * 3;
        n -= c;
    }
}
