/* SPDX-License-Identifier: MIT
 *
 * OpenV7 -- grade the MIDI splitter against the vendor driver's own capture.
 *
 * captures/usb/platter-frames.tsv is 12,161 real 42-byte frames lifted off the
 * wire while the STOCK Ploytec driver drove this deck under Windows, where
 * VirtualDJ has no hiccups. It is the only ground truth this project has: a
 * known-good stack handling a known-good stream.
 *
 * The unit tests in midi_test.c check hand-written vectors, which is how the
 * frame-spanning bug survived -- every vector used self-contained frames, so
 * they passed both with and without the defect. This one cannot be fooled that
 * way, because the corpus contains whatever the device actually does.
 *
 * Expected values are what a correct stream parse yields, cross-checked against
 * tools/win/parse-control-stream.ps1 on the Windows side:
 *   12124 positions, 12124 timestamps, paired 1:1, and NO position jump larger
 *   than 8 counts. At ~2 counts per frame at 1 kHz, a jump over 8 is a fault,
 *   not motion.
 *
 * Build and run with `make corpus`.
 */
#define main openv7_main_unused
#include "../src/main.c"
#undef main

#define CORPUS "captures/usb/platter-frames.tsv"
/* Measured on the reference capture; see docs/PROTOCOL.md. */
#define WANT_POS   12124
#define WANT_TS    12124
#define WANT_JUMPS 0

int main(void) {
    FILE *f = fopen(CORPUS, "r");
    if (!f) { fprintf(stderr, "corpus: cannot open %s (run from the repo root)\n", CORPUS); return 2; }

    struct midi_split s = {0};
    int frames = 0, spanning = 0, pos = 0, ts = 0, jumps = 0, back = 0;
    int last = -1;
    long dsum = 0; int dn = 0;
    char line[256];

    while (fgets(line, sizeof line, f)) {
        char *h = strrchr(line, '\t');
        if (!h) continue;
        h++;
        uint8_t fr[42];
        int ok = 1;
        for (int i = 0; i < 42; i++) {
            unsigned v;
            if (sscanf(h + 2*i, "%2x", &v) != 1) { ok = 0; break; }
            fr[i] = (uint8_t)v;
        }
        if (!ok) continue;
        frames++;
        if (!(fr[0] & 0x80)) spanning++;       /* frame opens mid-message */

        for (int i = 0; i < 42; i++) {
            uint8_t out[3];
            int n = midi_feed(&s, fr[i], out);
            if (n != 3) continue;
            if (out[0] == 0xB0 && out[1] == 0x00) {
                pos++;
                if (last >= 0) {
                    int d = out[2] - last;
                    if (d < -64) d += 128;      /* the 7-bit counter wraps */
                    if (d >  64) d -= 128;
                    dsum += (d < 0 ? -d : d); dn++;
                    if (d < 0) back++;
                    if (d > 8 || d < -8) jumps++;
                }
                last = out[2];
            } else if ((out[0] & 0xF0) == 0xE0) ts++;
        }
    }
    fclose(f);

    double mean = dn ? (double)dsum / dn : 0.0;
    printf("corpus: %s\n", CORPUS);
    printf("  frames                 %d\n", frames);
    printf("  opening mid-message    %d (%.1f%%)\n", spanning, frames ? 100.0*spanning/frames : 0.0);
    printf("  positions (B0 00)      %d   want %d\n", pos, WANT_POS);
    printf("  timestamps (E0)        %d   want %d\n", ts, WANT_TS);
    printf("  mean |delta|           %.3f counts\n", mean);
    printf("  backwards deltas       %d (%.2f%%)\n", back, dn ? 100.0*back/dn : 0.0);
    printf("  jumps > 8 counts       %d   want %d\n", jumps, WANT_JUMPS);

    int bad = 0;
    if (pos   != WANT_POS)   { printf("\nFAIL: lost %d positions -- the parser is discarding real data\n", WANT_POS - pos); bad = 1; }
    if (ts    != WANT_TS)    { printf("FAIL: lost %d timestamps -- jog velocity will be wrong\n", WANT_TS - ts); bad = 1; }
    if (pos   != ts)         { printf("FAIL: %d positions but %d timestamps -- they pair 1:1 on the wire\n", pos, ts); bad = 1; }
    if (jumps != WANT_JUMPS) { printf("FAIL: %d fabricated position jumps -- these are the audible ones\n", jumps); bad = 1; }
    puts(bad ? "\nCORPUS FAILED" : "\ncorpus ok");
    return bad;
}
