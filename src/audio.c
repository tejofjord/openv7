/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — native audio: CoreAudio capture + test tone. See audio.h.
 */
#include "audio.h"
#include "v7ring.h"
#include "ploytec.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <math.h>
#include <unistd.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

enum { MODE_OFF = 0, MODE_TONE, MODE_DEVICE };

static int                 g_mode = MODE_OFF;
static v7ring             *g_ring;
static AudioObjectID       g_dev = kAudioObjectUnknown;
static AudioDeviceIOProcID g_proc;
static char                g_dev_name[256];
static Float64             g_src_rate;
static UInt32              g_src_channels;
static UInt32              g_buf_frames;
static int                 g_map[4] = { 0, 1, 2, 3 };
static _Atomic uint64_t    g_cb_frames;      /* frames CoreAudio has handed us */
static _Atomic uint64_t    g_cb_calls;

/* tone */
static double g_ph_a, g_ph_b;
static long   g_tone_n;
static float  g_tone_peak;

int audio_active(void) { return g_mode != MODE_OFF; }

/* ---------------------------------------------------------------- tone --- */

int audio_open_tone(void) {
    g_mode = MODE_TONE;
    g_ph_a = g_ph_b = 0.0;
    g_tone_n = 0;
    fprintf(stderr, "OpenV7: audio: TEST TONE -- deck A output 440 Hz, deck B output 660 Hz, -18 dBFS.\n"
                    "        Turn the mixer down before you listen.\n");
    return 0;
}

static void render_tone(uint8_t *dst, int frames) {
    const double da = 2.0 * M_PI * 440.0 / V7_SAMPLE_RATE;
    const double db = 2.0 * M_PI * 660.0 / V7_SAMPLE_RATE;
    for (int i = 0; i < frames; i++) {
        double env = g_tone_n < 4410 ? (double)g_tone_n / 4410.0 : 1.0;   /* 100 ms fade-in, no click */
        g_tone_n++;
        float a = (float)(0.125 * env * sin(g_ph_a));
        float b = (float)(0.125 * env * sin(g_ph_b));
        g_ph_a += da; if (g_ph_a >= 2.0 * M_PI) g_ph_a -= 2.0 * M_PI;
        g_ph_b += db; if (g_ph_b >= 2.0 * M_PI) g_ph_b -= 2.0 * M_PI;
        uint8_t *f = &dst[i * V7_ISO_FRAME_BYTES];
        v7r_pack_s24(f + 0, a); v7r_pack_s24(f + 3, a);
        v7r_pack_s24(f + 6, b); v7r_pack_s24(f + 9, b);
        if (fabsf(a) > g_tone_peak) g_tone_peak = fabsf(a);
        if (fabsf(b) > g_tone_peak) g_tone_peak = fabsf(b);
    }
}

/* ------------------------------------------------------ CoreAudio side --- */

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    return a;
}

static UInt32 input_channels(AudioObjectID dev) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput);
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) != noErr || sz == 0) return 0;
    AudioBufferList *bl = malloc(sz);
    if (!bl) return 0;
    UInt32 ch = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, bl) == noErr)
        for (UInt32 i = 0; i < bl->mNumberBuffers; i++) ch += bl->mBuffers[i].mNumberChannels;
    free(bl);
    return ch;
}

static int device_name(AudioObjectID dev, char *out, size_t n) {
    AudioObjectPropertyAddress a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
    CFStringRef s = NULL;
    UInt32 sz = sizeof s;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &s) != noErr || !s) return 0;
    Boolean ok = CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8);
    CFRelease(s);
    return ok ? 1 : 0;
}

static AudioObjectID find_device(const char *want, int verbose) {
    /* 1. by UID */
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    CFStringRef uid = CFStringCreateWithCString(NULL, want, kCFStringEncodingUTF8);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof dev;
    if (uid) {
        OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof uid, &uid, &sz, &dev);
        CFRelease(uid);
        if (st == noErr && dev != kAudioObjectUnknown && input_channels(dev) > 0) return dev;
    }

    /* 2. by name: exact first, then case-insensitive prefix */
    a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz) != noErr || sz == 0)
        return kAudioObjectUnknown;
    AudioObjectID *ids = malloc(sz);
    if (!ids) return kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids) != noErr) { free(ids); return kAudioObjectUnknown; }
    UInt32 n = sz / sizeof *ids;
    AudioObjectID found = kAudioObjectUnknown;
    char name[256];
    for (int pass = 0; pass < 2 && found == kAudioObjectUnknown; pass++) {
        for (UInt32 i = 0; i < n; i++) {
            if (!device_name(ids[i], name, sizeof name)) continue;
            int match = pass == 0 ? !strcmp(name, want) : !strncasecmp(name, want, strlen(want));
            if (match && input_channels(ids[i]) > 0) { found = ids[i]; break; }
        }
    }
    if (found == kAudioObjectUnknown && verbose) {
        fprintf(stderr, "OpenV7: audio: input devices on this Mac:\n");
        for (UInt32 i = 0; i < n; i++) {
            UInt32 ch = input_channels(ids[i]);
            if (ch && device_name(ids[i], name, sizeof name)) fprintf(stderr, "          \"%s\" (%u ch)\n", name, ch);
        }
    }
    free(ids);
    return found;
}

/* The HAL's IO thread calls this with each buffer of the device's input. It
   only copies: pick the four mapped channels, interleave, push to the ring. */
static OSStatus ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                       const AudioBufferList *in, const AudioTimeStamp *inInputTime,
                       AudioBufferList *out, const AudioTimeStamp *inOutputTime, void *ctx) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime; (void)ctx;
    if (out) {   /* we never play into the device; make sure we add nothing to its mix */
        for (UInt32 b = 0; b < out->mNumberBuffers; b++)
            if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    }
    if (!in || in->mNumberBuffers == 0 || !g_ring) return noErr;

    const float *src[V7R_CH] = { NULL };
    UInt32 stride[V7R_CH] = { 0 };
    UInt32 frames = UINT32_MAX;
    for (int c = 0; c < V7R_CH; c++) {
        UInt32 base = 0;
        for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
            UInt32 nch = in->mBuffers[b].mNumberChannels;
            if (nch && (UInt32)g_map[c] < base + nch) {
                if (in->mBuffers[b].mData) {
                    src[c] = (const float *)in->mBuffers[b].mData + (g_map[c] - base);
                    stride[c] = nch;
                    UInt32 fr = in->mBuffers[b].mDataByteSize / (UInt32)(sizeof(float) * nch);
                    if (fr < frames) frames = fr;
                }
                break;
            }
            base += nch;
        }
    }
    if (frames == UINT32_MAX) return noErr;

    float tmp[128 * V7R_CH];
    for (UInt32 off = 0; off < frames; off += 128) {
        UInt32 n = frames - off < 128 ? frames - off : 128;
        for (UInt32 i = 0; i < n; i++)
            for (int c = 0; c < V7R_CH; c++)
                tmp[i * V7R_CH + c] = src[c] ? src[c][(size_t)(off + i) * stride[c]] : 0.0f;
        v7r_write(g_ring, tmp, (int)n);
    }
    atomic_fetch_add_explicit(&g_cb_frames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_cb_calls, 1, memory_order_relaxed);
    return noErr;
}

/* Tell the HAL our IOProc uses none of the device's OUTPUT streams. Without
   this the bridge is also an (all-silent) output client of the loopback it is
   recording from. Best effort: failure only costs a little work. */
static void disable_output_streams(AudioObjectID dev) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeOutput);
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) != noErr || sz < sizeof(AudioHardwareIOProcStreamUsage)) return;
    AudioHardwareIOProcStreamUsage *u = calloc(1, sz);
    if (!u) return;
    u->mIOProc = (void *)g_proc;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, u) == noErr) {
        for (UInt32 i = 0; i < u->mNumberStreams; i++) u->mStreamIsOn[i] = 0;
        AudioObjectSetPropertyData(dev, &a, 0, NULL, sz, u);
    }
    free(u);
}

int audio_open_device(const char *want, int latency_ms, int buffer_frames, int urb_frames,
                      const int *map, int verbose) {
    if (!want || !*want) want = AUDIO_DEFAULT_DEVICE;

    /* This process has no CFRunLoop on its main thread; let the HAL run its
       notifications on its own thread (the documented setup for CLI tools). */
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal);
    CFRunLoopRef none = NULL;
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof none, &none);

    AudioObjectID dev = find_device(want, 0);
    if (dev == kAudioObjectUnknown && !strcmp(want, AUDIO_DEFAULT_DEVICE))
        dev = find_device(AUDIO_DEFAULT_NAME, 0);
    if (dev == kAudioObjectUnknown) {
        fprintf(stderr, "OpenV7: audio: no input device \"%s\". %s\n", want,
                !strcmp(want, AUDIO_DEFAULT_DEVICE)
                    ? "Install the Numark V7 audio driver (./install.sh --audio-driver). Control still works."
                    : "Control still works; the deck's outputs stay silent.");
        find_device(want, 1);   /* list what IS there */
        return -1;
    }
    device_name(dev, g_dev_name, sizeof g_dev_name);
    g_src_channels = input_channels(dev);

    /* Rate: ask for 44.1 kHz so no conversion is needed; accept anything. */
    UInt32 sz = sizeof g_src_rate;
    a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &g_src_rate);
    if (fabs(g_src_rate - V7_SAMPLE_RATE) > 0.5) {
        Float64 r = V7_SAMPLE_RATE;
        if (AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof r, &r) == noErr) {
            for (int i = 0; i < 20; i++) {          /* the change is asynchronous */
                usleep(25000);
                sz = sizeof g_src_rate;
                AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &g_src_rate);
                if (fabs(g_src_rate - V7_SAMPLE_RATE) <= 0.5) break;
            }
        }
    }
    if (g_src_rate < 8000.0 || g_src_rate > 384000.0) {
        fprintf(stderr, "OpenV7: audio: \"%s\" reports an unusable sample rate (%.0f)\n", g_dev_name, g_src_rate);
        return -1;
    }

    /* Small IO buffer: it adds straight to the latency. */
    a = addr(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
    UInt32 want_buf = buffer_frames > 0 ? (UInt32)buffer_frames : AUDIO_DEFAULT_BUFFER;
    AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof want_buf, &want_buf);
    sz = sizeof g_buf_frames;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &g_buf_frames) != noErr || !g_buf_frames) g_buf_frames = 512;

    /* Channel map */
    if (map) memcpy(g_map, map, sizeof g_map);
    else if (g_src_channels >= 4) { g_map[0] = 0; g_map[1] = 1; g_map[2] = 2; g_map[3] = 3; }
    else if (g_src_channels >= 2) { g_map[0] = 0; g_map[1] = 1; g_map[2] = 0; g_map[3] = 1; }
    else                          { g_map[0] = g_map[1] = g_map[2] = g_map[3] = 0; }
    for (int c = 0; c < 4; c++)
        if (g_map[c] < 0 || (UInt32)g_map[c] >= g_src_channels) {
            fprintf(stderr, "OpenV7: audio: channel %d does not exist on \"%s\" (%u channels)\n",
                    g_map[c] + 1, g_dev_name, g_src_channels);
            return -1;
        }

    /* Ring: start `latency` plus one full IO buffer plus one URB's worth ahead
       -- the fill dips by a whole IO buffer between deliveries and by a whole
       URB when the iso side renders one. Counted in SOURCE frames. */
    g_ring = calloc(1, sizeof *g_ring);
    if (!g_ring) return -1;
    int target = (int)(latency_ms * g_src_rate / 1000.0) + (int)g_buf_frames + (urb_frames > 0 ? urb_frames : 0);
    v7r_init(g_ring, g_src_rate, V7_SAMPLE_RATE, target);

    OSStatus st = AudioDeviceCreateIOProcID(dev, ioproc, NULL, &g_proc);
    if (st != noErr) {
        fprintf(stderr, "OpenV7: audio: cannot attach to \"%s\" (CoreAudio error %d)\n", g_dev_name, (int)st);
        free(g_ring); g_ring = NULL;
        return -1;
    }
    disable_output_streams(dev);
    st = AudioDeviceStart(dev, g_proc);
    if (st != noErr) {
        fprintf(stderr, "OpenV7: audio: cannot start \"%s\" (CoreAudio error %d)%s\n", g_dev_name, (int)st,
                st == (OSStatus)kAudioHardwareIllegalOperationError ? " -- microphone permission?" : "");
        AudioDeviceDestroyIOProcID(dev, g_proc);
        free(g_ring); g_ring = NULL;
        return -1;
    }
    g_dev = dev;
    g_mode = MODE_DEVICE;
    fprintf(stderr, "OpenV7: audio: playing \"%s\" (%u ch, %.0f Hz, %u-frame buffer) -> V7 outputs, "
                    "map %d,%d -> deck A, %d,%d -> deck B, ring ~%.1f ms.\n",
            g_dev_name, g_src_channels, g_src_rate, g_buf_frames,
            g_map[0] + 1, g_map[1] + 1, g_map[2] + 1, g_map[3] + 1, 1000.0 * target / g_src_rate);
    if (buffer_frames > 0 && g_buf_frames != (UInt32)buffer_frames)
        fprintf(stderr, "OpenV7: audio: asked CoreAudio for a %d-frame buffer, got %u.\n", buffer_frames, g_buf_frames);
    if (verbose && fabs(g_src_rate - V7_SAMPLE_RATE) > 0.5)
        fprintf(stderr, "OpenV7: audio: converting %.0f Hz -> 44100 Hz. Set the device to 44.1 kHz in "
                        "Audio MIDI Setup to avoid it.\n", g_src_rate);
    return 0;
}

void audio_set_deck_rate(double fps) {
    if (g_mode != MODE_DEVICE || !g_ring || fps < 40000.0 || fps > 48000.0) return;
    /* The producer delivers src_rate per host-second; the deck takes fps. The
       resampler's base ratio already covers src_rate/44100, so what is left
       is the deck's offset from 44100. (Host clock and USB clock are assumed
       equal; the fill-steering trims whatever they are not.) */
    v7r_set_ff(g_ring, V7_SAMPLE_RATE / fps - 1.0);
}

void audio_render(uint8_t *dst, int frames) {
    if (g_mode == MODE_TONE) render_tone(dst, frames);
    else if (g_mode == MODE_DEVICE && g_ring) v7r_read_s24(g_ring, dst, frames);
    else memset(dst, 0, (size_t)frames * V7_ISO_FRAME_BYTES);
}

void audio_diag(char *buf, size_t n) {
    if (g_mode == MODE_TONE) {
        float p = g_tone_peak; g_tone_peak = 0;
        snprintf(buf, n, "audio=tone peak=%.1fdBFS", p > 0 ? 20.0 * log10(p) : -200.0);
        return;
    }
    if (g_mode != MODE_DEVICE || !g_ring) { snprintf(buf, n, "audio=off"); return; }
    static uint64_t last_frames;
    uint64_t f = atomic_load(&g_cb_frames);
    double pk = v7r_take_peak_db(g_ring);
    snprintf(buf, n, "audio in/s=%llu fill=%.0f adj=%+.1fppm (ff %+.1f) peak=%.1fdBFS%s u=%llu o=%llu",
             (unsigned long long)(f - last_frames), v7r_fill(g_ring), g_ring->adj * 1e6, g_ring->ff * 1e6,
             pk, g_ring->running ? "" : " (priming)",
             (unsigned long long)g_ring->underruns,
             (unsigned long long)atomic_load(&g_ring->overruns));
    last_frames = f;
}

void audio_close(void) {
    if (g_mode == MODE_DEVICE && g_dev != kAudioObjectUnknown) {
        AudioDeviceStop(g_dev, g_proc);
        AudioDeviceDestroyIOProcID(g_dev, g_proc);
        g_dev = kAudioObjectUnknown;
    }
    g_mode = MODE_OFF;
    /* g_ring is left allocated: an in-flight IOProc may still be returning. */
}
