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

#define ISO_NPKT   16
/* 16 iso transfers in flight (~32 ms of queued output at 8000 packets/s), NOT 4.
   With a shallow queue any scheduling hiccup empties it, the V7 sees a gap in
   its playback clock, and it drops the whole stream — controls included — after
   a while ("goes quiet"). A deep queue absorbs the hiccups. Proven on hardware:
   4 transfers crashed iso-OUT to 0 within ~9 s under load; 16 held a steady
   500/62 indefinitely. */
#define ISO_NXFER  16

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

/* ---- streaming-health counters (for the --diag rate report) ---- */
static long g_isoout_cmpl = 0, g_isoin_cmpl = 0;

/* ---- USB transfer callbacks ---- */
static void LIBUSB_CALL iso_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }  /* unplugged */
    g_isoout_cmpl++;
    if (!g_quit) libusb_submit_transfer(t);           /* silence buffer already zero */
}
static void LIBUSB_CALL drain_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) { g_quit = 1; return; }
    if (!g_quit) libusb_submit_transfer(t);           /* discard audio-return */
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
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
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
    if (!g_quit) libusb_submit_transfer(t);
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
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("OpenV7 — Numark V7 userspace driver\n"
                   "usage: openv7 [-v|--verbose] [--learn] [--diag]\n"
                   "  -v        print decoded MIDI as it arrives\n"
                   "  --learn   catalog each control once (touch every control, Ctrl-C for the map)\n"
                   "  --diag    print isochronous stream health once a second (~500/~62 = healthy)\n");
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
        unsigned char *b = calloc(1, V7_ISO_PKT_SIZE * ISO_NPKT);
        iso[i] = libusb_alloc_transfer(ISO_NPKT);
        libusb_fill_iso_transfer(iso[i], g_dev, V7_EP_AUDIO_OUT, b,
                                 V7_ISO_PKT_SIZE * ISO_NPKT, ISO_NPKT, iso_cb, NULL, 1000);
        libusb_set_iso_packet_lengths(iso[i], V7_ISO_PKT_SIZE);
        libusb_submit_transfer(iso[i]);
    }
    /* iso-IN: the device stalls its control stream unless this endpoint is
       actively drained — the fix for "controls only report at startup". */
    struct libusb_transfer *isoin[ISO_NXFER];
    for (int i = 0; i < ISO_NXFER; i++) {
        unsigned char *b = calloc(1, V7_ISO_IN_PKT_SIZE * ISO_NPKT);
        isoin[i] = libusb_alloc_transfer(ISO_NPKT);
        libusb_fill_iso_transfer(isoin[i], g_dev, V7_EP_AUDIO_IN, b,
                                 V7_ISO_IN_PKT_SIZE * ISO_NPKT, ISO_NPKT, isoin_cb, NULL, 1000);
        libusb_set_iso_packet_lengths(isoin[i], V7_ISO_IN_PKT_SIZE);
        libusb_submit_transfer(isoin[i]);
    }
    /* control-IN and audio-return-drain reads */
    static unsigned char cin[512], aux[512];
    struct libusb_transfer *t_in  = libusb_alloc_transfer(0);
    struct libusb_transfer *t_aux = libusb_alloc_transfer(0);
    libusb_fill_bulk_transfer(t_in,  g_dev, V7_EP_CTRL_IN, cin, sizeof cin, ctrl_in_cb, NULL, 0);
    libusb_fill_bulk_transfer(t_aux, g_dev, V7_EP_AUX_IN,  aux, sizeof aux, drain_cb,   NULL, 0);
    libusb_submit_transfer(t_in);
    libusb_submit_transfer(t_aux);

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
        /* EP0 status re-arm, every 2 s (secondary keepalive). */
        { time_t now = time(NULL);
          if (now - rearm_t >= 2) { ploytec_rearm(); rearm_t = now; } }
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
        else if (nowms - ka04_ms >= 25) { submit_out(idle_frame); ka04_ms = nowms; }
        /* --diag: report iso completion rates once per WALL-CLOCK second. This
           MUST be time-gated, not iteration-gated: the loop spins ~500×/s, so an
           iteration counter fires the (unbuffered) fprintf ~10×/s, and that log
           I/O stalls the event loop enough to underrun the stream — the report
           would then measure its own interference. Healthy: ~500 iso-out/s,
           ~62 iso-in/s. */
        if (g_diag) {
            time_t now = time(NULL);
            if (now != diag_t) {
                fprintf(stderr, "  [diag] iso-out/s=%ld iso-in/s=%ld\n",
                        g_isoout_cmpl - diag_o0, g_isoin_cmpl - diag_i0);
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
