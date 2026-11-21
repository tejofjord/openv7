/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — unit tests for the bridge's MIDI splitter.
 *
 * midi_feed() is static, so the test includes main.c directly with main()
 * renamed out of the way. Build and run with `make test`.
 *
 * Every case under "regressions" below FAILS against the parser as it stood
 * before these were written; the SysEx one is the reason they exist. An
 * identity reply -- which this device does emit -- was sized as a run of
 * 3-byte channel messages, so ten bytes on the wire became five fabricated
 * control messages delivered to CoreMIDI as if the deck had sent them.
 */
#define main openv7_main_unused
#include "../src/main.c"
#undef main


static int fails = 0;
static void expect(const char *what, const uint8_t *in, int nin,
                   const uint8_t *want, int nwant) {
    struct midi_split s = {0};
    uint8_t got[64]; int ngot = 0;
    for (int i = 0; i < nin; i++) {
        uint8_t o[3];
        int n = midi_feed(&s, in[i], o);
        for (int k = 0; k < n; k++) got[ngot++] = o[k];
    }
    int ok = (ngot == nwant) && !memcmp(got, want, nwant);
    if (!ok) {
        fails++;
        printf("  FAIL %-34s got:", what);
        for (int i = 0; i < ngot; i++) printf(" %02x", got[i]);
        printf("   want:");
        for (int i = 0; i < nwant; i++) printf(" %02x", want[i]);
        printf("\n");
    } else printf("  ok   %s\n", what);
}

/* Feed timed strip values (ms, value pairs, -1 ends) through the filter with a
   1 ms main-loop tick; collect what apps would see. Values are raw unless a
   map is set. */
static int g_sunk[256], g_nsunk;
static void sink(const uint8_t *m) { if (g_nsunk < 256) g_sunk[g_nsunk++] = m[2]; }
static void strip_run(uint8_t cc, const int *in) {
    memset(g_strip, 0, sizeof g_strip);
    g_strip_sink = sink; g_nsunk = 0;
    long t = 0;
    for (int i = 0; in[i] >= 0; i += 2) {
        while (t < in[i]) strip_tick_at(t++);
        uint8_t m[3] = {0xB0, cc, (uint8_t)in[i + 1]}, f[3]; const char *why;
        if (strip_process_at(m, 3, f, &why, t)) sink(f);
    }
    for (long end = t + 500; t < end; ) strip_tick_at(t++);
}
static void strip_case(const char *what, uint8_t cc, const int *in, const int *want) {
    strip_run(cc, in);
    int nw = 0; while (want[nw] >= 0) nw++;
    int ok = g_nsunk == nw;
    for (int i = 0; ok && i < nw; i++) ok = g_sunk[i] == want[i];
    if (!ok) {
        fails++;
        printf("  FAIL %-44s got:", what); for (int i = 0; i < g_nsunk; i++) printf(" %02x", g_sunk[i]);
        printf("   want:"); for (int i = 0; i < nw; i++) printf(" %02x", want[i]); printf("\n");
    } else printf("  ok   %s\n", what);
}
/* a steady hold: value v every 4 ms from t0 for ms */
static int *hold(int *p, int t0, int ms, int v) { for (int t = t0; t < t0 + ms; t += 4) { *p++ = t; *p++ = v; } return p; }

int main(void) {
    printf("midi_feed:\n");
    { uint8_t i[]={0x90,0x11,0x7f}, w[]={0x90,0x11,0x7f};
      expect("note-on passes through", i,3, w,3); }
    { uint8_t i[]={0x90,0x11,0x7f,0x11,0x00}, w[]={0x90,0x11,0x7f,0x90,0x11,0x00};
      expect("running status still works", i,5, w,6); }
    { uint8_t i[]={0xC0,0x05}, w[]={0xC0,0x05};
      expect("program change is 2 bytes", i,2, w,2); }
    { uint8_t i[]={0xFD,0x90,0xFD,0x11,0x7f}, w[]={0x90,0x11,0x7f};
      expect("0xFD filler is skipped", i,5, w,3); }
    { uint8_t i[]={0x90,0xF8,0x11,0x7f}, w[]={0x90,0x11,0x7f};
      expect("realtime does not break a msg", i,4, w,3); }

    puts("  -- regressions fixed by this change --");
    /* F1 is 2 bytes. Sized at 3 it swallowed the next status byte. */
    { uint8_t i[]={0xF1,0x20,0x90,0x11,0x7f}, w[]={0xF1,0x20,0x90,0x11,0x7f};
      expect("F1 (2-byte) does not eat next msg", i,5, w,5); }
    { uint8_t i[]={0xF3,0x04,0x90,0x11,0x7f}, w[]={0xF3,0x04,0x90,0x11,0x7f};
      expect("F3 (2-byte) does not eat next msg", i,5, w,5); }
    { uint8_t i[]={0xF2,0x01,0x02,0x90,0x11,0x7f}, w[]={0xF2,0x01,0x02,0x90,0x11,0x7f};
      expect("F2 (3-byte) song position",        i,6, w,6); }
    /* SysEx identity reply: dropped whole, not minced into channel messages.
       Payload bytes are 7-bit, as the spec requires. */
    { uint8_t i[]={0xF0,0x7E,0x00,0x06,0x02,0x15,0x64,0x75,0x00,0xF7,0x90,0x11,0x7f},
               w[]={0x90,0x11,0x7f};
      expect("SysEx dropped, stream resyncs",    i,13, w,3); }
    /* A status byte inside SysEx ABORTS it (MIDI 1.0). Not a hypothetical: it is
       how a bridge recovers when a SysEx is truncated on the wire. */
    { uint8_t i[]={0xF0,0x7E,0x00,0x90,0x11,0x7f}, w[]={0x90,0x11,0x7f};
      expect("status byte aborts SysEx",         i,6, w,3); }
    /* Realtime may be interleaved INSIDE SysEx and must not end it. */
    { uint8_t i[]={0xF0,0x7E,0xF8,0x00,0xF7,0x90,0x11,0x7f}, w[]={0x90,0x11,0x7f};
      expect("realtime inside SysEx is ignored", i,8, w,3); }
    /* The SysEx that was dropped above is not lost: the parser hands the whole
       clean message to its caller (s.sx / s.sxready), which forwards inbound
       ones to apps and outbound device inquiries to the deck. */
    { struct midi_split s = {0}; uint8_t o[3];
      uint8_t rep[] = {0xF0,0x00,0x01,0x3F,0x7F,0x75,0x07,0x00,0x02,0x04,0x01,0x00,0x02,0x08,
                       0x30,0x4E,0x31,0x31,0x30,0x30,0x31,0x31,0x38,0x38,0x31,0x30,0x33,0x34,0x32,0x38,0xF7};
      int ready = 0;
      for (unsigned k = 0; k < sizeof rep; k++) { midi_feed(&s, rep[k], o); if (s.sxready) ready = 1; }
      int ok = ready && s.sxlen == (int)sizeof rep && !memcmp(s.sx, rep, sizeof rep);
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "SysEx identity reply collected whole (31 bytes)"); }
    { struct midi_split s = {0}; uint8_t o[3]; int ready = 0;
      uint8_t q[] = {0xF0,0x7E,0x00,0xFD,0xFD,0xFD,0xFD,0xFD,0xFD,0xFD,0xFD,0xFD,0x00,0x06,0x01,0xF7};
      for (unsigned k = 0; k < sizeof q; k++) { midi_feed(&s, q[k], o); if (s.sxready) ready = 1; }
      uint8_t want[] = {0xF0,0x7E,0x00,0x06,0x01,0xF7};
      int ok = ready && s.sxlen == 6 && !memcmp(s.sx, want, 6) && is_device_inquiry(s.sx, s.sxlen);
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "SysEx spanning a frame boundary (filler + terminator) reassembles"); }
    { struct midi_split s = {0}; uint8_t o[3]; int ready = 0;
      uint8_t a[] = {0xF0,0x7E,0x00,0x90,0x11,0x7f};
      for (unsigned k = 0; k < sizeof a; k++) { midi_feed(&s, a[k], o); if (s.sxready) ready = 1; }
      if (ready) fails++;
      printf("  %s %s\n", !ready ? "ok  " : "FAIL", "an aborted SysEx is never handed on"); }
    { struct midi_split s = {0}; uint8_t o[3]; int ready = 0;
      uint8_t big[80]; big[0] = 0xF0; for (int k = 1; k < 79; k++) big[k] = 0x11; big[79] = 0xF7;
      for (unsigned k = 0; k < sizeof big; k++) { midi_feed(&s, big[k], o); if (s.sxready) ready = 1; }
      if (ready) fails++;
      printf("  %s %s\n", !ready ? "ok  " : "FAIL", "an over-long SysEx is dropped, not truncated"); }
    { uint8_t vendor[] = {0xF0,0x00,0x01,0x3F,0x7F,0x01,0xF7}, inq[] = {0xF0,0x7E,0x7F,0x06,0x01,0xF7};
      int ok = is_device_inquiry(inq, 6) && !is_device_inquiry(vendor, 7);
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "only the device inquiry may go to the deck"); }
    /* Running status must NOT carry across a system-common message. */
    { uint8_t i[]={0xF3,0x04,0x05}, w[]={0xF3,0x04};
      expect("no running status after sys-common", i,3, w,2); }

    puts("  -- --strip-filter (sequences verbatim from build/vdj-A.log / vdj-F.log) --");
    /* the defaults (VirtualDJ map on) are checked below; the filter cases read raw */
    { int ok = g_strip_filter == 1 && g_strip_map == 1 && strip_scale(2) == 10 && strip_scale(127) == 115;
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "default: filter on, VirtualDJ window 10..115"); }
    g_strip_filter = 1; g_strip_map = 0; g_strip_olo = g_strip_ohi = 0;
    { int s[400], *p = hold(s, 0, 200, 0x7f);       /* vdj-F 514.725: roll-off off the right end */
      int ro[] = {0x79,0x69,0x61,0x33,0x2e,0x2c,0x18,0x07,0x00};
      for (int i = 0; i < 9; i++) { *p++ = 200 + 4 * i; *p++ = ro[i]; } *p = -1;
      strip_case("release roll-off 7f 79 69 61 .. 00 -> stays 7f", 0x45, s, (int[]){0x7f,0x00,-1}); }
    { int s[400], *p = hold(s, 0, 200, 0x58); *p++ = 200; *p++ = 0x57; *p++ = 204; *p++ = 0x01; *p = -1;
      strip_case("release: 58 57 01 -> lifted",              0x45, s, (int[]){0x58,0x00,-1}); }
    { int s[400], *p = hold(s, 0, 200, 0x4d); *p++ = 200; *p++ = 0x07; *p++ = 204; *p++ = 0x01; *p++ = 500; *p++ = 0; *p = -1;
      strip_case("release transient: 4d 07 01, later 00",   0x4D, s, (int[]){0x4d,0x00,-1}); }
    strip_case("lift blips 00 5b 00 / 60 00 5f 02 00",      0x45,
               (int[]){0,0x5b, 4,0x00, 8,0x60, 12,0x00, 16,0x5f, 20,0x02, 24,0x00, -1}, (int[]){-1});
    strip_case("deck-flip dump 01 while lifted",            0x4D, (int[]){0,0x01,-1}, (int[]){-1});
    strip_case("a 36 ms touch is noise",                    0x45, (int[]){0,0x40, 12,0x40, 24,0x41, 36,0x00,-1}, (int[]){-1});
    { int s[400], *p = s; int land[] = {0x36,0x6a,0x73,0x78,0x79,0x7b,0x7d,0x7f};
      for (int i = 0; i < 8; i++) { *p++ = 4 * i; *p++ = land[i]; }
      p = hold(p, 32, 200, 0x7f); *p++ = 232; *p++ = 0; *p = -1;   /* vdj-F 430.684 */
      strip_case("landing 36 6a 73 .. 7f seeks once, settled", 0x45, s, (int[]){0x7d,0x7f,0x00,-1}); }
    strip_case("slow slide to the bottom",                  0x45,
               (int[]){0,0x06, 100,0x05, 200,0x04, 300,0x03, 400,0x02, 500,0x01,-1}, (int[]){0x06,0x05,0x04,0x03,0x02,0x00,-1});
    { int s[400], *p = hold(s, 0, 100, 0x50); *p++ = 100; *p++ = 0x10; p = hold(p, 104, 100, 0x50); *p++ = 204; *p++ = 0; *p = -1;
      strip_case("a one-sample spike while held is ignored", 0x45, s, (int[]){0x50,0x00,-1}); }
    { int s[400], *p = hold(s, 0, 100, 0x78);       /* vdj-G 77.404: a pressure dip at the far end */
      int dip[] = {0x74,0x65,0x57,0x56,0x67,0x72,0x7d};
      for (int i = 0; i < 7; i++) { *p++ = 100 + 4 * i; *p++ = dip[i]; }
      p = hold(p, 128, 100, 0x7d); *p++ = 228; *p++ = 0; *p = -1;
      strip_run(0x45, s);
      int ok = g_nsunk >= 2 && g_sunk[g_nsunk - 1] == 0;
      for (int i = 0; i < g_nsunk - 1; i++) ok &= g_sunk[i] >= 0x72;
      if (!ok) { fails++; printf("  got:"); for (int i = 0; i < g_nsunk; i++) printf(" %02x", g_sunk[i]); printf("\n"); }
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "a dip at the far end that comes straight back is skipped"); }
    { int s[400], *p = s; for (int i = 0; i < 40; i++) { *p++ = 4 * i; *p++ = 0x20 + i; } *p++ = 300; *p++ = 0; *p = -1;
      strip_run(0x45, s);
      int ok = g_nsunk >= 3 && g_sunk[g_nsunk - 2] >= 0x20 + 39 - 12 && g_sunk[g_nsunk - 1] == 0;
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "a drag follows the finger and ends where it stopped"); }
    { /* --strip-range: the physical ends map to the start and to short of the end */
      g_strip_lo = 28; g_strip_hi = 124;
      int ok = strip_scale(0x1c) == 1 && strip_scale(0x1b) == 1 && strip_scale(0x7c) == STRIP_OUT_MAX &&
               strip_scale(0x7f) == STRIP_OUT_MAX && strip_scale(76) == 62 && strip_scale(0) == 0 && strip_scale(1) == 1;
      int s[400], *p = hold(s, 0, 100, 0x7d); *p = -1; strip_run(0x45, s);
      ok &= g_nsunk == 1 && g_sunk[0] == STRIP_OUT_MAX;
      g_strip_lo = g_strip_hi = 0;
      ok &= strip_scale(0x7d) == 0x7d;
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "--strip-range maps 28..124 onto 1..124, off means raw"); }
    { /* --strip-out: a calibrated full-travel strip squeezed into VirtualDJ's window */
      g_strip_map = 1; g_strip_olo = 10; g_strip_ohi = 115;
      int ok = strip_scale(2) == 10 && strip_scale(0x7f) == 115 && strip_scale(0) == 0 && strip_scale(1) == 1 &&
               strip_scale(64) == 10 + (64 - 2) * 105 / 125;
      int s[400], *p = hold(s, 0, 100, 0x7f); *p = -1; strip_run(0x4D, s);
      ok &= g_nsunk == 1 && g_sunk[0] == 115;
      g_strip_lo = 10; g_strip_hi = 120;                 /* both ends set */
      ok &= strip_scale(10) == 10 && strip_scale(5) == 10 && strip_scale(120) == 115 && strip_scale(65) == 10 + 55 * 105 / 110;
      g_strip_map = 0; g_strip_lo = g_strip_hi = g_strip_olo = g_strip_ohi = 0;
      ok &= strip_scale(0x7f) == 0x7f;
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "--strip-out maps 2..127 onto 10..115; 00/01 stay lifted"); }
    { uint8_t f[3]; const char *why; uint8_t led[]={0xB0,0x09,0x01}, pos[]={0xB0,0x00,0x01};
      int ok = strip_process(led, 3, f, &why) == 3 && strip_process(pos, 3, f, &why) == 3 && f[2] == 0x01;
      g_strip_filter = 0;
      uint8_t one[]={0xB0,0x45,0x01};
      ok &= strip_process(one, 3, f, &why) == 3 && f[2] == 0x01;
      if (!ok) fails++;
      printf("  %s %s\n", ok ? "ok  " : "FAIL", "other CCs untouched; off means off"); }
    g_strip_sink = NULL;

    puts("  -- real 42-byte inbound frames (docs/PROTOCOL.md) --");
    /* The frame the platter actually puts on the wire, twice in a row:
         B0 00 7E | E0 71 75 | FD x35 | 00
       Two MIDI messages, 35 bytes of 0xFD filler, then a 0x00 TERMINATOR.
       Positions step 7E -> 00 between frames (+2 counts/ms at 33 1/3 RPM).

       The terminator matters: midi_feed skips only 0xFD and bytes >= 0xF8, so
       0x00 reaches the data-byte path and is absorbed as the first data byte of
       a running-status message. This asserts the absorption is harmless here --
       exactly four messages out, none fabricated, none shifted. */
    { uint8_t i[84], w[] = {0xB0,0x00,0x7E, 0xE0,0x71,0x75,
                            0xB0,0x00,0x00, 0xE0,0x1C,0x75};
      int k = 0;
      i[k++]=0xB0; i[k++]=0x00; i[k++]=0x7E; i[k++]=0xE0; i[k++]=0x71; i[k++]=0x75;
      for (int j = 0; j < 35; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      i[k++]=0xB0; i[k++]=0x00; i[k++]=0x00; i[k++]=0xE0; i[k++]=0x1C; i[k++]=0x75;
      for (int j = 0; j < 35; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      expect("two platter frames -> 4 messages", i,k, w,12); }

    puts("  -- the 42nd byte carries AUDIO while audio plays (raw-K, 2026-11-21) --");
    { /* three real frames from raw-K: deck A position + timestamp, trailer = audio byte */
      static const char *hex[] = {
        "b00011e04711fdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdf0",
        "b00010e03b3efdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfe",
        "b0000fe0333cfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfd0e" };
      uint8_t buf[126]; int len = 0;
      for (int f = 0; f < 3; f++) for (int i = 0; i < 42; i++) { unsigned v; sscanf(hex[f] + 2*i, "%2x", &v); buf[len++] = (uint8_t)v; }
      struct midi_split s = {0}; int good = 0, other = 0;
      for (int i = 0; i < len; i++) {
          if (in_frame_trailer(len, i)) { s.pad = 0; continue; }
          uint8_t o[3]; int n = midi_feed(&s, buf[i], o);
          if (n <= 0) continue;
          if ((o[0] == 0xB0 && o[1] == 0x00) || o[0] == 0xE0) good++; else other++;
      }
      int ok = good == 6 && other == 0;
      if (!ok) fails++;
      printf("  %s %s (good %d, other %d)\n", ok ? "ok  " : "FAIL", "audio in the frame trailer is dropped by position", good, other); }
    puts("  -- frame terminator must not fabricate messages --");
    /* THE JOG-JITTER BUG. A frame is <MIDI> <0xFD padding> <0x00 terminator>.
       midi_feed skipped only 0xFD, so the terminator reached the data-byte path
       and, under running status, became data[0] of a NEW message. After a
       2-byte message that COMPLETES one -- a message the deck never sent.

       Measured live against VirtualDJ: 3.39% of the platter's 0xE0 timestamps
       carried LSB 0x00 where chance predicts 0.78%, and deltas touching those
       ran backwards 31% of the time versus 1.8% for clean ones. Each fabricated
       timestamp is a bogus jog velocity, which vinyl mode turns into audible
       pitch modulation. */
    { uint8_t i[42], w[] = {0xC0,0x05};
      int k = 0;
      i[k++]=0xC0; i[k++]=0x05;
      for (int j = 0; j < 39; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      expect("2-byte msg + terminator", i,k, w,2); }

    /* Two frames that each hold COMPLETE messages. Note what this does and does
       not prove: it passes whether or not the parser resets at the boundary,
       which is exactly why it -- and every other frame test above -- missed the
       spanning bug. It was originally named "no running status across frames"
       and asserted that frames are self-contained. They are not; see the
       spanning tests below. Kept because the terminator handling is still worth
       pinning down. */
    { uint8_t i[90], w[] = {0xE0,0x71,0x75, 0xE0,0x1C,0x76};
      int k = 0;
      i[k++]=0xE0; i[k++]=0x71; i[k++]=0x75;
      for (int j = 0; j < 38; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      i[k++]=0xE0; i[k++]=0x1C; i[k++]=0x76;
      for (int j = 0; j < 38; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      expect("complete messages in adjacent frames", i,k, w,6); }

    puts("  -- messages SPAN frames (verbatim from the vendor-driver capture) --");
    /* Every frame test above uses self-contained frames, so all of them pass
       under a parser that resets state at the boundary AND under one that does
       not. They encoded the assumption instead of testing it, and the bug hid
       underneath for a month.

       These two frames are copied byte for byte out of
       captures/usb/platter-frames.tsv (rows 100-101), captured from the stock
       vendor driver. The first ENDS mid-message -- B0 00 14 then E0 1C, one
       data byte short -- and the second OPENS with that missing byte, 0x0B.
       11.7% of real frames look like this.

       Resetting the parser at the boundary drops the E0 outright and orphans
       the 0x0B, which is how 5.8% of the platter's timestamps went missing and
       where the audible position jumps came from. */
    { uint8_t i[84], w[] = {0xB0,0x00,0x14, 0xE0,0x1C,0x0B, 0xB0,0x00,0x16};
      int k = 0;
      i[k++]=0xB0; i[k++]=0x00; i[k++]=0x14; i[k++]=0xE0; i[k++]=0x1C;
      for (int j = 0; j < 36; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      i[k++]=0x0B; i[k++]=0xB0; i[k++]=0x00; i[k++]=0x16; i[k++]=0xE0; i[k++]=0x4D;
      for (int j = 0; j < 35; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      /* E0 4D is left pending on purpose: it completes in the NEXT frame. */
      expect("message spanning a frame boundary", i,k, w,9); }

    /* Running status must survive the boundary for the same reason. */
    { uint8_t i[90], w[] = {0xB0,0x00,0x14, 0xB0,0x00,0x16};
      int k = 0;
      i[k++]=0xB0; i[k++]=0x00; i[k++]=0x14;
      for (int j = 0; j < 38; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      i[k++]=0x00; i[k++]=0x16;             /* running status, no repeated B0 */
      for (int j = 0; j < 38; j++) i[k++] = 0xFD;
      i[k++]=0x00;
      expect("running status survives a frame", i,k, w,6); }

    printf(fails ? "\n%d FAILED\n" : "\nall passed\n", fails);
    return fails != 0;
}
