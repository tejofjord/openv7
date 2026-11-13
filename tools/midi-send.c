/* SPDX-License-Identifier: MIT
 *
 * Send raw MIDI bytes to a CoreMIDI destination -- by default the bridge's
 * "Numark V7" -- exactly as a DJ app would. The bridge queues them onto the
 * device's bulk OUT endpoint, one message per frame, and logs each one as
 * "out ..." when run with -v.
 *
 * This is the Mac twin of the Windows probes in tools/win/: it is how LED and
 * motor commands are tested without a DJ app in the loop.
 *
 *   clang -framework CoreMIDI -framework CoreFoundation tools/midi-send.c -o build/midi-send
 *   build/midi-send b0 07 7f              # one message (deck-A SYNC LED on, on a V7)
 *   build/midi-send b0 42 00 b0 44 00     # several, sent in order
 *   build/midi-send -d "Other Port" 90 3c 7f
 *   build/midi-send -l                    # list destinations
 *
 * Bytes are hex. Each complete message is sent in its own MIDIPacketList, in
 * order. Exit status is non-zero if the destination is not found -- in
 * practice, "the bridge is not running".
 *
 * Motor commands make the platters spin. Clear the platters first.
 */
#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int msg_len(unsigned char status) {
    switch (status & 0xF0) {
        case 0xC0: case 0xD0: return 2;
        case 0x80: case 0x90: case 0xA0: case 0xB0: case 0xE0: return 3;
        default: return 0;   /* system / SysEx: not needed here */
    }
}

static MIDIEndpointRef find_dest(const char *want, int list) {
    ItemCount n = MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < n; i++) {
        MIDIEndpointRef d = MIDIGetDestination(i);
        CFStringRef name = NULL;
        if (MIDIObjectGetStringProperty(d, kMIDIPropertyName, &name) != noErr || !name) continue;
        char buf[256] = "";
        CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(name);
        if (list) printf("%s\n", buf);
        else if (!strcmp(buf, want)) return d;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *dest_name = "Numark V7";
    int i = 1;
    if (i < argc && !strcmp(argv[i], "-l")) { find_dest(NULL, 1); return 0; }
    if (i + 1 < argc && !strcmp(argv[i], "-d")) { dest_name = argv[i + 1]; i += 2; }
    if (i >= argc) {
        fprintf(stderr, "usage: %s [-d DEST] HEXBYTE... | -l\n", argv[0]);
        return 2;
    }

    unsigned char bytes[256]; int nb = 0;
    for (; i < argc && nb < (int)sizeof bytes; i++) {
        char *end; long v = strtol(argv[i], &end, 16);
        if (*end || v < 0 || v > 0xFF) { fprintf(stderr, "not a hex byte: %s\n", argv[i]); return 2; }
        bytes[nb++] = (unsigned char)v;
    }

    /* Validate every message before touching CoreMIDI, so a typo sends nothing
       rather than the messages before it. */
    for (int k = 0; k < nb; ) {
        int len = msg_len(bytes[k]);
        if (!len || k + len > nb) { fprintf(stderr, "incomplete or unsupported message at byte %d\n", k); return 2; }
        k += len;
    }

    MIDIEndpointRef dest = find_dest(dest_name, 0);
    if (!dest) { fprintf(stderr, "no CoreMIDI destination \"%s\" -- is the bridge running?\n", dest_name); return 1; }

    MIDIClientRef client; MIDIPortRef port;
    if (MIDIClientCreate(CFSTR("openv7 midi-send"), NULL, NULL, &client) != noErr ||
        MIDIOutputPortCreate(client, CFSTR("out"), &port) != noErr) {
        fprintf(stderr, "CoreMIDI client setup failed\n"); return 1;
    }

    for (int k = 0; k < nb; ) {
        int len = msg_len(bytes[k]);
        if (!len || k + len > nb) { fprintf(stderr, "incomplete or unsupported message at byte %d\n", k); return 2; }
        Byte storage[64];
        MIDIPacketList *pl = (MIDIPacketList *)storage;
        MIDIPacket *p = MIDIPacketListInit(pl);
        p = MIDIPacketListAdd(pl, sizeof storage, p, 0, (ByteCount)len, &bytes[k]);
        if (!p || MIDISend(port, dest, pl) != noErr) { fprintf(stderr, "send failed\n"); return 1; }
        k += len;
    }

    usleep(50 * 1000);   /* let CoreMIDI deliver before the client goes away */
    MIDIPortDispose(port);
    MIDIClientDispose(client);
    return 0;
}
