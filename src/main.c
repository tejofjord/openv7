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
struct midi_split { uint8_t status, data[2]; int ndata, need; };
static int midi_msg_len(uint8_t status) {
    switch (status & 0xF0) {
        case 0xC0: case 0xD0: return 2;      /* status + 1 data */
        default:              return 3;      /* status + 2 data */
    }
}
/* feed one byte; when a full channel-voice message completes, copy it to out[<=3]
 * and return its length, else return 0. 0xFD/idle and realtime are skipped. */
static int midi_feed(struct midi_split *s, uint8_t x, uint8_t out[3]) {
    if (x == V7_MIDI_IDLE) return 0;
    if (x & 0x80) {
        if (x >= 0xF8) return 0;             /* system realtime — ignore */
        s->status = x; s->ndata = 0; s->need = midi_msg_len(x);
        return 0;
    }
    if (!s->status) return 0;
    s->data[s->ndata++] = x;
    if (s->ndata >= s->need - 1) {
        out[0] = s->status;
        out[1] = s->data[0];
        int n = s->need;
        if (n == 3) out[2] = s->data[1];
        s->ndata = 0;                        /* running status stays armed */
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

/* ---- CoreMIDI: receive from apps -> queue for the device ---- */
static void dest_read(const MIDIPacketList *pl, void *refCon, void *srcRefCon) {
    (void)refCon; (void)srcRefCon;
    const MIDIPacket *p = &pl->packet[0];
    for (unsigned i = 0; i < pl->numPackets; i++) {
        struct midi_split s = {0}; uint8_t out[3];
        for (unsigned j = 0; j < p->length; j++) {
            int n = midi_feed(&s, p->data[j], out);
            if (n > 0) outq_push(out, n);
        }
        p = MIDIPacketNext(p);
    }
}

/* ---- USB: Ploytec handshake (arms the device for streaming) ---- */
static int ctrl(uint8_t rt, uint8_t rq, uint16_t v, uint16_t ix, unsigned char *b, uint16_t l) {
    return libusb_control_transfer(g_dev, rt, rq, v, ix, b, l, 2000);
}
static int ploytec_handshake(void) {
    unsigned char b[16]; int r;
    r = ctrl(0xC0, PL_REQ_FIRMWARE, 0, 0, b, 15);
    if (r < 3) { fprintf(stderr, "firmware read failed (%d)\n", r); return -1; }
    fprintf(stderr, "  V7 firmware: chip 0x%02X\n", b[0]);
    ctrl(0xC0, PL_REQ_STATUS, 0, 0, b, 1);            /* status read */
    ctrl(0xA2, PL_REQ_GET_RATE, 0x0100, 0, b, 3);     /* GET_CUR rate */
    unsigned char rate[3] = { V7_SAMPLE_RATE & 0xFF, (V7_SAMPLE_RATE >> 8) & 0xFF, (V7_SAMPLE_RATE >> 16) & 0xFF };
    uint16_t reps[] = { 0x0086, V7_EP_AUDIO_OUT, V7_EP_AUDIO_IN, 0x0005 };
    for (unsigned i = 0; i < 4; i++) ctrl(0x22, PL_REQ_SET_RATE, 0x0100, reps[i], rate, 3);
    r = ctrl(0xC0, PL_REQ_STATUS, 0, 0, b, 1);        /* re-read status */
    unsigned char st = (r > 0) ? b[0] : 0;
    int8_t mod = (int8_t)(st | 0x20);                 /* arm: bit5 set, sign-extended */
    ctrl(0x40, PL_REQ_STATUS, (uint16_t)(int16_t)mod, 0, NULL, 0);
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
        libusb_fill_control_setup(wb, 0x40, PL_REQ_STATUS, (uint16_t)(int16_t)mod, 0, 0);
        struct libusb_transfer *wt = libusb_alloc_transfer(0);
        libusb_fill_control_transfer(wt, g_dev, wb, ka_write_cb, NULL, 500);
        if (libusb_submit_transfer(wt) != 0) { free(wb); libusb_free_transfer(wt); }
    }
    free(t->buffer); libusb_free_transfer(t);
}
static void ploytec_rearm(void) {
    unsigned char *rb = malloc(LIBUSB_CONTROL_SETUP_SIZE + 1);
    libusb_fill_control_setup(rb, 0xC0, PL_REQ_STATUS, 0, 0, 1);
    struct libusb_transfer *rt = libusb_alloc_transfer(0);
    libusb_fill_control_transfer(rt, g_dev, rb, ka_read_cb, NULL, 500);
    if (libusb_submit_transfer(rt) != 0) { free(rb); libusb_free_transfer(rt); }
}

/* bulk-IN watchdog state (definition of arm_bulk is further down) */
static struct libusb_transfer *g_t_in = NULL, *g_t_aux = NULL;
static int g_in_live = 0, g_aux_live = 0;
static long g_ctrl_bytes = 0;          /* control-IN traffic, for --diag */
static void arm_bulk(struct libusb_transfer *t, int *live, unsigned char ep, const char *name);

/* ---- streaming-health counters (for the --diag rate report) ---- */
static long g_isoout_cmpl = 0, g_isoin_cmpl = 0;

/* ---- USB transfer callbacks ---- */
static void LIBUSB_CALL iso_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }  /* unplugged */
    g_isoout_cmpl++;
    /* Re-pace before every resubmit: the packet lengths are what hold 44.1 kHz,
       and the accumulator has to keep advancing across resubmissions or the
       fractional 0.0125 frame/packet is lost and the stream drifts slow. */
    if (!g_quit) { iso_pace(t); libusb_submit_transfer(t); }   /* silence buffer already zero */
}
static void LIBUSB_CALL drain_cb(struct libusb_transfer *t) {
    g_aux_live = 0;
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }
    if (t->status == LIBUSB_TRANSFER_STALL) libusb_clear_halt(g_dev, V7_EP_AUX_IN);
    if (!g_quit) arm_bulk(t, &g_aux_live, V7_EP_AUX_IN, "aux-drain");  /* discard audio-return */
}
static void LIBUSB_CALL isoin_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }
    g_isoin_cmpl++;
    if (!g_quit) libusb_submit_transfer(t);           /* drain iso-IN — REQUIRED or the
                                                         device stalls its control stream */
}
static void LIBUSB_CALL out_cb(struct libusb_transfer *t) {
    free(t->buffer);
    libusb_free_transfer(t);
}
static struct midi_split g_in;                        /* device-side parser state */
static void LIBUSB_CALL ctrl_in_cb(struct libusb_transfer *t) {
    g_in_live = 0;                                     /* no longer in flight */
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        g_ctrl_bytes += t->actual_length;
        uint8_t out[3];
        for (int i = 0; i < t->actual_length; i++) {
            int n = midi_feed(&g_in, t->buffer[i], out);
            if (n > 0) {
                midi_to_apps(out, n);
                if (g_learn) learn_note(out[0], out[1], n == 3 ? out[2] : 0);
                if (g_verbose) {
                    fprintf(stderr, "  in  ");
                    for (int k = 0; k < n; k++) fprintf(stderr, "%02x ", out[k]);
                    fprintf(stderr, "\n");
                }
            }
        }
    }
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }
    if (t->status == LIBUSB_TRANSFER_STALL) libusb_clear_halt(g_dev, V7_EP_CTRL_IN);
    if (!g_quit) arm_bulk(t, &g_in_live, V7_EP_CTRL_IN, "control-IN");
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
static void arm_bulk(struct libusb_transfer *t, int *live, unsigned char ep, const char *name) {
    if (g_quit || !t || *live) return;
    int r = libusb_submit_transfer(t);
    if (r == 0) { *live = 1; return; }
    if (r == LIBUSB_ERROR_PIPE) libusb_clear_halt(g_dev, ep);
    static time_t last_gripe;           /* don't spam the log on a persistent fault */
    time_t now = time(NULL);
    if (now != last_gripe) {
        fprintf(stderr, "OpenV7: %s submit failed (%s) — retrying\n", name, libusb_error_name(r));
        last_gripe = now;
    }
}

/* submit one queued outgoing frame to the device (fire-and-forget) */
static void submit_out(const unsigned char *frame) {
    unsigned char *buf = malloc(V7_OUT_FRAME_LEN);
    memcpy(buf, frame, V7_OUT_FRAME_LEN);
    struct libusb_transfer *t = libusb_alloc_transfer(0);
    libusb_fill_bulk_transfer(t, g_dev, V7_EP_CTRL_OUT, buf, V7_OUT_FRAME_LEN, out_cb, NULL, 500);
    if (libusb_submit_transfer(t) != 0) { free(buf); libusb_free_transfer(t); }
}

static void on_sigint(int s) { (void)s; g_quit = 1; }

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v") || !strcmp(argv[i], "--verbose")) g_verbose = 1;
        else if (!strcmp(argv[i], "--learn")) g_learn = 1;
        else if (!strcmp(argv[i], "--diag")) g_diag = 1;
        else if (!strcmp(argv[i], "--no-keepalive")) g_keepalive = 0;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("OpenV7 — Numark V7 userspace driver\n"
                   "usage: openv7 [-v|--verbose] [--learn] [--diag]\n"
                   "  -v        print decoded MIDI as it arrives\n"
                   "  --learn   catalog each control once (touch every control, Ctrl-C for the map)\n"
                   "  --diag    print isochronous stream health once a second (~200/~62 = healthy)\n"
                   "  --no-keepalive\n"
                   "            disable the control-stream keepalives (25 ms 0xFD frame on bulk\n"
                   "            0x04 + 2 s EP0 re-arm). They are ON by default: without them the\n"
                   "            control stream has been seen to deliver nothing at all from\n"
                   "            launch. Only for A/B testing that fault.\n");
            return 0;
        }
    }

    if (getenv("OPENV7_DIAG")) g_diag = 1;   /* also enable diag via environment */

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

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
    /* DO NOT call libusb_reset_device() here. A USB port reset re-enumerates the
       device but leaves the platter-encoder subsystem un-armed: the control
       stream still emits its idle heartbeat, yet jog/platter frames never come.
       Proven via an A/B test on real hardware — motor-spin with a fresh bring-up
       streamed 315 encoder frames; the identical bring-up preceded by
       reset_device streamed 1. The device is instead kept clean across sessions
       by the graceful teardown at exit (cancel transfers, drop the iso stream,
       release interfaces) below. */
    libusb_set_auto_detach_kernel_driver(g_dev, 1);
    libusb_set_configuration(g_dev, 1);
    for (int i = 0; i < V7_NUM_INTERFACES; i++) {
        libusb_claim_interface(g_dev, i);
        libusb_set_interface_alt_setting(g_dev, i, V7_ALT_SETTING);
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
    struct libusb_transfer *iso[ISO_NXFER];
    for (int i = 0; i < ISO_NXFER; i++) {
        /* Allocate for the WORST case (all 72 B packets) and never touch the
           bytes again — silence is zeros, and iso_pace() only moves the lengths.
           NOT V7_ISO_PKT_SIZE (156): that is the endpoint ceiling, not the
           amount the device is fed. */
        unsigned char *b = calloc(1, V7_ISO_PKT_MAX * ISO_NPKT_OUT);
        iso[i] = libusb_alloc_transfer(ISO_NPKT_OUT);
        libusb_fill_iso_transfer(iso[i], g_dev, V7_EP_AUDIO_OUT, b,
                                 V7_ISO_PKT_MAX * ISO_NPKT_OUT, ISO_NPKT_OUT, iso_cb, NULL, 1000);
        iso_pace(iso[i]);                              /* sets per-packet lengths + t->length */
        libusb_submit_transfer(iso[i]);
    }
    /* iso-IN: the device stalls its control stream unless this endpoint is
       actively drained — the fix for "controls only report at startup". */
    struct libusb_transfer *isoin[ISO_NXFER];
    for (int i = 0; i < ISO_NXFER; i++) {
        unsigned char *b = calloc(1, V7_ISO_IN_PKT_SIZE * ISO_NPKT_IN);
        isoin[i] = libusb_alloc_transfer(ISO_NPKT_IN);
        libusb_fill_iso_transfer(isoin[i], g_dev, V7_EP_AUDIO_IN, b,
                                 V7_ISO_IN_PKT_SIZE * ISO_NPKT_IN, ISO_NPKT_IN, isoin_cb, NULL, 1000);
        libusb_set_iso_packet_lengths(isoin[i], V7_ISO_IN_PKT_SIZE);
        libusb_submit_transfer(isoin[i]);
    }
    /* control-IN and audio-return-drain reads */
    static unsigned char cin[512], aux[512];
    struct libusb_transfer *t_in  = libusb_alloc_transfer(0);
    struct libusb_transfer *t_aux = libusb_alloc_transfer(0);
    libusb_fill_bulk_transfer(t_in,  g_dev, V7_EP_CTRL_IN, cin, sizeof cin, ctrl_in_cb, NULL, 0);
    libusb_fill_bulk_transfer(t_aux, g_dev, V7_EP_AUX_IN,  aux, sizeof aux, drain_cb,   NULL, 0);
    g_t_in = t_in; g_t_aux = t_aux;
    arm_bulk(t_in,  &g_in_live,  V7_EP_CTRL_IN, "control-IN");
    arm_bulk(t_aux, &g_aux_live, V7_EP_AUX_IN,  "aux-drain");

    if (g_learn)
        fprintf(stderr, "OpenV7: LEARN mode — touch every control once, then Ctrl-C for the map.\n");
    else
        fprintf(stderr, "OpenV7: running. Select \"Numark V7\" in your DJ app. Ctrl-C to stop.\n");

    long diag_o0 = 0, diag_i0 = 0; time_t diag_t = time(NULL), rearm_t = time(NULL);
    unsigned char idle_frame[V7_OUT_FRAME_LEN]; memset(idle_frame, V7_MIDI_IDLE, V7_OUT_FRAME_LEN);
    struct timeval tvn; gettimeofday(&tvn, NULL); long ka04_ms = tvn.tv_sec*1000 + tvn.tv_usec/1000;
    while (!g_quit) {
        struct timeval tv = { 0, 20000 };
        libusb_handle_events_timeout(g_ctx, &tv);
        /* EP0 status re-arm, every 2 s (secondary keepalive) — legacy only. */
        if (g_keepalive) { time_t now = time(NULL);
          if (now - rearm_t >= 2) { ploytec_rearm(); rearm_t = now; } }
        /* Watchdog: re-arm either bulk-IN pipe if it is not in flight. Without
           this a single failed submit silently kills the control stream for the
           whole session -- the fault that presented as "the GUI registers
           nothing until you restart the bridge". No-op when both are live. */
        arm_bulk(g_t_in,  &g_in_live,  V7_EP_CTRL_IN, "control-IN");
        arm_bulk(g_t_aux, &g_aux_live, V7_EP_AUX_IN,  "aux-drain");
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
                fprintf(stderr, "  [diag] iso-out/s=%ld iso-in/s=%ld  ctrl-bytes=%ld in-live=%d  (healthy: ~200/~62)\n",
                        g_isoout_cmpl - diag_o0, g_isoin_cmpl - diag_i0, g_ctrl_bytes, g_in_live);
                diag_o0 = g_isoout_cmpl; diag_i0 = g_isoin_cmpl; diag_t = now;
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
    for (int i = 0; i < ISO_NXFER; i++) { libusb_cancel_transfer(iso[i]); libusb_cancel_transfer(isoin[i]); }
    libusb_cancel_transfer(t_in);
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
    return 0;
}
