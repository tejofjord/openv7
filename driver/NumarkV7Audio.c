/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — "Numark V7" CoreAudio device (an AudioServerPlugIn, a.k.a. HAL
 * plug-in), installed to /Library/Audio/Plug-Ins/HAL/NumarkV7.driver.
 *
 * What it is: a 4-channel, 44.1 kHz LOOPBACK. Apps play into its output
 * ("Numark V7", channels 1/2 = DECK A, 3/4 = DECK B); the OpenV7 bridge records
 * the same audio from its input and writes it into the V7's isochronous
 * stream. The plug-in never touches USB -- the bridge owns the deck (MIDI,
 * motor, LEDs and now audio), and CoreAudio itself is the pipe between them, so
 * there is no private IPC to get wrong and nothing here runs as root.
 *
 *   DJ app ──► "Numark V7" output ─┐ (this plug-in: ring buffer)
 *                                   └► "Numark V7" input ──► openv7 --audio ──► USB ──► V7 RCA outs
 *
 * The device's clock is the host clock at a nominal 44.1 kHz. The bridge's
 * drift-corrected reader (src/v7ring.c) absorbs whatever difference there is
 * between that and the USB clock that paces the deck.
 *
 * Structure follows Apple's NullAudio sample driver: one plug-in object, one
 * device, two streams, no controls. Plain C, no dependencies beyond CoreAudio.
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* ------------------------------------------------------------------ constants */

#define kPlugIn_FactoryName     NumarkV7_Create
#define kManufacturer           "OpenV7"
#define kDevice_Name            "Numark V7"
#define kDevice_UID             "com.openv7.audio.NumarkV7"      /* src/audio.h looks for this */
#define kDevice_ModelUID        "com.openv7.audio.NumarkV7.model"
#define kChannels               4
#define kSampleRate             44100.0
#define kBytesPerFrame          (kChannels * (UInt32)sizeof(Float32))
#define kRingFrames             16384u                           /* also the zero-timestamp period */

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

/* ---------------------------------------------------------------------- state */

static pthread_mutex_t            gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32                     gRefCount = 0;
static AudioServerPlugInHostRef   gHost = NULL;

static UInt64                     gIOCount = 0;           /* clients doing IO */
static Float64                    gHostTicksPerFrame = 0.0;
static UInt64                     gAnchorHostTime = 0;
static UInt64                     gNumberTimeStamps = 0;
static UInt32                     gStreamActive[2] = { 1, 1 };   /* [0] input, [1] output */

/* Loopback ring, indexed by device sample time. gWriteEnd is one past the last
   sample time written by the output side; anything at or beyond it (or more
   than a ring behind it) reads as silence, so a stopped player is never heard
   as a stale loop of its last 370 ms. */
static os_unfair_lock             gRingLock = OS_UNFAIR_LOCK_INIT;
static Float32                    gRing[kRingFrames * kChannels];
static SInt64                     gWriteEnd = 0;

/* ------------------------------------------------------------------ prototypes */

static HRESULT  V7_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG    V7_AddRef(void *inDriver);
static ULONG    V7_Release(void *inDriver);
static OSStatus V7_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus V7_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus V7_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus V7_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus V7_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus V7_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus V7_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean  V7_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus V7_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus V7_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus V7_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus V7_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus V7_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus V7_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus V7_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus V7_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus V7_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus V7_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus V7_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

/* ---------------------------------------------------------- the COM interface */

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    V7_QueryInterface,
    V7_AddRef,
    V7_Release,
    V7_Initialize,
    V7_CreateDevice,
    V7_DestroyDevice,
    V7_AddDeviceClient,
    V7_RemoveDeviceClient,
    V7_PerformDeviceConfigurationChange,
    V7_AbortDeviceConfigurationChange,
    V7_HasProperty,
    V7_IsPropertySettable,
    V7_GetPropertyDataSize,
    V7_GetPropertyData,
    V7_SetPropertyData,
    V7_StartIO,
    V7_StopIO,
    V7_GetZeroTimeStamp,
    V7_WillDoIOOperation,
    V7_BeginIOOperation,
    V7_DoIOOperation,
    V7_EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef    = &gInterfacePtr;

/* The factory named in Info.plist (CFPlugInFactories). */
__attribute__((visibility("default")))
void *NumarkV7_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void *NumarkV7_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT V7_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (!req) return kAudioHardwareIllegalOperationError;
    HRESULT r;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        r = S_OK;
    } else {
        r = E_NOINTERFACE;
    }
    CFRelease(req);
    return r;
}

static ULONG V7_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) ++gRefCount;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG V7_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;    /* the driver is a static singleton; nothing to free */
}

/* ------------------------------------------------------------ basic operations */

static OSStatus V7_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostHz = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    gHostTicksPerFrame = hostHz / kSampleRate;
    return 0;
}

static OSStatus V7_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus V7_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus V7_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
static OSStatus V7_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
static OSStatus V7_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
static OSStatus V7_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

/* ------------------------------------------------------------------ properties
 *
 * One function answers every property question. With outData == NULL it only
 * reports the size, which is how HasProperty and GetPropertyDataSize are
 * answered too -- so the three can never disagree about what exists.
 */

static AudioStreamBasicDescription stream_format(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate       = kSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket   = kBytesPerFrame;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel   = 32;
    return f;
}

static AudioClassID class_of(AudioObjectID obj) {
    switch (obj) {
        case kObjectID_PlugIn:        return kAudioPlugInClassID;
        case kObjectID_Device:        return kAudioDeviceClassID;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: return kAudioStreamClassID;
    }
    return 0;
}

/* Does `obj` pass an OwnedObjects class-ID qualifier? */
static int class_wanted(AudioObjectID obj, UInt32 qsz, const void *q) {
    if (!q || qsz < sizeof(AudioClassID)) return 1;
    const AudioClassID *c = (const AudioClassID *)q;
    UInt32 n = qsz / (UInt32)sizeof(AudioClassID);
    for (UInt32 i = 0; i < n; i++)
        if (c[i] == kAudioObjectClassID || c[i] == class_of(obj)) return 1;
    return 0;
}

#define PUT(type, value) do {                                                    \
        if (outData) {                                                           \
            if (inSize < (UInt32)sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *(type *)outData = (value);                                          \
        }                                                                        \
        *outSize = (UInt32)sizeof(type);                                         \
        return 0;                                                                \
    } while (0)

static OSStatus put_ids(const AudioObjectID *ids, UInt32 n, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (outData) {
        UInt32 fit = inSize / (UInt32)sizeof(AudioObjectID);
        if (fit < n) n = fit;
        if (n) memcpy(outData, ids, n * sizeof(AudioObjectID));
    }
    *outSize = n * (UInt32)sizeof(AudioObjectID);
    return 0;
}

static OSStatus prop(AudioObjectID obj, const AudioObjectPropertyAddress *a,
                     UInt32 qsz, const void *q, UInt32 inSize, UInt32 *outSize, void *outData) {
    const AudioObjectPropertySelector sel = a->mSelector;

    switch (obj) {
    /* ---------------------------------------------------------------- plug-in */
    case kObjectID_PlugIn:
        switch (sel) {
        case kAudioObjectPropertyBaseClass:    PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:        PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(kManufacturer));
        case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFSTR(""));
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID ids[1]; UInt32 n = 0;
            if (class_wanted(kObjectID_Device, qsz, q)) ids[n++] = kObjectID_Device;
            return put_ids(ids, n, inSize, outSize, outData);
        }
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID ids[1] = { kObjectID_Device };
            return put_ids(ids, 1, inSize, outSize, outData);
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID dev = kAudioObjectUnknown;
            if (outData) {
                if (qsz != sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *(const CFStringRef *)q;
                if (uid && CFEqual(uid, CFSTR(kDevice_UID))) dev = kObjectID_Device;
            }
            PUT(AudioObjectID, dev);
        }
        }
        return kAudioHardwareUnknownPropertyError;

    /* ----------------------------------------------------------------- device */
    case kObjectID_Device:
        switch (sel) {
        case kAudioObjectPropertyBaseClass:    PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:        PUT(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:         PUT(CFStringRef, CFSTR(kDevice_Name));
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(kManufacturer));
        case kAudioDevicePropertyDeviceUID:    PUT(CFStringRef, CFSTR(kDevice_UID));
        case kAudioDevicePropertyModelUID:     PUT(CFStringRef, CFSTR(kDevice_ModelUID));
        case kAudioDevicePropertyConfigurationApplication: PUT(CFStringRef, CFSTR("com.apple.audio.AudioMIDISetup"));
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain:  PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            PUT(UInt32, running);
        }
        /* The output is what people pick. The input exists for the bridge and
           should never become the Mac's default microphone. */
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            PUT(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0);
        case kAudioDevicePropertyLatency:      PUT(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyIsHidden:     PUT(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kRingFrames);
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            PUT(AudioValueRange, r);
        }
        case kAudioDevicePropertyRelatedDevices: {
            AudioObjectID ids[1] = { kObjectID_Device };
            return put_ids(ids, 1, inSize, outSize, outData);
        }
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2]; UInt32 n = 0;
            int filter = sel == kAudioObjectPropertyOwnedObjects;
            if (a->mScope != kAudioObjectPropertyScopeOutput &&
                (!filter || class_wanted(kObjectID_Stream_Input, qsz, q)))  ids[n++] = kObjectID_Stream_Input;
            if (a->mScope != kAudioObjectPropertyScopeInput &&
                (!filter || class_wanted(kObjectID_Stream_Output, qsz, q))) ids[n++] = kObjectID_Stream_Output;
            return put_ids(ids, n, inSize, outSize, outData);
        }
        case kAudioObjectPropertyControlList:
            return put_ids(NULL, 0, inSize, outSize, outData);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 sz = 2 * (UInt32)sizeof(UInt32);
            if (outData) {
                if (inSize < sz) return kAudioHardwareBadPropertySizeError;
                ((UInt32 *)outData)[0] = 1;
                ((UInt32 *)outData)[1] = 2;
            }
            *outSize = sz;
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 sz = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions)
                      + kChannels * (UInt32)sizeof(AudioChannelDescription);
            if (outData) {
                if (inSize < sz) return kAudioHardwareBadPropertySizeError;
                static const AudioChannelLabel labels[kChannels] = {
                    kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                    kAudioChannelLabel_Discrete_0 | 2, kAudioChannelLabel_Discrete_0 | 3
                };
                AudioChannelLayout *l = (AudioChannelLayout *)outData;
                memset(l, 0, sz);
                l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                l->mNumberChannelDescriptions = kChannels;
                for (UInt32 i = 0; i < kChannels; i++) l->mChannelDescriptions[i].mChannelLabel = labels[i];
            }
            *outSize = sz;
            return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;

    /* ---------------------------------------------------------------- streams */
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output: {
        const int isInput = obj == kObjectID_Stream_Input;
        switch (sel) {
        case kAudioObjectPropertyBaseClass:    PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:        PUT(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: return put_ids(NULL, 0, inSize, outSize, outData);
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 v = gStreamActive[isInput ? 0 : 1];
            pthread_mutex_unlock(&gStateMutex);
            PUT(UInt32, v);
        }
        case kAudioStreamPropertyDirection:    PUT(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType: PUT(UInt32, kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency:      PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            PUT(AudioStreamBasicDescription, stream_format());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription d;
            memset(&d, 0, sizeof d);
            d.mFormat = stream_format();
            d.mSampleRateRange.mMinimum = kSampleRate;
            d.mSampleRateRange.mMaximum = kSampleRate;
            if (outData) {
                if (inSize < sizeof d) { *outSize = 0; return 0; }   /* array semantics: zero fit */
                memcpy(outData, &d, sizeof d);
            }
            *outSize = (UInt32)sizeof d;
            return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    }
    return kAudioHardwareBadObjectError;
}

static Boolean V7_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || !inAddress) return false;
    UInt32 size = 0;
    return prop(inObjectID, inAddress, 0, NULL, 0, &size, NULL) == 0;
}

static OSStatus V7_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outIsSettable) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus st = prop(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
    if (st) return st;
    *outIsSettable = false;
    if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
        }
    }
    return 0;
}

static OSStatus V7_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize) return kAudioHardwareIllegalOperationError;
    return prop(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
}

static OSStatus V7_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;
    return prop(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
}

static int format_ok(const AudioStreamBasicDescription *f) {
    AudioStreamBasicDescription ours = stream_format();
    return f->mFormatID == ours.mFormatID && f->mChannelsPerFrame == ours.mChannelsPerFrame
        && f->mBitsPerChannel == ours.mBitsPerChannel && f->mBytesPerFrame == ours.mBytesPerFrame
        && (f->mFormatFlags & kAudioFormatFlagIsFloat)
        && f->mSampleRate > kSampleRate - 0.5 && f->mSampleRate < kSampleRate + 0.5;
}

static OSStatus V7_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !inData) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 r = *(const Float64 *)inData;
        return (r > kSampleRate - 0.5 && r < kSampleRate + 0.5) ? 0 : kAudioHardwareIllegalOperationError;
    }
    if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive: {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            gStreamActive[inObjectID == kObjectID_Stream_Input ? 0 : 1] = *(const UInt32 *)inData != 0;
            pthread_mutex_unlock(&gStateMutex);
            return 0;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            return format_ok((const AudioStreamBasicDescription *)inData) ? 0 : kAudioDeviceUnsupportedFormatError;
        }
    }
    UInt32 size = 0;
    OSStatus st = prop(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
    return st ? st : kAudioHardwareUnsupportedOperationError;
}

/* -------------------------------------------------------------------------- IO */

static OSStatus V7_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    OSStatus st = 0;
    if (gIOCount == UINT64_MAX) {
        st = kAudioHardwareIllegalOperationError;
    } else if (gIOCount++ == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        os_unfair_lock_lock(&gRingLock);
        memset(gRing, 0, sizeof gRing);
        gWriteEnd = 0;
        os_unfair_lock_unlock(&gRingLock);
    }
    pthread_mutex_unlock(&gStateMutex);
    return st;
}

static OSStatus V7_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    OSStatus st = 0;
    if (gIOCount == 0) st = kAudioHardwareIllegalOperationError;
    else --gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return st;
}

/* The device clock: a zero timestamp every kRingFrames frames of host time at
   exactly 44.1 kHz, anchored when IO started (as in Apple's NullAudio). */
static OSStatus V7_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64  now   = mach_absolute_time();
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64  next  = gAnchorHostTime + (UInt64)(((Float64)(gNumberTimeStamps + 1)) * ticksPerRing);
    if (next <= now) ++gNumberTimeStamps;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime   = gAnchorHostTime + (UInt64)(((Float64)gNumberTimeStamps) * ticksPerRing);
    *outSeed       = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus V7_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = inOperationID == kAudioServerPlugInIOOperationReadInput ||
                   inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus V7_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus V7_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static void ring_copy_in(SInt64 t, const Float32 *src, UInt32 n) {
    UInt32 pos = (UInt32)((UInt64)t % kRingFrames);
    UInt32 first = n < kRingFrames - pos ? n : kRingFrames - pos;
    memcpy(&gRing[pos * kChannels], src, first * kBytesPerFrame);
    if (n > first) memcpy(&gRing[0], src + first * kChannels, (n - first) * kBytesPerFrame);
}

static void ring_zero(SInt64 t, UInt32 n) {
    UInt32 pos = (UInt32)((UInt64)t % kRingFrames);
    UInt32 first = n < kRingFrames - pos ? n : kRingFrames - pos;
    memset(&gRing[pos * kChannels], 0, first * kBytesPerFrame);
    if (n > first) memset(&gRing[0], 0, (n - first) * kBytesPerFrame);
}

static void ring_copy_out(SInt64 t, Float32 *dst, UInt32 n) {
    UInt32 pos = (UInt32)((UInt64)t % kRingFrames);
    UInt32 first = n < kRingFrames - pos ? n : kRingFrames - pos;
    memcpy(dst, &gRing[pos * kChannels], first * kBytesPerFrame);
    if (n > first) memcpy(dst + first * kChannels, &gRing[0], (n - first) * kBytesPerFrame);
}

/* Output side: the HAL's mix of every app playing to "Numark V7". */
static void ring_write(SInt64 t, const Float32 *src, UInt32 n) {
    if (t < 0 || n == 0) return;
    if (n > kRingFrames) { src += (n - kRingFrames) * kChannels; t += n - kRingFrames; n = kRingFrames; }
    os_unfair_lock_lock(&gRingLock);
    if (t > gWriteEnd) {                     /* a gap: clear it so it reads as silence */
        SInt64 gap = t - gWriteEnd;
        if (gap > (SInt64)kRingFrames) gap = kRingFrames;
        ring_zero(t - gap, (UInt32)gap);
    }
    ring_copy_in(t, src, n);
    if (t + (SInt64)n > gWriteEnd) gWriteEnd = t + (SInt64)n;
    os_unfair_lock_unlock(&gRingLock);
}

/* Input side: what the bridge records. Only sample times that were actually
   written (and not yet lapped) return audio; everything else is silence. */
static void ring_read(SInt64 t, Float32 *dst, UInt32 n) {
    os_unfair_lock_lock(&gRingLock);
    SInt64 end = gWriteEnd, lo = end - (SInt64)kRingFrames;   /* valid: [lo, end) */
    if (lo < 0) lo = 0;
    for (UInt32 i = 0; i < n; ) {
        SInt64 s = t + (SInt64)i;
        UInt32 run;
        if (s >= lo && s < end) {
            run = (UInt32)((end - s) < (SInt64)(n - i) ? (end - s) : (SInt64)(n - i));
            ring_copy_out(s, dst + (size_t)i * kChannels, run);
        } else {
            /* silent up to the next valid sample, or to the end of the buffer */
            run = n - i;
            if (s < lo && lo < t + (SInt64)n) run = (UInt32)(lo - s);
            memset(dst + (size_t)i * kChannels, 0, (size_t)run * kBytesPerFrame);
        }
        i += run;
    }
    os_unfair_lock_unlock(&gRingLock);
}

static OSStatus V7_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!inIOCycleInfo || !ioMainBuffer) return 0;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_Stream_Output)
        ring_write((SInt64)inIOCycleInfo->mOutputTime.mSampleTime, (const Float32 *)ioMainBuffer, inIOBufferFrameSize);
    else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_Stream_Input)
        ring_read((SInt64)inIOCycleInfo->mInputTime.mSampleTime, (Float32 *)ioMainBuffer, inIOBufferFrameSize);
    return 0;
}
