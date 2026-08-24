/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — Numark V7 userspace driver for Apple-Silicon macOS
 *
 * Brings the Numark V7 (a proprietary Ploytec USB device, not class
 * compliant) online from userspace via libusb, then bridges its control
 * surface to a CoreMIDI virtual device so any app — VirtualDJ, Mixxx,
 * Ableton — sees a normal MIDI controller.
 *
 *   device --(bulk 0x83 MIDI)--> [OpenV7] --> CoreMIDI source "Numark V7"
 *   app    --> CoreMIDI dest "Numark V7" --> [OpenV7] --(bulk 0x04)--> device
 *
 * The isochronous OUT stream (silence) runs continuously as the audio clock;
 * the Ploytec chip only reports its controls while that clock is running.
 *
 * Audio (the V7's 4-out soundcard) is not yet exposed — use any CoreAudio
 * output in your DJ app for v1. See docs/ROADMAP.md.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/resource.h>
#include <libusb.h>
#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include "ploytec.h"

/* Defined in nonap.m — holds a LatencyCritical activity assertion so the menu-bar
   app's QoS clamp doesn't throttle the isochronous stream. */
extern void openv7_prevent_appnap(void);

/* ---- globals ---- */
static libusb_context     *g_ctx;
static libusb_device_handle *g_dev;
static MIDIClientRef        g_client;
static MIDIEndpointRef      g_source;   /* device -> apps */
static MIDIEndpointRef      g_dest;     /* apps -> device */
static volatile sig_atomic_t g_quit = 0;
static int g_stall_exit = 0;   /* exit non-zero so the supervisor relaunches */
static int g_verbose = 0;
static int g_learn   = 0;
static int g_diag    = 0;   /* --diag: print iso streaming rates once a second */
/* Control-stream keepalives: the 25 ms 0xFD frame on bulk 0x04 and the 2 s EP0
   'I' re-arm. ON by default; --no-keepalive disables them.

   HISTORY, because this flipped twice and the reasoning matters:
   The vendor driver uses NEITHER, and both were originally added to stop the
   control stream dying at ~24 s -- which looked like compensation for the 2.36x
   iso overfeed since fixed. A 120 s run with both off survived a 54 s idle, so
   they were disabled. That was over-concluded from ONE run: every test that
   "proved" it happened to touch the deck within ~10 s of arming, so none of them
   actually exercised a long cold idle before first input.

   In use the stream then intermittently delivered NOTHING from launch -- zero
   bytes even to an independent CoreMIDI listener, with a clean handshake. A
   45 s-idle A/B did not reproduce it either way, so the trigger is still
   UNKNOWN and this is defensive, not a proven fix. They cost one EP0 round trip
   per 2 s and one 42-byte frame per 25 ms, and the arm that had them ran fine,
   so the safe default is on. Do not turn this off again without a test that
   idles well past 24 s before the first input, repeated enough to catch an
   intermittent fault. */
static int g_keepalive = 1;
/* --supervised: exit when the launching parent goes away.

   The menu-bar app runs this as a child. If that app is force-quit or crashes,
   its terminate handler never runs and this process is ORPHANED -- still
   holding both USB interfaces. Every later bridge then fails to claim them
   (macOS reports LIBUSB_ERROR_ACCESS for an interface another process owns),
   which is one of the ways "sometimes the tester does not handshake on startup"
   happened: observed live here, five consecutive launches refused 3 s apart
   until the orphan died. There is no PDEATHSIG on macOS, so the child watches
   for reparenting instead: when the parent dies the kernel reparents us to
   launchd and getppid() changes.

   Opt-in, because a bare `./openv7` from a shell is legitimately orphaned by
   `nohup`/disown and must keep running. */
static int   g_supervised = 0;
static pid_t g_parent_pid = 0;

/* ---- learn mode: catalog each distinct control as it's touched ---- */
struct cat_entry { int key; uint8_t status, d0, vmin, vmax; long count; };
static struct cat_entry g_cat[256];
static int g_ncat = 0;

static const char *ctrl_label(uint8_t s, uint8_t d0) {
    switch (s & 0xF0) {
        case 0xB0:
            switch (d0) {
                case 0x00: return "jog / platter position (deck A)";
                case 0x02: return "jog / platter position (deck B)";
                case 0x43: return "motor start";   case 0x44: return "motor brake";
                case 0x45: return "RPM select";    case 0x46: return "direction";
                case 0x47: return "start-time";    case 0x48: return "brake-time";
                case 0x6e: case 0x7d: return "(idle heartbeat)";
            }
            return "CC";
        case 0xE0: return "pitch-bend (platter timestamp / pitch fader)";
        case 0x90: return "button / pad down";
        case 0x80: return "button / pad up";
    }
    return "";
}
static void learn_note(uint8_t s, uint8_t d0, uint8_t d1) {
    int key = ((s & 0xF0) == 0xE0) ? (s << 8) : ((s << 8) | d0);
    for (int i = 0; i < g_ncat; i++) if (g_cat[i].key == key) {
        if (d1 < g_cat[i].vmin) g_cat[i].vmin = d1;
        if (d1 > g_cat[i].vmax) g_cat[i].vmax = d1;
        g_cat[i].count++;
        return;
    }
    if (g_ncat < 256) {
        g_cat[g_ncat] = (struct cat_entry){ key, s, d0, d1, d1, 1 };
        g_ncat++;
        if (!(s == 0xB0 && (d0 == 0x6e || d0 == 0x7d)))   /* skip heartbeat */
            fprintf(stderr, "  NEW control:  %02x %02x   %s\n", s, d0, ctrl_label(s, d0));
    }
}
static void learn_dump(void) {
    fprintf(stderr, "\n===== control catalog: %d unique =====\n", g_ncat);
    for (int i = 0; i < g_ncat; i++)
        fprintf(stderr, "  %02x %02x  val %3u..%-3u  x%-6ld %s\n",
                g_cat[i].status, g_cat[i].d0, g_cat[i].vmin, g_cat[i].vmax,
                g_cat[i].count, ctrl_label(g_cat[i].status, g_cat[i].d0));
}

/* Packets per URB. These differ per endpoint because the two endpoints are
   serviced at different intervals:
     iso-OUT 0x02 — once per 125 us MICROFRAME (8000/s). The vendor driver uses
                    40 packets/URB, i.e. 200 URBs/s. (AUDIO-CODEC.md says
                    "~400 URBs/s", which contradicts the 529,303 B/s in its own
                    table: 400 x 2640 = 1,056,000 B/s. 200 is the self-consistent
                    figure and is what the byte rate actually implies.)
     iso-IN  0x81 — once per 1 ms FRAME (1000/s). 16 packets/URB => ~62 URBs/s,
                    which is exactly the rate --diag has always reported healthy,
                    so this one is left alone: it is measured-good as it stands. */
#define ISO_NPKT_OUT  40
#define ISO_NPKT_IN   16
/* 16 iso transfers in flight (~32 ms of queued output at 8000 packets/s), NOT 4.
   With a shallow queue any scheduling hiccup empties it, the V7 sees a gap in
   its playback clock, and it drops the whole stream — controls included — after
   a while ("goes quiet"). A deep queue absorbs the hiccups. Proven on hardware:
   4 transfers crashed iso-OUT to 0 within ~9 s under load; 16 held a steady
   500/62 indefinitely. That proof is about queue depth in TIME, not in transfer
   count: 16 x 16 packets = 32 ms. With 40-packet URBs the same 16 transfers now
   buy 80 ms, so resilience strictly increases. Latency does not matter while the
   stream is silence; shrink this to ~8 when real PCM starts being written. */
#define ISO_NXFER  16

/* ---- iso-OUT pacing ------------------------------------------------------
   Hold a true 44.1 kHz by carrying the fractional remainder rather than
   alternating 6/5 blindly (see the NOTE in ploytec.h: strict alternation is
   44,000 Hz, 0.23 % slow). Per packet: emit 5 frames, add 44100 % 8000 = 4100
   to the accumulator, and promote to 6 frames whenever it passes 8000. Over any
   80 packets this sums to exactly 441 frames = 44,100 Hz by construction.

   The accumulator is deliberately GLOBAL across all in-flight transfers: it is
   the aggregate rate on the wire that has to be 44.1 kHz, not the rate of any
   one URB. Seeded so the first packet is a 72 like the capture's. */
#define ISO_ACC_STEP  (V7_SAMPLE_RATE % V7_ISO_PKTS_PER_SEC)   /* 4100 */
static unsigned g_iso_acc = ISO_ACC_STEP;

/* Set this transfer's per-packet lengths from the accumulator and resize it to
   match. The payload stays all-zero (silence), so only the LENGTHS move. */
static void iso_pace(struct libusb_transfer *t) {
    int total = 0;
    for (int i = 0; i < t->num_iso_packets; i++) {
        int frames = V7_ISO_FRAMES_MIN;
        g_iso_acc += ISO_ACC_STEP;
        if (g_iso_acc >= V7_ISO_PKTS_PER_SEC) { frames = V7_ISO_FRAMES_MAX; g_iso_acc -= V7_ISO_PKTS_PER_SEC; }
        int len = frames * V7_ISO_FRAME_BYTES;          /* 60 or 72 */
        t->iso_packet_desc[i].length = len;
        total += len;
    }
    t->length = total;                                   /* libusb packs packets contiguously */
}

/* ---- outgoing (app -> device) frame queue ---- */
#define OUTQ 512
static unsigned char outq[OUTQ][V7_OUT_FRAME_LEN];
static volatile int  outq_head = 0, outq_tail = 0;
static pthread_mutex_t outq_mtx = PTHREAD_MUTEX_INITIALIZER;

static void outq_push(const unsigned char *msg, int len) {
    pthread_mutex_lock(&outq_mtx);
    int next = (outq_head + 1) % OUTQ;
    if (next != outq_tail) {
        memset(outq[outq_head], V7_MIDI_IDLE, V7_OUT_FRAME_LEN);
        memcpy(outq[outq_head], msg, len < V7_OUT_FRAME_LEN ? len : V7_OUT_FRAME_LEN);
        outq_head = next;
    }
    pthread_mutex_unlock(&outq_mtx);
}

/* ---- small MIDI message splitter (handles running status) ---- */
struct midi_split { uint8_t status, data[2]; int ndata, need, insysex; int pad; };

/* How many consecutive 0xFD bytes mark the END of a 42-byte frame rather than
   incidental filler. Real frames carry 35-38 of them; a lone 0xFD between two
   messages is filler and must stay transparent, which is why this is a run
   length and not "any 0xFD". */
#define FRAME_PAD_MIN 8
/* Length of a complete message INCLUDING its status byte.

   System common used to fall into the `default: return 3` below, which is wrong
   for three of the five: 0xF1 (MTC quarter frame) and 0xF3 (song select) are
   TWO bytes, so sizing them at three swallowed the byte that followed and
   shifted everything after it. 0xF0 (SysEx) has no fixed length at all and was
   the worst case -- an identity reply, which this device does emit, got chopped
   into a run of bogus 3-byte channel messages and forwarded as if it were real
   control data. */
static int midi_msg_len(uint8_t status) {
    switch (status) {
        case 0xF1: case 0xF3:                     return 2;   /* MTC qframe, song select */
        case 0xF2:                                return 3;   /* song position pointer */
        case 0xF4: case 0xF5: case 0xF6: case 0xF7: return 1; /* one-byte system common */
        default: break;
    }
    switch (status & 0xF0) {
        case 0xC0: case 0xD0: return 2;      /* status + 1 data */
        default:              return 3;      /* status + 2 data */
    }
}
/* feed one byte; when a full message completes, copy it to out[<=3] and return
 * its length, else return 0. 0xFD/idle and realtime are skipped.
 *
 * SysEx is DROPPED rather than forwarded: this bridge's outgoing framing is one
 * message per 42-byte 0xFD-padded frame, which has nowhere to put a message of
 * arbitrary length. Dropping it is a deliberate limitation; mangling it into
 * fake channel messages, which is what happened before, is a bug. */
static int midi_feed(struct midi_split *s, uint8_t x, uint8_t out[3]) {
    if (x == V7_MIDI_IDLE) { if (s->pad < FRAME_PAD_MIN) s->pad++; return 0; }
    /* End of a frame. The byte after a long 0xFD run is the frame TERMINATOR
       (0x00 inbound, docs/PROTOCOL.md) -- part of the container, not MIDI.
       Letting it reach the data-byte path is what fabricated a whole extra
       message after every 2-byte one, and put a bogus 0x00-LSB timestamp into
       the platter stream 3.4% of the time. Frames are self-contained, so
       running status is dropped at the boundary too: a data byte at the start
       of a frame belongs to no previous message. */
    if (s->pad >= FRAME_PAD_MIN) {
        s->pad = 0; s->status = 0; s->ndata = 0; s->insysex = 0;
        if (x == 0x00) return 0;             /* swallow the terminator */
        /* Anything else is already the next frame's first byte -- parse it. */
    }
    s->pad = 0;
    if (x >= 0xF8) return 0;                 /* system realtime — ignore, running status survives */
    if (x & 0x80) {
        if (x == 0xF0) { s->insysex = 1; s->status = 0; return 0; }
        if (x == 0xF7) { s->insysex = 0; s->status = 0; return 0; }
        s->insysex = 0;
        s->need = midi_msg_len(x);
        if (s->need == 1) { s->status = 0; out[0] = x; out[1] = out[2] = 0; return 1; }
        s->status = x; s->ndata = 0;
        return 0;
    }
    if (s->insysex) return 0;                /* SysEx payload — see above */
    if (!s->status) return 0;
    s->data[s->ndata++] = x;
    if (s->ndata >= s->need - 1) {
        out[0] = s->status;
        out[1] = s->data[0];
        int n = s->need;
        if (n == 3) out[2] = s->data[1];
        s->ndata = 0;                        /* running status stays armed */
        /* ...for CHANNEL messages only. Running status does not apply to system
           common, so a bare data byte after one must not repeat it. */
        if (s->status >= 0xF0) s->status = 0;
        return n;
    }
    return 0;
}

/* ---- CoreMIDI: send a decoded message device -> apps ---- */
static void midi_to_apps(const uint8_t *msg, int len) {
    Byte buf[64];
    MIDIPacketList *pl = (MIDIPacketList *)buf;
    MIDIPacket *p = MIDIPacketListInit(pl);
    p = MIDIPacketListAdd(pl, sizeof(buf), p, 0, len, msg);
    if (p) MIDIReceived(g_source, pl);
}

/* Batched variant: build one packet list across a whole transfer, flush once. */
static Byte g_pkt_buf[4096];
static MIDIPacketList *g_pl;
static MIDIPacket *g_pkt;
static int g_pkt_n;

static void batch_begin(void) {
    g_pl = (MIDIPacketList *)g_pkt_buf;
    g_pkt = MIDIPacketListInit(g_pl);
    g_pkt_n = 0;
}
static void batch_add(const uint8_t *msg, int len) {
    MIDIPacket *p = MIDIPacketListAdd(g_pl, sizeof g_pkt_buf, g_pkt, 0, len, msg);
    if (!p) { if (g_pkt_n) MIDIReceived(g_source, g_pl); batch_begin();   /* full: flush and restart */
              p = MIDIPacketListAdd(g_pl, sizeof g_pkt_buf, g_pkt, 0, len, msg); }
    if (p) { g_pkt = p; g_pkt_n++; }
}
static void batch_flush(void) { if (g_pkt_n) MIDIReceived(g_source, g_pl); g_pkt_n = 0; }

/* ---- CoreMIDI: receive from apps -> queue for the device ---- */
static void dest_read(const MIDIPacketList *pl, void *refCon, void *srcRefCon) {
    (void)refCon; (void)srcRefCon;
    const MIDIPacket *p = &pl->packet[0];
    for (unsigned i = 0; i < pl->numPackets; i++) {
        struct midi_split s = {0}; uint8_t out[3];
        for (unsigned j = 0; j < p->length; j++) {
            int n = midi_feed(&s, p->data[j], out);
            if (n > 0) {
                outq_push(out, n);
                /* App -> device was completely unlogged, so "the DJ app pressed
                   play and the platter did not spin" had no evidence either way:
                   nothing showed whether the app had sent a motor command at
                   all. Inbound has had -v since the beginning; this is its twin. */
                if (g_verbose) {
                    fprintf(stderr, "  out ");
                    for (int k = 0; k < n; k++) fprintf(stderr, "%02x ", out[k]);
                    fprintf(stderr, "%s\n", ctrl_label(out[0], out[1]));
                }
            }
        }
        p = MIDIPacketNext(p);
    }
}

/* ---- USB: Ploytec handshake (arms the device for streaming) ---- */
static int ctrl(uint8_t rt, uint8_t rq, uint16_t v, uint16_t ix, unsigned char *b, uint16_t l) {
    return libusb_control_transfer(g_dev, rt, rq, v, ix, b, l, 2000);
}
static const char *hs_err(int r) { return r < 0 ? libusb_error_name(r) : "short reply"; }

/* Arm the device for streaming.

   EVERY step is checked. It used to check only the firmware read and then
   return 0 unconditionally, discarding the result of all six remaining
   requests -- so "handshake complete, device armed" was printed whether or not
   the device had actually been armed. Worse, a failed final status read fell
   back to `st = 0` and armed from that FABRICATED value rather than the
   device's real status, silently writing a wrong arm word.

   That is the second half of "sometimes the tester does not handshake properly
   on startup": when it did fail, the log claimed success, so the failure was
   invisible and the session simply streamed nothing. Failing here instead
   returns non-zero from main, the supervisor relaunches a few seconds later,
   and the reason is in the log. */
static int ploytec_handshake(void) {
    unsigned char b[16]; int r;

    r = ctrl(0xC0, PL_REQ_FIRMWARE, 0, 0, b, 15);
    if (r < 3) { fprintf(stderr, "OpenV7: firmware read failed (%s)\n", hs_err(r)); return -1; }
    fprintf(stderr, "  V7 firmware: chip 0x%02X\n", b[0]);

    r = ctrl(0xC0, PL_REQ_STATUS, 0, 0, b, 1);        /* status read */
    if (r < 1) { fprintf(stderr, "OpenV7: status read failed (%s)\n", hs_err(r)); return -1; }

    r = ctrl(0xA2, PL_REQ_GET_RATE, 0x0100, 0, b, 3); /* GET_CUR rate */
    if (r < 0) { fprintf(stderr, "OpenV7: sample-rate GET_CUR failed (%s)\n", hs_err(r)); return -1; }

    unsigned char rate[3] = { V7_SAMPLE_RATE & 0xFF, (V7_SAMPLE_RATE >> 8) & 0xFF, (V7_SAMPLE_RATE >> 16) & 0xFF };
    uint16_t reps[] = { 0x0086, V7_EP_AUDIO_OUT, V7_EP_AUDIO_IN, 0x0005 };
    for (unsigned i = 0; i < 4; i++) {
        r = ctrl(0x22, PL_REQ_SET_RATE, 0x0100, reps[i], rate, 3);
        if (r < 0) { fprintf(stderr, "OpenV7: sample-rate SET_CUR on 0x%02X failed (%s)\n",
                             reps[i], hs_err(r)); return -1; }
    }

    r = ctrl(0xC0, PL_REQ_STATUS, 0, 0, b, 1);        /* re-read status */
    if (r < 1) { fprintf(stderr, "OpenV7: status re-read failed (%s)\n", hs_err(r)); return -1; }
    int8_t mod = (int8_t)(b[0] | 0x20);               /* arm: bit5 set, sign-extended */
    r = ctrl(0x40, PL_REQ_STATUS, (uint16_t)(int16_t)mod, 0, NULL, 0);
    if (r < 0) { fprintf(stderr, "OpenV7: arm write failed (%s)\n", hs_err(r)); return -1; }
    return 0;
}
/* Re-arm the control stream. The V7 has a watchdog: it silently STOPS reporting
   controls on bulk 0x83 (~24 s after arming) unless the 'I' status is re-read AND
   re-armed periodically — even while the iso audio clock stays perfectly healthy.
   BOTH steps are required (read-only or a cached write both fail on hardware).
   Proven: without it the platter/button stream dies at ~24 s; with a re-arm every
   2 s it streams indefinitely (5 min, zero dropouts).

   This MUST be asynchronous. A synchronous libusb_control_transfer runs its own
   nested event loop and, in the menu-bar app's throttled launch context, blocks
   long enough to starve the iso stream and kill it. Async control transfers are
   serviced by the main loop's handle_events and never block. */
static void LIBUSB_CALL ka_write_cb(struct libusb_transfer *t) {
    free(t->buffer); libusb_free_transfer(t);
}
static void LIBUSB_CALL ka_read_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length >= 1) {
        uint8_t status = libusb_control_transfer_get_data(t)[0];
        int8_t mod = (int8_t)(status | 0x20);
        unsigned char *wb = malloc(LIBUSB_CONTROL_SETUP_SIZE);
        if (!wb) { free(t->buffer); libusb_free_transfer(t); return; }
        libusb_fill_control_setup(wb, 0x40, PL_REQ_STATUS, (uint16_t)(int16_t)mod, 0, 0);
        struct libusb_transfer *wt = libusb_alloc_transfer(0);
        if (!wt) { free(wb); free(t->buffer); libusb_free_transfer(t); return; }
        libusb_fill_control_transfer(wt, g_dev, wb, ka_write_cb, NULL, 500);
        if (libusb_submit_transfer(wt) != 0) { free(wb); libusb_free_transfer(wt); }
    }
    free(t->buffer); libusb_free_transfer(t);
}
static void ploytec_rearm(void) {
    unsigned char *rb = malloc(LIBUSB_CONTROL_SETUP_SIZE + 1);
    if (!rb) return;
    libusb_fill_control_setup(rb, 0xC0, PL_REQ_STATUS, 0, 0, 1);
    struct libusb_transfer *rt = libusb_alloc_transfer(0);
    if (!rt) { free(rb); return; }
    libusb_fill_control_transfer(rt, g_dev, rb, ka_read_cb, NULL, 500);
    if (libusb_submit_transfer(rt) != 0) { free(rb); libusb_free_transfer(rt); }
}

/* Clear a stalled endpoint without blocking the event thread.

   All three call sites for this run from inside a transfer callback -- i.e. on
   the thread currently executing libusb_handle_events. Calling the SYNCHRONOUS
   libusb_clear_halt() there is the hazard the ploytec_rearm comment above
   describes: a synchronous transfer runs its own nested event loop and stops
   servicing the iso ring while it waits. Stalls are rare, so this never
   surfaced, but the one moment it fires is a moment the stream is already
   unhealthy -- the worst possible time to stall the pump holding up the
   44.1 kHz clock.

   The fix is to DEFER the same call, not to replace it. An async
   CLEAR_FEATURE(ENDPOINT_HALT) control transfer looks equivalent and is not:
   on macOS libusb_clear_halt goes to ClearPipeStallBothEnds(), which clears the
   HOST side of the pipe and resets the data toggle as well as sending the
   request to the device. Sending only the device half leaves the host pipe
   stalled, so every following transfer fails LIBUSB_ERROR_PIPE and the retry
   path spins -- worse than the blocking call it was meant to improve on.

   So: callbacks queue an endpoint here, and the main loop drains the queue
   between handle_events calls, where blocking is harmless. */
#define CLEAR_MAX 8
static unsigned char g_clear_q[CLEAR_MAX];
static int g_nclear = 0;
static long now_ms(void);
/* Stall detection, third attempt -- the first two failed for instructive reasons.
   A continuous run of submit failures never materialises (clear_halt "succeeds",
   the next submit succeeds, the transfer then completes stalled). And counting
   stalls alone needs a threshold, which needs the rate: measured, it is about
   TWO per second, so any window/threshold pair tuned for a fast failure never
   fires.

   What is unambiguous is the CONJUNCTION: stalls are occurring AND no control
   data has arrived for several seconds. Neither half alone is safe -- an idle V7
   legitimately sends nothing for minutes (docs/PROTOCOL.md), so silence by
   itself must never trigger a reset. */
static long g_pipe_win_ms;             /* start of the current stall window */
static int  g_pipe_hits;               /* stalls seen inside it */
static long g_last_data_ms;            /* last control-IN completion WITH data */
#define STALL_WINDOW_MS  5000
#define STALL_HITS       3             /* more than a one-off blip */
#define STALL_QUIET_MS   4000          /* ...and nothing has arrived meanwhile */

static void clear_halt_later(unsigned char ep) {
    /* Count EVERY stall here, whichever path found it. Counting submit failures
       alone missed the fault entirely: a stalled pipe often submits fine and
       then COMPLETES with LIBUSB_TRANSFER_STALL, so arm_bulk saw nothing wrong
       while no data moved at all. Both paths call this function. */
    long now = now_ms();
    if (!g_pipe_win_ms || now - g_pipe_win_ms > STALL_WINDOW_MS) { g_pipe_win_ms = now; g_pipe_hits = 0; }
    g_pipe_hits++;

    for (int i = 0; i < g_nclear; i++) if (g_clear_q[i] == ep) return;   /* already queued */
    if (g_nclear < CLEAR_MAX) g_clear_q[g_nclear++] = ep;
}

/* bulk-IN watchdog state (definition of arm_bulk is further down)

   The control pipe uses a RING of transfers, not one. With a single transfer
   there is a window between completion and resubmission in which nothing is
   armed on 0x83, and whatever the device sends during it is lost. That showed
   up as a one-byte shift in the MIDI stream: a capture of the BLEEP switch,
   whose bounce bursts hard, produced "90 00 1c" in the middle of a run of
   "90 1c 7f"/"90 1c 00" -- the pairing slipped because one 1c went missing.
   Keeping several transfers queued means the endpoint is always armed. */
/* Overridable at build time so the queue depth can be A/B tested against the
   jog-timestamp ordering measurement (tools: --diag-jog). */
#ifndef CTRL_IN_NXFER
#define CTRL_IN_NXFER 4
#endif
static struct libusb_transfer *g_t_in[CTRL_IN_NXFER];

/* A libusb error that means "this handle is dead", not "try again".

   ROOT CAUSE of "the V7 shows connected but nothing ever arrives, and only a
   restart fixes it". arm_bulk() retried EVERY submit failure forever, including
   LIBUSB_ERROR_NO_DEVICE -- which is returned once the device has left the bus,
   and is never transient: the handle names an enumeration that no longer
   exists, so no amount of retrying can revive it. Unplugging the V7 therefore
   WEDGED the bridge instead of ending it. Measured on this machine after an
   11-hour unplug: 37,946 retry lines, 2.7 MB of log, 5m36s of CPU, with the
   process still "running", its stale CoreMIDI endpoint still published, and the
   menu bar still green.

   Because the supervising app only relaunches the bridge when the PROCESS
   exits, that wedged bridge was never replaced -- so on replug the device was
   never re-opened and never re-handshaked, which is what "sometimes the tester
   does not handshake on startup" actually was. Exiting here is the whole fix:
   the supervisor sees the exit, relaunches, and the fresh process runs the full
   handshake against the new enumeration. */
static int usb_gone(int err) {
    return err == LIBUSB_ERROR_NO_DEVICE || err == LIBUSB_ERROR_NOT_FOUND;
}
static void usb_lost(int err, const char *name) {
    fprintf(stderr, "OpenV7: device disconnected (%s on %s) — exiting so it is "
                    "re-opened and re-handshaked on replug.\n", libusb_error_name(err), name);
    g_quit = 1;
}

/* Runs on the main loop, never in a callback -- see clear_halt_later. */
static void clear_halt_drain(void) {
    for (int i = 0; i < g_nclear; i++) {
        int r = libusb_clear_halt(g_dev, g_clear_q[i]);
        if (r == 0) continue;
        if (usb_gone(r)) { usb_lost(r, "clear-halt"); break; }
        fprintf(stderr, "OpenV7: clear-halt on 0x%02X failed (%s)\n",
                g_clear_q[i], libusb_error_name(r));
    }
    g_nclear = 0;
}

static struct libusb_transfer *g_t_aux = NULL;
static int g_in_live[CTRL_IN_NXFER];
static int g_aux_live = 0;
static long g_ctrl_bytes = 0;          /* control-IN traffic, for --diag */

/* Stall detection. A stalled control-IN pipe used to be permanent: arm_bulk
   retries forever, clear_halt reports success without fixing anything, and the
   process stays up -- so the menu bar keeps saying "connected" while not one
   MIDI byte flows. Seen 323 times in a single launch.

   The signal is a CONTINUOUS run of PIPE submit failures, not silence: an idle
   V7 legitimately sends nothing at all (docs/PROTOCOL.md -- 10 minutes of idle
   produced zero messages), so "no data" must never trigger recovery.

   Recovery is a USB port reset followed by a FRESH process. src/main.c used to
   warn that libusb_reset_device leaves the platter encoder un-armed; measured
   again on a wedged device, a reset plus a new bring-up restored it completely
   -- 0 PIPE errors and ~907 platter frames/s. The reset invalidates this
   handle, so exit and let the supervisor relaunch rather than carrying on. */
/* Counted over a WINDOW, not as an unbroken run. The first version of this
   tracked a continuous streak and never once fired, because a stalled pipe does
   not fail cleanly: clear_halt reports success, the next submit succeeds, the
   transfer then COMPLETES stalled, and round it goes. A submit succeeds inside
   every couple of seconds, which reset the streak forever. Rate is the honest
   signal -- a healthy bridge produces zero of these. */

static long now_ms(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000L + tv.tv_usec / 1000;
}
/* Last-complained-at, one clock PER ENDPOINT. A single shared static meant a
   persistently failing pipe griped once a second and silenced every OTHER
   pipe's message for that same second -- so a second endpoint failing at the
   same time was invisible in the log, which is precisely when you most need to
   see both. */
static time_t g_gripe_ctrl_in, g_gripe_aux, g_gripe_iso_out, g_gripe_iso_in;
static void arm_bulk(struct libusb_transfer *t, int *live, unsigned char ep,
                     const char *name, time_t *gripe);

/* iso rings, kept addressable so the main loop can re-arm them (see arm_iso) */
static struct libusb_transfer *g_iso_out[ISO_NXFER], *g_iso_in[ISO_NXFER];
static int g_iso_out_live[ISO_NXFER], g_iso_in_live[ISO_NXFER];
static void arm_iso(struct libusb_transfer *t, int *live, int pace, const char *name, time_t *gripe);

/* ---- streaming-health counters (for the --diag rate report) ---- */
static long g_isoout_cmpl = 0, g_isoin_cmpl = 0;

/* ---- USB transfer callbacks ---- */
static void LIBUSB_CALL iso_cb(struct libusb_transfer *t) {
    int idx = (int)(intptr_t)t->user_data;
    g_iso_out_live[idx] = 0;                                   /* no longer in flight */
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { usb_lost(LIBUSB_ERROR_NO_DEVICE, "iso-out"); return; }
    g_isoout_cmpl++;
    /* Re-pace before every resubmit: the packet lengths are what hold 44.1 kHz,
       and the accumulator has to keep advancing across resubmissions or the
       fractional 0.0125 frame/packet is lost and the stream drifts slow.
       arm_iso does the pacing and, unlike the bare submit this replaces, CHECKS
       the result -- the silence buffer is already zero, only lengths move. */
    arm_iso(t, &g_iso_out_live[idx], 1, "iso-out", &g_gripe_iso_out);
}
static void LIBUSB_CALL drain_cb(struct libusb_transfer *t) {
    g_aux_live = 0;
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }
    if (t->status == LIBUSB_TRANSFER_STALL) clear_halt_later(V7_EP_AUX_IN);
    if (!g_quit) arm_bulk(t, &g_aux_live, V7_EP_AUX_IN, "aux-drain", &g_gripe_aux);  /* discard audio-return */
}
static void LIBUSB_CALL isoin_cb(struct libusb_transfer *t) {
    int idx = (int)(intptr_t)t->user_data;
    g_iso_in_live[idx] = 0;
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { usb_lost(LIBUSB_ERROR_NO_DEVICE, "iso-in"); return; }
    g_isoin_cmpl++;
    arm_iso(t, &g_iso_in_live[idx], 0, "iso-in", &g_gripe_iso_in);  /* drain iso-IN — REQUIRED or the
                                                         device stalls its control stream */
}
static void LIBUSB_CALL out_cb(struct libusb_transfer *t) {
    free(t->buffer);
    libusb_free_transfer(t);
}
static struct midi_split g_in;                        /* device-side parser state */
/* ---- --diag-jog: is the platter's timestamp stream actually smooth? --------
   PURELY OBSERVATIONAL. Nothing here changes a byte that reaches the app; it
   exists to settle a question that cannot be settled by reading code.

   The platter sends a position CC paired 1:1 with an 0xE0 pitch-bend carrying a
   timestamp off a 2,822,400 Hz clock (44100 x 64 -- see docs/PROTOCOL.md). A
   host that scratches from this stream computes velocity as position-delta over
   TIMESTAMP-delta, so three separate things can each make that velocity noisy,
   and they call for completely different fixes:

     1. the device's own clock is uneven      -> dt spread is wide
     2. we are dropping or reordering frames  -> e0/s and pos/s stop matching
     3. the device is fine but WE deliver in  -> dt spread is tight while the
        clumps                                   host inter-arrival spread is wide

   So measure all three at once: the device's timestamp delta, the pairing
   count, and the wall-clock gap between arrivals as seen from this process. */
static int g_diag_jog = 0;

/* The platter's 0xE0 timestamps ARE forwarded, and must be: VirtualDJ's native
   V7 mapping drives the jog from them, not from the position CC. Proven live --
   suppressing them silences the jog completely while CC 0x00 keeps streaming at
   ~968/s.

   They were briefly suppressed here on the theory that a DJ app was binding
   them as literal pitch bend. That theory was wrong, and the experiment that
   appeared to confirm it was confounded: suppressing them required restarting
   the bridge, which tore down the CoreMIDI endpoint, and an app that has lost
   its controller sounds exactly like an app whose jitter is fixed.

   The real fault was ours and upstream of all of this -- see FRAME_PAD_MIN in
   midi_feed. The frame terminator was being parsed as MIDI, fabricating a
   bogus-timestamp 0xE0 message 3.4% of the time (chance: 0.78%), and each one
   is a wrong jog velocity. With that fixed the rate is 0.79% and backwards
   timestamp deltas fell from 1.83% to 0.36%.

   --no-timestamps still suppresses them, because it is the fastest way to tell
   a jog fault from a timestamp fault on any app. */
static int g_send_timestamps = 1;

/* SIGUSR1 toggles the filter AT RUNTIME. This exists because testing it by
   restarting the bridge is not a valid experiment: a restart tears down the
   CoreMIDI source, and a DJ app that loses its controller mid-session goes
   quiet whether or not the filter did anything. The first attempt at this A/B
   produced "the audio is perfect now" from an app that had simply stopped
   receiving. Toggling in place keeps the endpoint, the app's binding and the
   audio stream all untouched, so the only thing that changes is the one thing
   under test.
     kill -USR1 $(pgrep -f openv7) */
static volatile sig_atomic_t g_toggle_ts = 0;
static void on_sigusr1(int sig) { (void)sig; g_toggle_ts = 1; }

/* Deliver every message decoded from ONE USB transfer in a SINGLE
   MIDIPacketList, instead of one list per message.

   On the wire the platter's position and its 0xE0 timestamp are two messages
   inside the SAME 42-byte frame -- they are one event, split across two MIDI
   messages by the protocol. midi_to_apps has always sent one MIDIPacketList per
   message, so that atomic pair reaches the app as two separate deliveries. A
   host that pairs a position with the timestamp it arrived WITH would mis-pair
   them, and a mis-paired timestamp is a wrong velocity, which in vinyl mode is
   a wrong playback speed.

   SIGUSR2 toggles it, for the same reason SIGUSR1 exists: the comparison is
   only valid if the app never loses the endpoint.
     kill -USR2 $(pgrep -f openv7) */
static int g_batch_frame = 0;
static volatile sig_atomic_t g_toggle_batch = 0;
static void on_sigusr2(int sig) { (void)sig; g_toggle_batch = 1; }

/* Should this decoded message go to CoreMIDI at all? Split out so it is
   testable: the filter is a claim about the protocol, and claims get tests. */
static int forward_to_apps(const uint8_t *msg) {
    if (!g_send_timestamps && (msg[0] & 0xF0) == 0xE0) return 0;   /* platter timestamp */
    return 1;
}

static long     g_jog_n, g_jog_pos_n;          /* 0xE0s and paired position CCs  */
static int      g_jog_have;                    /* seen a first 0xE0 to diff from */
static unsigned g_jog_prev;                    /* previous 14-bit timestamp      */
static long     g_jog_dsum; static unsigned g_jog_dmin, g_jog_dmax;   /* clock units */
static long     g_jog_hsum; static long g_jog_hmin, g_jog_hmax;       /* host us     */
static long     g_jog_hprev;

static long now_us(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000000L + tv.tv_usec;
}

static void jog_stat(const uint8_t *m, int n) {
    if (n < 3) return;
    /* Position CCs: 0x00 is deck A, 0x02 deck B (docs/CONTROL-MAP.md). Counted
       only to check the 1:1 pairing survives our own parser. */
    if ((m[0] & 0xF0) == 0xB0 && (m[1] == 0x00 || m[1] == 0x02)) { g_jog_pos_n++; return; }
    if ((m[0] & 0xF0) != 0xE0) return;

    unsigned v = (unsigned)m[1] | ((unsigned)m[2] << 7);   /* 14-bit, LSB first */
    long h = now_us();
    if (g_jog_have) {
        unsigned d = (v - g_jog_prev) & 0x3FFF;   /* the counter wraps every 16384 */
        long hd = h - g_jog_hprev;
        if (g_jog_n == 0) { g_jog_dmin = g_jog_dmax = d; g_jog_hmin = g_jog_hmax = hd; }
        else {
            if (d  < g_jog_dmin) g_jog_dmin = d;   if (d  > g_jog_dmax) g_jog_dmax = d;
            if (hd < g_jog_hmin) g_jog_hmin = hd;  if (hd > g_jog_hmax) g_jog_hmax = hd;
        }
        g_jog_dsum += d; g_jog_hsum += hd; g_jog_n++;
    }
    g_jog_prev = v; g_jog_hprev = h; g_jog_have = 1;
}

static void LIBUSB_CALL ctrl_in_cb(struct libusb_transfer *t) {
    int idx = (int)(intptr_t)t->user_data;
    g_in_live[idx] = 0;                                /* no longer in flight */
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        g_ctrl_bytes += t->actual_length;
        if (t->actual_length > 0) g_last_data_ms = now_ms();   /* the pipe is genuinely alive */
        uint8_t out[3];
        if (g_batch_frame) batch_begin();
        for (int i = 0; i < t->actual_length; i++) {
            int n = midi_feed(&g_in, t->buffer[i], out);
            if (n > 0) {
                if (forward_to_apps(out)) {
                    if (g_batch_frame) batch_add(out, n); else midi_to_apps(out, n);
                }
                if (g_diag_jog) jog_stat(out, n);
                if (g_learn) learn_note(out[0], out[1], n == 3 ? out[2] : 0);
                if (g_verbose) {
                    fprintf(stderr, "  in  ");
                    for (int k = 0; k < n; k++) fprintf(stderr, "%02x ", out[k]);
                    fprintf(stderr, "\n");
                }
            }
        }
        if (g_batch_frame) batch_flush();
    }
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }
    if (t->status == LIBUSB_TRANSFER_STALL) clear_halt_later(V7_EP_CTRL_IN);
    if (!g_quit) arm_bulk(t, &g_in_live[idx], V7_EP_CTRL_IN, "control-IN", &g_gripe_ctrl_in);
}

/* ---- bulk-IN re-arm watchdog -------------------------------------------
   ROOT CAUSE of "the GUI registers nothing, but a bridge restart fixes it":
   both bulk-IN pipes were submitted with the return value DISCARDED, at startup
   and on every resubmit. libusb_submit_transfer can fail transiently, and when
   it did the pipe was simply never re-armed -- for the life of the process. The
   bridge went on logging "running" and streaming iso at full rate (the audio
   clock is a separate set of transfers), so from outside everything looked
   healthy while the control endpoint was silently dead. Intermittent, because
   it depends on whether that one submit happened to fail.

   Now every submit is checked, a STALL clears the halt first, and the main loop
   re-arms anything not in flight, so the pipe self-heals instead of dying. */
static void arm_bulk(struct libusb_transfer *t, int *live, unsigned char ep,
                     const char *name, time_t *gripe) {
    if (g_quit || !t || *live) return;
    int r = libusb_submit_transfer(t);
    if (r == 0) { *live = 1; return; }
    if (usb_gone(r)) { usb_lost(r, name); return; }   /* dead handle: exit, do not spin */
    if (r == LIBUSB_ERROR_PIPE) clear_halt_later(ep);
    time_t now = time(NULL);            /* don't spam the log on a persistent fault */
    if (now != *gripe) {
        fprintf(stderr, "OpenV7: %s submit failed (%s) — retrying\n", name, libusb_error_name(r));
        *gripe = now;
    }
}

/* Re-arm one isochronous transfer. This is arm_bulk's twin, and it exists
   because the iso ring had the EXACT defect arm_bulk was written to fix and
   never got the fix: both iso callbacks resubmitted with the return value
   DISCARDED. A submit that fails drops that transfer out of the ring
   permanently and nothing notices -- there is no completion callback for a
   transfer that was never submitted. Lose all 16 and the 44.1 kHz playback
   clock stops, which silences the control surface too (the chip only reports
   controls while that clock runs), while the bridge goes on logging "running"
   because the bulk pipes are still armed. That is the same "healthy from the
   outside, dead on the wire" shape as the bulk bug.

   Checking the result and re-arming from the main loop makes the ring
   self-healing instead of silently draining. */
static void arm_iso(struct libusb_transfer *t, int *live, int pace, const char *name, time_t *gripe) {
    if (g_quit || !t || *live) return;
    if (pace) iso_pace(t);              /* lengths carry the rate; re-pace every submit */
    int r = libusb_submit_transfer(t);
    if (r == 0) { *live = 1; return; }
    if (usb_gone(r)) { usb_lost(r, name); return; }
    time_t now = time(NULL);
    if (now != *gripe) {
        fprintf(stderr, "OpenV7: %s submit failed (%s) — retrying\n", name, libusb_error_name(r));
        *gripe = now;
    }
}

/* submit one queued outgoing frame to the device (fire-and-forget) */
static void submit_out(const unsigned char *frame) {
    unsigned char *buf = malloc(V7_OUT_FRAME_LEN);
    if (!buf) return;
    memcpy(buf, frame, V7_OUT_FRAME_LEN);
    struct libusb_transfer *t = libusb_alloc_transfer(0);
    if (!t) { free(buf); return; }
    libusb_fill_bulk_transfer(t, g_dev, V7_EP_CTRL_OUT, buf, V7_OUT_FRAME_LEN, out_cb, NULL, 500);
    if (libusb_submit_transfer(t) != 0) { free(buf); libusb_free_transfer(t); }
}

static void on_sigint(int s) { (void)s; g_quit = 1; }

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v") || !strcmp(argv[i], "--verbose")) g_verbose = 1;
        else if (!strcmp(argv[i], "--learn")) g_learn = 1;
        else if (!strcmp(argv[i], "--diag")) g_diag = 1;
        else if (!strcmp(argv[i], "--diag-jog")) g_diag_jog = 1;
        else if (!strcmp(argv[i], "--no-timestamps")) g_send_timestamps = 0;
        else if (!strcmp(argv[i], "--no-keepalive")) g_keepalive = 0;
        else if (!strcmp(argv[i], "--supervised")) g_supervised = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("OpenV7 — Numark V7 userspace driver\n"
                   "usage: openv7 [-v|--verbose] [--learn] [--diag] [--diag-jog]\n"
                   "       [--no-timestamps] [--no-keepalive]\n"
                   "  -v        print decoded MIDI as it arrives\n"
                   "  --learn   catalog each control once (touch every control, Ctrl-C for the map)\n"
                   "  --diag    print isochronous stream health once a second (~200/~62 = healthy)\n"
                   "  --no-timestamps\n"
                   "            suppress the platter's 0xE0 timestamp messages. Diagnostic:\n"
                   "            VirtualDJ drives the jog FROM them, so this silences the jog\n"
                   "            and tells a jog fault apart from a timestamp fault.\n"
                   "  --diag-jog\n"
                   "            print platter timestamp-clock health once a second: whether the\n"
                   "            device's 0xE0 clock is smooth, whether position/timestamp stay\n"
                   "            paired 1:1, and whether WE deliver them evenly. Observational.\n"
                   "  --no-keepalive\n"
                   "            disable the control-stream keepalives (25 ms 0xFD frame on bulk\n"
                   "            0x04 + 2 s EP0 re-arm). They are ON by default: without them the\n"
                   "            control stream has been seen to deliver nothing at all from\n"
                   "            launch. Only for A/B testing that fault.\n"
                   "  --supervised\n"
                   "            exit when the launching parent process goes away, instead of\n"
                   "            lingering as an orphan that holds the USB interfaces and blocks\n"
                   "            every later bridge from claiming them. Used by OpenV7.app.\n");
            return 0;
        }
    }

    if (getenv("OPENV7_DIAG")) g_diag = 1;   /* also enable diag via environment */

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGUSR1, on_sigusr1);
    signal(SIGUSR2, on_sigusr2);
    g_parent_pid = getppid();

    /* Clear any inherited background/throttled scheduling. A menu-bar app's
       child can inherit a throttled task policy; keeping this process at normal
       priority with an interactive QoS keeps the isochronous clock steady.
       (This alone was NOT the streaming bug — that was a stray reset_device,
       see below — but steady iso timing is still worth having.) */
    setpriority(PRIO_DARWIN_PROCESS, 0, 0);   /* keep normal (un-throttled) scheduling */
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    /* Hold an App-Nap exemption for the whole process (see src/nonap.m) so a
       background/menu-bar parent can't nap the isochronous stream. Defensive —
       the stream is healthy without it, but it costs nothing to keep. */
    openv7_prevent_appnap();

    if (libusb_init(&g_ctx) < 0) { fprintf(stderr, "libusb init failed\n"); return 1; }
    g_dev = libusb_open_device_with_vid_pid(g_ctx, V7_VID, V7_PID);
    if (!g_dev) { fprintf(stderr, "Numark V7 not found (is it plugged in and powered on?)\n"); return 2; }
    /* DO NOT call libusb_reset_device() here -- on the bring-up path. (The stall
       recovery below does reset, deliberately, as a last resort.) Re-measured
       2026-08-24 on a wedged deck: a reset followed by a FRESH process does
       restore the platter encoder, buttons and faders, contrary to what this
       comment used to claim. What it does NOT restore is the MOTOR, which stays
       deaf to every start command until the deck is power-cycled.
       Proven via an A/B test on real hardware — motor-spin with a fresh bring-up
       streamed 315 encoder frames; the identical bring-up preceded by
       reset_device streamed 1. The device is instead kept clean across sessions
       by the graceful teardown at exit (cancel transfers, drop the iso stream,
       release interfaces) below. */
    libusb_set_auto_detach_kernel_driver(g_dev, 1);
    libusb_set_configuration(g_dev, 1);
    /* Check the claim and the alt setting. Both results used to be discarded and
       "device claimed." printed regardless. Claiming is what makes the endpoints
       usable and alt 1 is where the iso endpoints live, so a swallowed failure
       here produced a process that logged a clean bring-up and then streamed
       nothing at all -- the other face of "sometimes it doesn't handshake on
       startup". LIBUSB_ERROR_BUSY specifically means another process still holds
       the interface, in practice a previous bridge that has not finished tearing
       down; exiting lets the supervisor retry once it has let go. */
    for (int i = 0; i < V7_NUM_INTERFACES; i++) {
        int r = libusb_claim_interface(g_dev, i);
        if (r != 0) {
            fprintf(stderr, "OpenV7: cannot claim interface %d (%s)%s\n", i, libusb_error_name(r),
                    r == LIBUSB_ERROR_BUSY ? " — a previous bridge is still shutting down" : "");
            return 4;
        }
        r = libusb_set_interface_alt_setting(g_dev, i, V7_ALT_SETTING);
        if (r != 0) {
            fprintf(stderr, "OpenV7: cannot select alt setting %d on interface %d (%s)\n",
                    V7_ALT_SETTING, i, libusb_error_name(r));
            return 4;
        }
    }
    fprintf(stderr, "OpenV7: device claimed.\n");
    if (ploytec_handshake() != 0) return 3;
    fprintf(stderr, "OpenV7: handshake complete, device armed.\n");

    /* CoreMIDI virtual device */
    MIDIClientCreate(CFSTR("OpenV7"), NULL, NULL, &g_client);
    MIDISourceCreate(g_client, CFSTR("Numark V7"), &g_source);
    MIDIDestinationCreate(g_client, CFSTR("Numark V7"), dest_read, NULL, &g_dest);
    fprintf(stderr, "OpenV7: CoreMIDI device \"Numark V7\" is live.\n");

    /* iso-OUT audio clock (silence) */
    for (int i = 0; i < ISO_NXFER; i++) {
        /* Allocate for the WORST case (all 72 B packets) and never touch the
           bytes again — silence is zeros, and iso_pace() only moves the lengths.
           NOT V7_ISO_PKT_SIZE (156): that is the endpoint ceiling, not the
           amount the device is fed. */
        unsigned char *b = calloc(1, V7_ISO_PKT_MAX * ISO_NPKT_OUT);
        g_iso_out[i] = libusb_alloc_transfer(ISO_NPKT_OUT);
        /* Bail rather than limp. A short iso ring is not a degraded stream, it
           is the "healthy from the outside, dead on the wire" failure mode the
           arm_iso comment describes -- and an unchecked calloc here would hand
           libusb a NULL buffer and crash instead. */
        if (!b || !g_iso_out[i]) { fprintf(stderr, "OpenV7: out of memory building the iso-OUT ring\n"); return 5; }
        libusb_fill_iso_transfer(g_iso_out[i], g_dev, V7_EP_AUDIO_OUT, b,
                                 V7_ISO_PKT_MAX * ISO_NPKT_OUT, ISO_NPKT_OUT, iso_cb,
                                 (void *)(intptr_t)i, 1000);
        arm_iso(g_iso_out[i], &g_iso_out_live[i], 1, "iso-out", &g_gripe_iso_out);   /* paces, then submits checked */
    }
    /* iso-IN: the device stalls its control stream unless this endpoint is
       actively drained — the fix for "controls only report at startup". */
    for (int i = 0; i < ISO_NXFER; i++) {
        unsigned char *b = calloc(1, V7_ISO_IN_PKT_SIZE * ISO_NPKT_IN);
        g_iso_in[i] = libusb_alloc_transfer(ISO_NPKT_IN);
        if (!b || !g_iso_in[i]) { fprintf(stderr, "OpenV7: out of memory building the iso-IN ring\n"); return 5; }
        libusb_fill_iso_transfer(g_iso_in[i], g_dev, V7_EP_AUDIO_IN, b,
                                 V7_ISO_IN_PKT_SIZE * ISO_NPKT_IN, ISO_NPKT_IN, isoin_cb,
                                 (void *)(intptr_t)i, 1000);
        libusb_set_iso_packet_lengths(g_iso_in[i], V7_ISO_IN_PKT_SIZE);
        arm_iso(g_iso_in[i], &g_iso_in_live[i], 0, "iso-in", &g_gripe_iso_in);
    }
    /* control-IN ring + audio-return drain */
    static unsigned char aux[512];
    for (int i = 0; i < CTRL_IN_NXFER; i++) {
        unsigned char *cb_buf = calloc(1, 512);
        g_t_in[i] = libusb_alloc_transfer(0);
        if (!cb_buf || !g_t_in[i]) { fprintf(stderr, "OpenV7: out of memory building the control-IN ring\n"); return 5; }
        libusb_fill_bulk_transfer(g_t_in[i], g_dev, V7_EP_CTRL_IN, cb_buf, 512,
                                  ctrl_in_cb, (void *)(intptr_t)i, 0);
        arm_bulk(g_t_in[i], &g_in_live[i], V7_EP_CTRL_IN, "control-IN", &g_gripe_ctrl_in);
    }
    struct libusb_transfer *t_aux = libusb_alloc_transfer(0);
    if (!t_aux) { fprintf(stderr, "OpenV7: out of memory building the aux-drain transfer\n"); return 5; }
    libusb_fill_bulk_transfer(t_aux, g_dev, V7_EP_AUX_IN,  aux, sizeof aux, drain_cb,   NULL, 0);
    g_t_aux = t_aux;
    arm_bulk(t_aux, &g_aux_live, V7_EP_AUX_IN,  "aux-drain", &g_gripe_aux);

    if (g_learn)
        fprintf(stderr, "OpenV7: LEARN mode — touch every control once, then Ctrl-C for the map.\n");
    else
        fprintf(stderr, "OpenV7: running. Select \"Numark V7\" in your DJ app. Ctrl-C to stop.\n");
    g_last_data_ms = now_ms();

    long diag_o0 = 0, diag_i0 = 0; time_t diag_t = time(NULL), rearm_t = time(NULL);
    time_t jog_t = time(NULL);
    unsigned char idle_frame[V7_OUT_FRAME_LEN]; memset(idle_frame, V7_MIDI_IDLE, V7_OUT_FRAME_LEN);
    struct timeval tvn; gettimeofday(&tvn, NULL); long ka04_ms = tvn.tv_sec*1000 + tvn.tv_usec/1000;
    while (!g_quit) {
        struct timeval tv = { 0, 20000 };
        libusb_handle_events_timeout(g_ctx, &tv);
        clear_halt_drain();     /* stall recovery, deferred out of the callbacks */
        /* Escalate a pipe that clear_halt cannot fix. Without this the bridge
           spins on PIPE indefinitely while reporting itself healthy. */
        if (g_pipe_hits >= STALL_HITS && g_last_data_ms &&
            now_ms() - g_last_data_ms > STALL_QUIET_MS) {
            fprintf(stderr, "OpenV7: %d pipe stalls in %ldms and clear-halt did not fix it — "
                            "resetting the device and restarting.\n",
                    g_pipe_hits, now_ms() - g_pipe_win_ms);
            /* A port reset restores the CONTROL path -- encoder, buttons and
               faders all report again after the fresh bring-up, measured on
               hardware. It does NOT restore the MOTOR: the deck ignores every
               documented start command afterwards (instant, soft, and the full
               stop/latch/RPM/start sequence) until it is power-cycled, while
               still happily sending button and platter messages.

               That is the real shape of the warning this file used to carry.
               The warning named the platter encoder, which does come back; the
               motor is what does not. Resetting is still the right call when the
               alternative is a control stream that is dead for the rest of the
               session -- but it is not free, and the operator has to be told. */
            libusb_reset_device(g_dev);   /* invalidates the handle: exit, do not continue */
            fprintf(stderr, "OpenV7: control restored. MOTOR control needs a power cycle "
                            "of the deck -- a USB reset does not re-arm it.\n");
            g_stall_exit = 1;
            g_quit = 1;
        }
        if (g_toggle_ts) {      /* SIGUSR1: flip the timestamp filter in place */
            g_toggle_ts = 0;
            g_send_timestamps = !g_send_timestamps;
            fprintf(stderr, "OpenV7: platter 0xE0 timestamps -> apps: %s\n",
                    g_send_timestamps ? "ON (raw protocol)" : "OFF (filtered)");
        }
        if (g_toggle_batch) {
            g_toggle_batch = 0;
            g_batch_frame = !g_batch_frame;
            fprintf(stderr, "OpenV7: CoreMIDI packing: %s\n",
                    g_batch_frame ? "ONE packet list per USB transfer (pair kept together)"
                                  : "one packet list per message (original)");
        }
        /* EP0 status re-arm, every 2 s (secondary keepalive) — legacy only. */
        if (g_keepalive) { time_t now = time(NULL);
          if (now - rearm_t >= 2) { ploytec_rearm(); rearm_t = now; } }
        /* Orphan check: the parent died and we were reparented. Release the USB
           interfaces via the normal teardown rather than sitting on them. */
        if (g_supervised && getppid() != g_parent_pid) {
            fprintf(stderr, "OpenV7: supervising parent exited — shutting down.\n");
            g_quit = 1;
        }
        /* Watchdog: re-arm either bulk-IN pipe if it is not in flight. Without
           this a single failed submit silently kills the control stream for the
           whole session -- the fault that presented as "the GUI registers
           nothing until you restart the bridge". No-op when both are live. */
        for (int i = 0; i < CTRL_IN_NXFER; i++)
            arm_bulk(g_t_in[i], &g_in_live[i], V7_EP_CTRL_IN, "control-IN", &g_gripe_ctrl_in);
        arm_bulk(g_t_aux, &g_aux_live, V7_EP_AUX_IN,  "aux-drain", &g_gripe_aux);
        /* Same watchdog for the iso rings. A transfer whose resubmit failed is
           gone from the ring with no callback to notice; without this the ring
           drains silently and takes the control stream with it. No-op when all
           32 are in flight, which is the normal case. */
        for (int i = 0; i < ISO_NXFER; i++) {
            arm_iso(g_iso_out[i], &g_iso_out_live[i], 1, "iso-out", &g_gripe_iso_out);
            arm_iso(g_iso_in[i],  &g_iso_in_live[i],  0, "iso-in",  &g_gripe_iso_in);
        }
        /* drain outgoing MIDI to the device */
        int sent_real = 0;
        pthread_mutex_lock(&outq_mtx);
        while (outq_tail != outq_head) {
            submit_out(outq[outq_tail]);
            outq_tail = (outq_tail + 1) % OUTQ;
            sent_real = 1;
        }
        pthread_mutex_unlock(&outq_mtx);
        /* PRIMARY keepalive: the V7 silences its whole control stream (jog,
           buttons — bulk 0x83 IN) unless it keeps receiving frames on the
           control-OUT pipe (bulk 0x04). Send an idle (0xFD-filled) frame at a
           steady ~25 ms cadence whenever the app isn't already sending — it acts
           as a second clock for the control channel. Proven on hardware: without
           it the stream dies as soon as output goes quiet (e.g. platter braked);
           with it, it survives pauses and streams indefinitely. */
        gettimeofday(&tvn, NULL); long nowms = tvn.tv_sec*1000 + tvn.tv_usec/1000;
        if (sent_real) ka04_ms = nowms;
        else if (g_keepalive && nowms - ka04_ms >= 25) { submit_out(idle_frame); ka04_ms = nowms; }
        /* --diag: report iso completion rates once per WALL-CLOCK second. This
           MUST be time-gated, not iteration-gated: the loop spins ~500×/s, so an
           iteration counter fires the (unbuffered) fprintf ~10×/s, and that log
           I/O stalls the event loop enough to underrun the stream — the report
           would then measure its own interference.

           Healthy: ~200 iso-out/s, ~62 iso-in/s. iso-out WAS ~500/s before the
           pacing fix — 8000 packets/s over 16-packet URBs. It is now 8000 over
           40-packet URBs = 200. A drop from 500 to 200 here is the fix working,
           not a regression; the packet rate on the wire is identical. */
        if (g_diag) {
            time_t now = time(NULL);
            if (now != diag_t) {
                int iso_armed = 0, in_armed = 0;
                for (int i = 0; i < ISO_NXFER; i++) iso_armed += g_iso_out_live[i] + g_iso_in_live[i];
                /* Counted with a LOOP, not g_in_live[0]+[1]+[2]+[3]. The unrolled
                   version silently under-reported the moment CTRL_IN_NXFER changed
                   -- a health readout that lies when you tune the thing it measures
                   is worse than no readout. */
                for (int i = 0; i < CTRL_IN_NXFER; i++) in_armed += g_in_live[i];
                fprintf(stderr, "  [diag] iso-out/s=%ld iso-in/s=%ld  ctrl-bytes=%ld in-armed=%d/%d iso-armed=%d/%d  (healthy: ~200/~62)\n",
                        g_isoout_cmpl - diag_o0, g_isoin_cmpl - diag_i0, g_ctrl_bytes,
                        in_armed, CTRL_IN_NXFER,
                        iso_armed, ISO_NXFER * 2);
                diag_o0 = g_isoout_cmpl; diag_i0 = g_isoin_cmpl; diag_t = now;
            }
        }
        if (g_diag_jog) {
            time_t now = time(NULL);
            if (now != jog_t) {
                if (g_jog_n) {
                    double dmean = (double)g_jog_dsum / g_jog_n;
                    double hmean = (double)g_jog_hsum / g_jog_n;
                    fprintf(stderr,
                        "  [jog] e0/s=%ld pos/s=%ld | device dt mean=%.0f min=%u max=%u units"
                        " | host gap mean=%.0f min=%ld max=%ld us | implied clock %.0f Hz (expect 2822400)\n",
                        g_jog_n, g_jog_pos_n, dmean, g_jog_dmin, g_jog_dmax,
                        hmean, g_jog_hmin, g_jog_hmax, dmean * (double)g_jog_n);
                } else if (g_jog_pos_n) {
                    fprintf(stderr, "  [jog] pos/s=%ld but ZERO 0xE0 timestamps — the 1:1 pairing is broken\n",
                            g_jog_pos_n);
                } else {
                    /* Say so explicitly. An empty readout must never be mistaken
                       for a measurement: spin the platter or the motor to feed it. */
                    fprintf(stderr, "  [jog] idle — platter not moving, nothing to measure\n");
                }
                g_jog_n = g_jog_pos_n = 0; g_jog_dsum = 0; g_jog_hsum = 0;
                jog_t = now;
            }
        }
    }

    fprintf(stderr, "\nOpenV7: shutting down.\n");
    if (g_learn) learn_dump();
    g_quit = 1;
    /* Graceful teardown so the device is left clean for the next session: cancel
       every outstanding transfer, let the cancellations complete, drop the iso
       stream to the zero-bandwidth alt setting, and release the interfaces.
       Skipping this leaves the device mid-stream and can jam the control stream
       on the next launch. */
    for (int i = 0; i < ISO_NXFER; i++) { libusb_cancel_transfer(g_iso_out[i]); libusb_cancel_transfer(g_iso_in[i]); }
    for (int i = 0; i < CTRL_IN_NXFER; i++) libusb_cancel_transfer(g_t_in[i]);
    libusb_cancel_transfer(t_aux);
    for (int i = 0; i < 12; i++) { struct timeval tv = { 0, 50000 }; libusb_handle_events_timeout(g_ctx, &tv); }
    for (int i = 0; i < V7_NUM_INTERFACES; i++) {
        libusb_set_interface_alt_setting(g_dev, i, 0);   /* zero-bandwidth alt: stop the stream cleanly */
        libusb_release_interface(g_dev, i);
    }
    MIDIEndpointDispose(g_source);
    MIDIEndpointDispose(g_dest);
    MIDIClientDispose(g_client);
    libusb_close(g_dev);
    libusb_exit(g_ctx);
    /* Non-zero after a stall reset so the supervising app relaunches us into a
       full fresh bring-up, which is what actually clears the fault. */
    return g_stall_exit ? 3 : 0;
}
