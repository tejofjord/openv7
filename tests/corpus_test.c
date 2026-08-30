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

/* Two corpora, both captured from the stock vendor driver on Windows where
   VirtualDJ has no hiccups. The second is the harder case and the one that
   matters: it was taken while VirtualDJ actually played and scratched, so it
   contains direction reversals (4.4% backwards steps) rather than steady
   rotation only. Expected counts come from a correct stream parse, cross-checked
   against tools/win/parse-control-stream.ps1.

   MAX_STEP is the largest position delta the deck genuinely produces. It exists
   to pin down the claim in docs/PROTOCOL.md that the 7-bit counter's 64-count
   ambiguity cannot fire on a host that keeps up.

   Do NOT read MAX_STEP as the deck's ceiling. Both corpora were captured with
   the MOTOR driving the platter, which is smooth and bounded; a hand spinning
   the platter is faster. Measured on real hardware (Apple Silicon, 2026-08-30,
   30 s of hand scratching, 22,137 position samples) the worst step was 35 --
   3.5x this corpus's worst, leaving only ~1.8x headroom to the 64-count
   ambiguity rather than the 6x these captures imply. Steps >= 64 were still
   zero. The margin is real but far thinner than motor-driven capture suggests.

   STARVED is the sharper regression signal, and the one that would have caught
   the frame-spanning bug immediately: frames that demonstrably ARRIVED but
   yielded no position update. Unlike a timing gap it cannot be explained away
   by the device idling or the capture pausing. The pre-fix parser swallowed
   4,035 frames on the scratching corpus; the fix swallows 10. */
struct corpus {
    const char *path; int gz;
    int frames, pos, ts, max_step, max_starved;
};
static const struct corpus CORPORA[] = {
    { "captures/usb/platter-frames.tsv",       0, 12161, 12124, 12124,  3,  4 },
    { "captures/vdj/vdj-inbound-0x83.tsv.gz",  1, 68678, 68513, 68513, 10, 10 },
};
#define AMBIGUOUS 64        /* half the 7-bit range: steps this large are undecidable */

static int grade(const struct corpus *c) {
    FILE *f;
    if (c->gz) {
        char cmd[512];
        snprintf(cmd, sizeof cmd, "gzip -dc '%s'", c->path);
        f = popen(cmd, "r");
    } else f = fopen(c->path, "r");
    if (!f) { fprintf(stderr, "corpus: cannot open %s (run from the repo root)\n", c->path); return 2; }

    struct midi_split s = {0};
    int frames = 0, spanning = 0, pos = 0, ts = 0, ambig = 0, back = 0, worst = 0;
    int since = 0, starved = 0, starve_ev = 0;
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
        frames++; since++;
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
                    int a = d < 0 ? -d : d;
                    dsum += a; dn++;
                    if (d < 0) back++;
                    if (a > worst) worst = a;
                    if (a >= AMBIGUOUS) ambig++;
                }
                /* >2 frames since the last position = the parser ate real data.
                   1-2 is ordinary: some frames carry only buttons or deck B. */
                if (last >= 0 && since > 2) { starved += since - 1; starve_ev++; }
                since = 0;
                last = out[2];
            } else if ((out[0] & 0xF0) == 0xE0) ts++;
        }
    }
    if (c->gz) pclose(f); else fclose(f);

    double mean = dn ? (double)dsum / dn : 0.0;
    printf("%s\n", c->path);
    printf("  frames                 %-6d  want %d\n", frames, c->frames);
    printf("  opening mid-message    %d (%.1f%%)\n", spanning, frames ? 100.0*spanning/frames : 0.0);
    printf("  positions (B0 00)      %-6d  want %d\n", pos, c->pos);
    printf("  timestamps (E0)        %-6d  want %d\n", ts, c->ts);
    printf("  mean |delta|           %.3f counts\n", mean);
    printf("  backwards deltas       %d (%.2f%%)\n", back, dn ? 100.0*back/dn : 0.0);
    printf("  largest step           %-6d  want <= %d\n", worst, c->max_step);
    printf("  steps >= %d (ambiguous) %-6d  want 0\n", AMBIGUOUS, ambig);
    printf("  frames swallowed       %-6d  want <= %d  (%d events)\n",
           starved, c->max_starved, starve_ev);

    int bad = 0;
    if (frames != c->frames) { printf("  FAIL: read %d frames, expected %d\n", frames, c->frames); bad = 1; }
    if (pos    != c->pos)    { printf("  FAIL: lost %d positions -- the parser is discarding real data\n", c->pos - pos); bad = 1; }
    if (ts     != c->ts)     { printf("  FAIL: lost %d timestamps -- jog velocity will be wrong\n", c->ts - ts); bad = 1; }
    if (pos    != ts)        { printf("  FAIL: %d positions but %d timestamps -- they pair 1:1 on the wire\n", pos, ts); bad = 1; }
    if (worst  > c->max_step){ printf("  FAIL: step of %d counts -- the deck does not move that fast; frames were lost\n", worst); bad = 1; }
    if (ambig  != 0)         { printf("  FAIL: %d undecidable steps -- see PROTOCOL.md, these should never occur\n", ambig); bad = 1; }
    if (starved > c->max_starved) { printf("  FAIL: %d frames arrived and produced no position -- the parser is eating data\n", starved); bad = 1; }
    puts(bad ? "  FAILED\n" : "  ok\n");
    return bad;
}

int main(void) {
    int bad = 0;
    for (size_t i = 0; i < sizeof CORPORA / sizeof *CORPORA; i++) bad |= grade(&CORPORA[i]);
    puts(bad ? "CORPUS FAILED" : "corpus ok");
    return bad != 0;
}
