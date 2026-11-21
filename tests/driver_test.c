/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — tests for the "Numark V7" CoreAudio plug-in (driver/NumarkV7Audio.c).
 *
 * Loads nothing into coreaudiod: the driver source is compiled straight into
 * this test and driven through its own AudioServerPlugInDriverInterface, the
 * same table the HAL calls. `make drivertest`.
 */
#include "../driver/NumarkV7Audio.c"
#include <stdio.h>
#include <stdlib.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (cond) { printf("  ok   "); printf(__VA_ARGS__); printf("\n"); } \
                              else { fails++; printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static AudioServerPlugInDriverRef D;
#define CALL(fn, ...) ((*D)->fn(D, __VA_ARGS__))

static AudioObjectPropertyAddress A(AudioObjectPropertySelector s, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { s, sc, 0 };
    return a;
}

static UInt32 get_u32(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc, OSStatus *st) {
    AudioObjectPropertyAddress a = A(s, sc);
    UInt32 v = 0xDEADBEEF, sz = sizeof v;
    *st = CALL(GetPropertyData, o, 0, &a, 0, NULL, sizeof v, &sz, &v);
    return v;
}

static void test_identity(void) {
    printf("plug-in identity\n");
    void *drv = NumarkV7_Create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(drv != NULL, "factory returns a driver for the AudioServerPlugIn type");
    CHECK(NumarkV7_Create(NULL, IUnknownUUID) == NULL, "factory refuses other types");
    D = (AudioServerPlugInDriverRef)drv;
    LPVOID iface = NULL;
    HRESULT h = (*D)->QueryInterface(D, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface);
    CHECK(h == S_OK && iface == (LPVOID)D, "QueryInterface hands back the driver interface");
    CHECK(CALL(Initialize, NULL) == 0, "Initialize");
}

static void test_properties(void) {
    printf("properties\n");
    OSStatus st;
    AudioObjectPropertyAddress a = A(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
    AudioObjectID ids[4]; UInt32 sz = sizeof ids;
    st = CALL(GetPropertyData, kObjectID_PlugIn, 0, &a, 0, NULL, sz, &sz, ids);
    CHECK(st == 0 && sz == sizeof(AudioObjectID) && ids[0] == kObjectID_Device, "plug-in lists exactly one device");

    CFStringRef uid = CFSTR(kDevice_UID);
    a = A(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectID dev = 0; sz = sizeof dev;
    st = CALL(GetPropertyData, kObjectID_PlugIn, 0, &a, sizeof uid, &uid, sz, &sz, &dev);
    CHECK(st == 0 && dev == kObjectID_Device, "UID \"%s\" resolves to the device", kDevice_UID);
    CFStringRef other = CFSTR("nope");
    dev = 99; sz = sizeof dev;
    CALL(GetPropertyData, kObjectID_PlugIn, 0, &a, sizeof other, &other, sz, &sz, &dev);
    CHECK(dev == kAudioObjectUnknown, "unknown UID resolves to nothing");

    a = A(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
    CFStringRef name = NULL; sz = sizeof name;
    st = CALL(GetPropertyData, kObjectID_Device, 0, &a, 0, NULL, sz, &sz, &name);
    char buf[64] = "";
    if (name) CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
    CHECK(st == 0 && !strcmp(buf, "Numark V7"), "device is called \"%s\"", buf);

    a = A(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);  sz = sizeof ids;
    CALL(GetPropertyData, kObjectID_Device, 0, &a, 0, NULL, sz, &sz, ids);
    CHECK(sz == sizeof(AudioObjectID) && ids[0] == kObjectID_Stream_Input, "input scope: the input stream only");
    a = A(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput); sz = sizeof ids;
    CALL(GetPropertyData, kObjectID_Device, 0, &a, 0, NULL, sz, &sz, ids);
    CHECK(sz == sizeof(AudioObjectID) && ids[0] == kObjectID_Stream_Output, "output scope: the output stream only");
    a = A(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal); sz = sizeof ids;
    CALL(GetPropertyData, kObjectID_Device, 0, &a, 0, NULL, sz, &sz, ids);
    CHECK(sz == 2 * sizeof(AudioObjectID), "global scope: both streams");

    AudioClassID want = kAudioStreamClassID;
    a = A(kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal); sz = sizeof ids;
    CALL(GetPropertyData, kObjectID_Device, 0, &a, sizeof want, &want, sz, &sz, ids);
    CHECK(sz == 2 * sizeof(AudioObjectID), "owned objects filtered to streams: 2");
    want = kAudioDeviceClassID; sz = sizeof ids;
    CALL(GetPropertyData, kObjectID_Device, 0, &a, sizeof want, &want, sz, &sz, ids);
    CHECK(sz == 0, "owned objects filtered to devices: none");

    CHECK(get_u32(kObjectID_Device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, &st) == 1,
          "output can be the default output");
    CHECK(get_u32(kObjectID_Device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput, &st) == 0,
          "input can NOT be the default microphone");
    CHECK(get_u32(kObjectID_Stream_Input, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, &st) == 1 &&
          get_u32(kObjectID_Stream_Output, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, &st) == 0,
          "stream directions");

    a = A(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription f; sz = sizeof f;
    st = CALL(GetPropertyData, kObjectID_Stream_Output, 0, &a, 0, NULL, sz, &sz, &f);
    CHECK(st == 0 && f.mSampleRate == 44100.0 && f.mChannelsPerFrame == 4 && f.mBitsPerChannel == 32 &&
          (f.mFormatFlags & kAudioFormatFlagIsFloat) && f.mBytesPerFrame == 16,
          "format: 44.1 kHz, 4 ch, float32");

    a = A(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput);
    st = CALL(GetPropertyDataSize, kObjectID_Device, 0, &a, 0, NULL, &sz);
    AudioChannelLayout *l = calloc(1, sz);
    st |= CALL(GetPropertyData, kObjectID_Device, 0, &a, 0, NULL, sz, &sz, l);
    CHECK(st == 0 && l->mNumberChannelDescriptions == 4, "channel layout describes 4 channels");
    free(l);

    a = A('zzzz', kAudioObjectPropertyScopeGlobal);
    CHECK(!CALL(HasProperty, kObjectID_Device, 0, &a), "unknown property is not claimed");
    a = A(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
    CHECK(!CALL(HasProperty, 42, 0, &a), "unknown object has no properties");
    CHECK(CALL(HasProperty, kObjectID_Device, 0, &a), "HasProperty agrees with GetPropertyData");

    Boolean settable = 1;
    a = A(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    CALL(IsPropertySettable, kObjectID_Device, 0, &a, &settable);
    CHECK(!settable, "sample rate is fixed");
    Float64 r48 = 48000.0;
    CHECK(CALL(SetPropertyData, kObjectID_Device, 0, &a, 0, NULL, sizeof r48, &r48) != 0, "setting 48 kHz is refused");
}

static void test_loopback(void) {
    printf("loopback IO\n");
    CHECK(CALL(StartIO, kObjectID_Device, 1) == 0, "StartIO");
    OSStatus st;
    CHECK(get_u32(kObjectID_Device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, &st) == 1, "device reports running");

    Boolean will = 0, inplace = 0;
    CALL(WillDoIOOperation, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix, &will, &inplace);
    CHECK(will, "will do WriteMix");
    CALL(WillDoIOOperation, kObjectID_Device, 1, kAudioServerPlugInIOOperationReadInput, &will, &inplace);
    CHECK(will, "will do ReadInput");

    enum { N = 512 };
    static Float32 w[N * 4], r[N * 4];
    AudioServerPlugInIOCycleInfo io; memset(&io, 0, sizeof io);

    /* write 40 cycles of a ramp at output times 1000.., read them back later */
    for (int c = 0; c < 40; c++) {
        for (int i = 0; i < N * 4; i++) w[i] = (Float32)(c * N * 4 + i) / 100000.0f;
        io.mOutputTime.mSampleTime = 1000.0 + c * N;
        CALL(DoIOOperation, kObjectID_Device, kObjectID_Stream_Output, 1, kAudioServerPlugInIOOperationWriteMix, N, &io, w, NULL);
    }
    int ok = 1;
    for (int c = 0; c < 40; c++) {
        io.mInputTime.mSampleTime = 1000.0 + c * N;
        CALL(DoIOOperation, kObjectID_Device, kObjectID_Stream_Input, 1, kAudioServerPlugInIOOperationReadInput, N, &io, r, NULL);
        for (int i = 0; i < N * 4; i++) if (r[i] != (Float32)(c * N * 4 + i) / 100000.0f) ok = 0;
    }
    CHECK(!ok, "audio older than one ring (16384 frames) reads as silence");
    ok = 1;
    for (int c = 8; c < 40; c++) {
        io.mInputTime.mSampleTime = 1000.0 + c * N;
        CALL(DoIOOperation, kObjectID_Device, kObjectID_Stream_Input, 1, kAudioServerPlugInIOOperationReadInput, N, &io, r, NULL);
        for (int i = 0; i < N * 4; i++) if (r[i] != (Float32)(c * N * 4 + i) / 100000.0f) ok = 0;
    }
    CHECK(ok, "what was played comes back exactly at the same sample times");

    /* reading past what was written: silence, not old audio */
    io.mInputTime.mSampleTime = 1000.0 + 40 * N + 100;
    CALL(DoIOOperation, kObjectID_Device, kObjectID_Stream_Input, 1, kAudioServerPlugInIOOperationReadInput, N, &io, r, NULL);
    int silent = 1; for (int i = 0; i < N * 4; i++) if (r[i] != 0) silent = 0;
    CHECK(silent, "after the player stops, the input is silent (no stale loop)");

    /* a buffer straddling the write head: audio then silence */
    io.mInputTime.mSampleTime = 1000.0 + 40 * N - 100;
    CALL(DoIOOperation, kObjectID_Device, kObjectID_Stream_Input, 1, kAudioServerPlugInIOOperationReadInput, N, &io, r, NULL);
    int straddle = r[99 * 4] != 0 && r[100 * 4] == 0 && r[N * 4 - 1] == 0;
    CHECK(straddle, "a read straddling the write head is audio up to it, silence after");

    /* a gap in writing reads back as silence, even after the ring laps it */
    for (int i = 0; i < N * 4; i++) w[i] = 0.5f;
    io.mOutputTime.mSampleTime = 1000.0 + 40 * N + 3000;
    CALL(DoIOOperation, kObjectID_Device, kObjectID_Stream_Output, 1, kAudioServerPlugInIOOperationWriteMix, N, &io, w, NULL);
    io.mInputTime.mSampleTime = 1000.0 + 40 * N + 1000;
    CALL(DoIOOperation, kObjectID_Device, kObjectID_Stream_Input, 1, kAudioServerPlugInIOOperationReadInput, N, &io, r, NULL);
    silent = 1; for (int i = 0; i < N * 4; i++) if (r[i] != 0) silent = 0;
    CHECK(silent, "a gap between writes reads as silence, not as ring leftovers");

    Float64 st0; UInt64 ht0, seed;
    CHECK(CALL(GetZeroTimeStamp, kObjectID_Device, 1, &st0, &ht0, &seed) == 0 && seed == 1, "zero timestamp");

    CHECK(CALL(StopIO, kObjectID_Device, 1) == 0, "StopIO");
    CHECK(CALL(StopIO, kObjectID_Device, 1) != 0, "unbalanced StopIO is refused");
}

int main(void) {
    test_identity();
    test_properties();
    test_loopback();
    printf(fails ? "\n%d FAILED\n" : "\nall driver tests passed\n", fails);
    return fails ? 1 : 0;
}
