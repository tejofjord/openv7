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
    /* Running status must NOT carry across a system-common message. */
    { uint8_t i[]={0xF3,0x04,0x05}, w[]={0xF3,0x04};
      expect("no running status after sys-common", i,3, w,2); }

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
