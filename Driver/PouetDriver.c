// PouetDriver.c
// Audio Server Plugin that creates a virtual microphone AND a virtual speaker device.
// Pouet (input):   App writes mic audio → SHM → driver serves to apps as microphone
// PouetSpeaker (output): Apps play audio → driver writes to SHM → App reads for dashcam/proxy
// Install to: /Library/Audio/Plug-Ins/HAL/Pouet.driver

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <os/log.h>

static os_log_t sDriverLog;

// ---------------------------------------------------------------------------
// Shared memory layout (must match App side: SharedMemory.h)
// ---------------------------------------------------------------------------
#define POUET_SHM_NAME           "/PouetAudio"
#define POUET_SPEAKER_SHM_NAME   "/PouetSpeakerAudio"
#define POUET_SHM_SIZE   (4096 * 256)   // ~1 second at 48kHz stereo f32

#define POUET_SAMPLE_RATE    48000.0
#define POUET_NUM_CHANNELS   2
#define POUET_BUFFER_FRAMES  512
#define POUET_SAFETY_OFFSET  64     // frames of breathing room for producer (~1.3ms at 48kHz)
#define POUET_MAX_LAG_MULT  3      // allow 3 buffer periods of clock drift before compression
#define POUET_LAP_SKIP_DIV  2      // on producer lap, skip to middle of valid data (cap/2)

// Ring buffer header lives at the start of the shared memory region.
typedef struct {
    _Atomic uint64_t writePos;  // samples written (producer increments)
    char             _pad1[56]; // pad to 64-byte cache line boundary
    _Atomic uint64_t readPos;   // samples consumed (consumer increments)
    char             _pad2[56]; // pad to 64-byte cache line boundary
    uint32_t         capacity;  // total float samples in data[]
    uint32_t         _pad;
    float            data[];    // interleaved PCM frames follow
} PouetSHM;

_Static_assert(sizeof(PouetSHM) == 136, "SHM header size mismatch — must match Swift SHMHeader");
_Static_assert(offsetof(PouetSHM, readPos) == 64, "readPos offset mismatch");
_Static_assert(offsetof(PouetSHM, capacity) == 128, "capacity offset mismatch");

// ---------------------------------------------------------------------------
// Object IDs
// ---------------------------------------------------------------------------
#define kPluginObjectID         1

// Pouet (input device)
#define kMicDeviceID            2
#define kMicInputStreamID       3
#define kMicVolumeCtrlID        5

// PouetSpeaker (output device)
#define kSpkDeviceID            6
#define kSpkOutputStreamID      7
#define kSpkVolumeCtrlID        8

// ---------------------------------------------------------------------------
// Device configuration (data-driven to avoid massive duplication)
// ---------------------------------------------------------------------------
typedef struct {
    AudioObjectID deviceID;
    AudioObjectID streamID;
    AudioObjectID volumeCtrlID;
    const char*   name;
    const char*   uid;
    const char*   modelUID;
    UInt32        streamDirection;       // 0=output, 1=input
    UInt32        terminalType;
    AudioObjectPropertyScope defaultScope;  // scope for "can be default device"
    Boolean       canBeDefaultSystem;
    const char*   shmName;
} DeviceDesc;

static const DeviceDesc kMicDesc = {
    .deviceID        = kMicDeviceID,
    .streamID        = kMicInputStreamID,
    .volumeCtrlID    = kMicVolumeCtrlID,
    .name            = "Pouet",
    .uid             = "Pouet-UID-001",
    .modelUID        = "Pouet-Model-001",
    .streamDirection = 1,
    .terminalType    = kAudioStreamTerminalTypeMicrophone,
    .defaultScope    = kAudioObjectPropertyScopeInput,
    .canBeDefaultSystem = false,
    .shmName         = POUET_SHM_NAME,
};

static const DeviceDesc kSpkDesc = {
    .deviceID        = kSpkDeviceID,
    .streamID        = kSpkOutputStreamID,
    .volumeCtrlID    = kSpkVolumeCtrlID,
    .name            = "PouetSpeaker",
    .uid             = "PouetSpeaker-UID-001",
    .modelUID        = "PouetSpeaker-Model-001",
    .streamDirection = 0,
    .terminalType    = kAudioStreamTerminalTypeSpeaker,
    .defaultScope    = kAudioObjectPropertyScopeOutput,
    .canBeDefaultSystem = false,
    .shmName         = POUET_SPEAKER_SHM_NAME,
};

static const DeviceDesc* DeviceDescForID(AudioObjectID id)
{
    if (id == kMicDeviceID) return &kMicDesc;
    if (id == kSpkDeviceID) return &kSpkDesc;
    return NULL;
}

static const DeviceDesc* DeviceDescForStreamID(AudioObjectID streamID)
{
    if (streamID == kMicInputStreamID) return &kMicDesc;
    if (streamID == kSpkOutputStreamID) return &kSpkDesc;
    return NULL;
}

static const DeviceDesc* DeviceDescForVolumeID(AudioObjectID volID)
{
    if (volID == kMicVolumeCtrlID) return &kMicDesc;
    if (volID == kSpkVolumeCtrlID) return &kSpkDesc;
    return NULL;
}

// ---------------------------------------------------------------------------
// Per-device runtime state
// ---------------------------------------------------------------------------
typedef struct {
    int            shmFd;
    PouetSHM* shm;
    UInt32         ioRunning;
    Float32        volume;
    Boolean        mute;
    _Atomic uint64_t anchorHostTime;
    _Atomic uint64_t anchorSampleTime;
} DeviceState;

// ---------------------------------------------------------------------------
// Driver state
// ---------------------------------------------------------------------------
typedef struct {
    AudioServerPlugInDriverInterface**  driverInterface;  // must be first
    CFUUIDRef                           factoryUUID;
    volatile int32_t                    refCount;

    AudioServerPlugInHostRef            host;
    pthread_mutex_t stateLock;
    mach_timebase_info_data_t tbInfo;

    DeviceState     mic;
    DeviceState     spk;
} PouetDriver;

static DeviceState* StateForDevice(PouetDriver* d, AudioObjectID devID)
{
    if (devID == kMicDeviceID) return &d->mic;
    if (devID == kSpkDeviceID) return &d->spk;
    return NULL;
}

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------
static HRESULT          Pouet_QueryInterface(void*, REFIID, LPVOID*);
static ULONG            Pouet_AddRef(void*);
static ULONG            Pouet_Release(void*);
static OSStatus         Pouet_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus         Pouet_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus         Pouet_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus         Pouet_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus         Pouet_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus         Pouet_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus         Pouet_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean          Pouet_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus         Pouet_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus         Pouet_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus         Pouet_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus         Pouet_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus         Pouet_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus         Pouet_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus         Pouet_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus         Pouet_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus         Pouet_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus         Pouet_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus         Pouet_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

// ---------------------------------------------------------------------------
// vtable
// ---------------------------------------------------------------------------
static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,                                           // _reserved
    Pouet_QueryInterface,
    Pouet_AddRef,
    Pouet_Release,
    Pouet_Initialize,
    Pouet_CreateDevice,
    Pouet_DestroyDevice,
    Pouet_AddDeviceClient,
    Pouet_RemoveDeviceClient,
    Pouet_PerformDeviceConfigurationChange,
    Pouet_AbortDeviceConfigurationChange,
    Pouet_HasProperty,
    Pouet_IsPropertySettable,
    Pouet_GetPropertyDataSize,
    Pouet_GetPropertyData,
    Pouet_SetPropertyData,
    Pouet_StartIO,
    Pouet_StopIO,
    Pouet_GetZeroTimeStamp,
    Pouet_WillDoIOOperation,
    Pouet_BeginIOOperation,
    Pouet_DoIOOperation,
    Pouet_EndIOOperation
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverInterface** gDriverInterfacePtrPtr = &gDriverInterfacePtr;

static PouetDriver gDriver = {
    .driverInterface = &gDriverInterfacePtr,
    .mic = { .shmFd = -1, .shm = NULL, .ioRunning = 0, .volume = 1.0f, .mute = false },
    .spk = { .shmFd = -1, .shm = NULL, .ioRunning = 0, .volume = 1.0f, .mute = false },
};

// ---------------------------------------------------------------------------
// Shared memory helpers
// ---------------------------------------------------------------------------
static void SHM_Close(DeviceState* st);  // forward decl

static void SHM_OpenNamed(DeviceState* st, const char* name)
{
    size_t sz = sizeof(PouetSHM) + POUET_SHM_SIZE;

    int newFd = shm_open(name, O_RDWR, 0666);
    if (newFd < 0) {
        if (st->shm) return;  // SHM doesn't exist yet, keep existing mapping
        newFd = shm_open(name, O_RDWR | O_CREAT, 0666);
        if (newFd < 0) {
            os_log_error(sDriverLog, "SHM_OpenNamed: shm_open(%{public}s) failed: %{errno}d", name, errno);
            return;
        }
        ftruncate(newFd, (off_t)sz);
    }

    if (st->shm) {
        // Check if our fd still points to the current segment.
        struct stat oldStat, newStat;
        if (fstat(st->shmFd, &oldStat) == 0 && fstat(newFd, &newStat) == 0 &&
            oldStat.st_ino == newStat.st_ino) {
            close(newFd);  // same segment, keep existing mapping
            return;
        }
        SHM_Close(st);  // different segment, remap below
    }

    st->shmFd = newFd;

    void* m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, st->shmFd, 0);
    if (m == MAP_FAILED) {
        os_log_error(sDriverLog, "SHM_OpenNamed: mmap(%{public}s) failed: %{errno}d", name, errno);
        close(st->shmFd); st->shmFd = -1; return;
    }
    st->shm = (PouetSHM*)m;

    // Ensure capacity is initialized (may have been created by driver before app)
    uint32_t expectedCap = POUET_SHM_SIZE / sizeof(float);
    if (st->shm->capacity == 0) {
        st->shm->capacity = expectedCap;
        atomic_store_explicit(&st->shm->writePos, 0, memory_order_release);
        atomic_store_explicit(&st->shm->readPos,  0, memory_order_release);
    }
}

static void SHM_Close(DeviceState* st) {
    if (st->shm) {
        size_t sz = sizeof(PouetSHM) + POUET_SHM_SIZE;
        munmap(st->shm, sz);
        st->shm = NULL;
    }
    if (st->shmFd >= 0) {
        close(st->shmFd);
        st->shmFd = -1;
    }
}

// Read `numFrames` stereo frames from ring buffer into `out` (for Pouet input).
// Reads whatever is available and zero-fills the remainder to avoid dropping good data.
// When too much data accumulates (clock drift), gradually drops evenly-spaced samples
// Handles all cases with a single resample loop:
//   - Normal (avail == needed):   1:1 copy
//   - Overrun (avail >> needed):  compress (skip samples to catch up)
//   - Partial underrun (0 < avail < needed): stretch (repeat samples)
//   - Complete underrun (avail == 0): output silence
//   - Producer lap (avail > cap): skip ahead to valid data
static void SHM_Read(DeviceState* st, float* out, uint32_t numFrames)
{
    uint32_t numSamples = numFrames * POUET_NUM_CHANNELS;
    if (!st->shm) { memset(out, 0, numSamples * sizeof(float)); return; }

    PouetSHM* shm = st->shm;
    uint64_t rp = atomic_load_explicit(&shm->readPos,  memory_order_acquire);
    uint64_t wp = atomic_load_explicit(&shm->writePos, memory_order_acquire);
    uint64_t avail = wp - rp;

    uint32_t cap = shm->capacity;
    if (cap == 0) { memset(out, 0, numSamples * sizeof(float)); return; }

    // Producer lapped us — our data is gone. Skip ahead to valid region.
    if (avail > cap) {
        rp = wp - cap / POUET_LAP_SKIP_DIV;
        avail = wp - rp;
    }

    if (avail == 0) { memset(out, 0, numSamples * sizeof(float)); return; }

    // Determine how many samples to consume.
    uint64_t maxLag = numSamples * POUET_MAX_LAG_MULT;
    uint64_t toConsume;
    if (avail > maxLag)
        toConsume = avail;          // overrun: drain all excess
    else if (avail >= numSamples)
        toConsume = numSamples;     // normal: 1:1
    else
        toConsume = avail;          // partial underrun: stretch

    // Align to stereo frame boundary
    toConsume = (toConsume / POUET_NUM_CHANNELS) * POUET_NUM_CHANNELS;
    if (toConsume == 0) { memset(out, 0, numSamples * sizeof(float)); return; }

    // Resample: map toConsume input frames → numFrames output frames.
    uint32_t toConsumeFrames = (uint32_t)(toConsume / POUET_NUM_CHANNELS);
    for (uint32_t f = 0; f < numFrames; f++) {
        uint32_t srcFrame = (uint32_t)((uint64_t)f * toConsumeFrames / numFrames);
        for (uint32_t ch = 0; ch < POUET_NUM_CHANNELS; ch++) {
            uint32_t idx = (uint32_t)((rp + srcFrame * POUET_NUM_CHANNELS + ch) % cap);
            float s = shm->data[idx];
            if (st->mute) s = 0.0f;
            out[f * POUET_NUM_CHANNELS + ch] = s * st->volume;
        }
    }
    atomic_store_explicit(&shm->readPos, rp + toConsume, memory_order_release);
}

// Write `numFrames` stereo frames from apps into ring buffer (for PouetSpeaker output).
static void SHM_Write(DeviceState* st, const float* in, uint32_t numFrames)
{
    uint32_t numSamples = numFrames * POUET_NUM_CHANNELS;
    if (!st->shm) return;

    PouetSHM* shm = st->shm;
    uint64_t wp = atomic_load_explicit(&shm->writePos, memory_order_acquire);
    uint32_t cap = shm->capacity;
    if (cap == 0) return;

    for (uint32_t i = 0; i < numSamples; i++) {
        uint32_t idx = (uint32_t)((wp + i) % cap);
        shm->data[idx] = in[i] * st->volume;
    }
    atomic_store_explicit(&shm->writePos, wp + numSamples, memory_order_release);
}

// ---------------------------------------------------------------------------
// Factory entry point (called by coreaudiod)
// ---------------------------------------------------------------------------
__attribute__((visibility("default")))
void* PouetDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    sDriverLog = os_log_create("com.pouet.driver", "audio");
    pthread_mutex_init(&gDriver.stateLock, NULL);
    mach_timebase_info(&gDriver.tbInfo);
    gDriver.refCount = 1;
    return gDriverInterfacePtrPtr;
}

// ---------------------------------------------------------------------------
// COM boilerplate
// ---------------------------------------------------------------------------
static HRESULT Pouet_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID) ||
        CFEqual(uuid, IUnknownUUID)) {
        Pouet_AddRef(inDriver);
        *outInterface = inDriver;
        result = S_OK;
    }
    CFRelease(uuid);
    return result;
}
static ULONG Pouet_AddRef(void* inDriver)  { (void)inDriver; return (ULONG)__sync_add_and_fetch(&gDriver.refCount, 1); }
static ULONG Pouet_Release(void* inDriver) { (void)inDriver; return (ULONG)__sync_sub_and_fetch(&gDriver.refCount, 1); }

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------
static OSStatus Pouet_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gDriver.host = inHost;
    SHM_OpenNamed(&gDriver.mic, POUET_SHM_NAME);
    SHM_OpenNamed(&gDriver.spk, POUET_SPEAKER_SHM_NAME);
    return kAudioHardwareNoError;
}

static OSStatus Pouet_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef props,
    const AudioServerPlugInClientInfo* ci, AudioObjectID* outDevID)
{ (void)d;(void)props;(void)ci; *outDevID = kAudioObjectUnknown; return kAudioHardwareUnsupportedOperationError; }
static OSStatus Pouet_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id)
{ (void)d;(void)id; return kAudioHardwareUnsupportedOperationError; }
static OSStatus Pouet_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci)
{ (void)d;(void)id;(void)ci; return kAudioHardwareNoError; }
static OSStatus Pouet_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci)
{ (void)d;(void)id;(void)ci; return kAudioHardwareNoError; }
static OSStatus Pouet_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* data)
{ (void)d;(void)id;(void)action;(void)data; return kAudioHardwareNoError; }
static OSStatus Pouet_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* data)
{ (void)d;(void)id;(void)action;(void)data; return kAudioHardwareNoError; }

// ---------------------------------------------------------------------------
// Helper: is this a device/stream/volume object we know?
// ---------------------------------------------------------------------------
static Boolean IsDevice(AudioObjectID id) { return id == kMicDeviceID || id == kSpkDeviceID; }
static Boolean IsStream(AudioObjectID id) { return id == kMicInputStreamID || id == kSpkOutputStreamID; }
static Boolean IsVolume(AudioObjectID id) { return id == kMicVolumeCtrlID || id == kSpkVolumeCtrlID; }

// ---------------------------------------------------------------------------
// HasProperty
// ---------------------------------------------------------------------------
static Boolean Pouet_HasProperty(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientPID;

    if (inObjectID == kPluginObjectID) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
    }

    if (IsDevice(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        }
    }

    if (IsStream(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
    }

    if (IsVolume(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            return true;
        }
    }

    return false;
}

// ---------------------------------------------------------------------------
// IsPropertySettable
// ---------------------------------------------------------------------------
static OSStatus Pouet_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientPID;
    *outIsSettable = false;

    if (IsDevice(inObjectID)) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
            *outIsSettable = true;
    }

    if (IsStream(inObjectID)) {
        if (inAddress->mSelector == kAudioStreamPropertyIsActive ||
            inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)
            *outIsSettable = true;
    }

    if (IsVolume(inObjectID)) {
        if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
            inAddress->mSelector == kAudioLevelControlPropertyDecibelValue)
            *outIsSettable = true;
    }

    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// GetPropertyDataSize
// ---------------------------------------------------------------------------
static OSStatus Pouet_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress,
    UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inDriver; (void)inClientPID;
    (void)inQualifierDataSize; (void)inQualifierData;

    // ---- Plugin ----
    if (inObjectID == kPluginObjectID) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        }
    }

    // ---- Device (both mic and speaker share same data sizes) ----
    if (IsDevice(inObjectID)) {
        const DeviceDesc* desc = DeviceDescForID(inObjectID);
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = sizeof(AudioObjectID) * 3; return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams: {
            AudioObjectPropertyScope streamScope =
                desc->streamDirection == 1 ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
            *outDataSize = (inAddress->mScope == streamScope) ? sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = sizeof(UInt32) * 2; return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 sz = offsetof(AudioChannelLayout, mChannelDescriptions[0]) +
                        POUET_NUM_CHANNELS * sizeof(AudioChannelDescription);
            *outDataSize = sz; return kAudioHardwareNoError;
        }
        }
    }

    // ---- Stream ----
    if (IsStream(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription); return kAudioHardwareNoError;
        }
    }

    // ---- Volume control ----
    if (IsVolume(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange:
            *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
        }
    }

    return kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------------------
// Helper: build the ASBD for our format
// ---------------------------------------------------------------------------
static AudioStreamBasicDescription MakeASBD(Float64 rate)
{
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate       = rate;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat |
                             kAudioFormatFlagsNativeEndian |
                             kAudioFormatFlagIsPacked;
    asbd.mBitsPerChannel   = 32;
    asbd.mChannelsPerFrame = POUET_NUM_CHANNELS;
    asbd.mFramesPerPacket  = 1;
    asbd.mBytesPerFrame    = sizeof(float) * POUET_NUM_CHANNELS;
    asbd.mBytesPerPacket   = asbd.mBytesPerFrame;
    return asbd;
}

// ---------------------------------------------------------------------------
// GetPropertyData
// ---------------------------------------------------------------------------
static OSStatus Pouet_GetPropertyData(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress,
    UInt32 inQualDataSize, const void* inQualData,
    UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inDriver; (void)inClientPID;
    (void)inQualDataSize; (void)inQualData; (void)inDataSize;

    // ---------------------------------------------------------------- Plugin
    if (inObjectID == kPluginObjectID) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID*)outData = kAudioObjectClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            *(AudioClassID*)outData = kAudioPlugInClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID*)outData = kAudioObjectPlugInObject;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "Pouet Plugin", kCFStringEncodingUTF8);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "Pouet", kCFStringEncodingUTF8);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            ids[0] = kMicDeviceID;
            ids[1] = kSpkDeviceID;
            *outDataSize = sizeof(AudioObjectID) * 2;
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "", kCFStringEncodingUTF8);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CFStringRef uid = (inQualDataSize >= sizeof(CFStringRef)) ? *(CFStringRef*)inQualData : NULL;
            AudioObjectID result = kAudioObjectUnknown;
            if (uid) {
                if (CFStringCompare(uid, CFSTR("Pouet-UID-001"), 0) == kCFCompareEqualTo)
                    result = kMicDeviceID;
                else if (CFStringCompare(uid, CFSTR("PouetSpeaker-UID-001"), 0) == kCFCompareEqualTo)
                    result = kSpkDeviceID;
            }
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID*)outData = result;
            return kAudioHardwareNoError;
        }
        }
    }

    // ---------------------------------------------------------------- Device
    if (IsDevice(inObjectID)) {
        const DeviceDesc* desc = DeviceDescForID(inObjectID);
        DeviceState* st = StateForDevice(&gDriver, inObjectID);
        if (!desc || !st) return kAudioHardwareUnknownPropertyError;

        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *(AudioObjectID*)outData = kPluginObjectID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, desc->name, kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "Pouet", kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, desc->uid, kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, desc->modelUID, kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
            *(UInt32*)outData = kAudioDeviceTransportTypeBuiltIn;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *(AudioObjectID*)outData = desc->deviceID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain:
            *(UInt32*)outData = desc->deviceID;  // unique domain per device (not 0 = built-in)
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsRunning:
            *(UInt32*)outData = st->ioRunning > 0 ? 1 : 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            *(UInt32*)outData = (inAddress->mScope == desc->defaultScope) ? 1 : 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *(UInt32*)outData = desc->canBeDefaultSystem ? 1 : 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyLatency:
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertySafetyOffset:
            *(UInt32*)outData = POUET_SAFETY_OFFSET;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyIsHidden:
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *(UInt32*)outData = POUET_BUFFER_FRAMES;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams: {
            AudioObjectPropertyScope streamScope =
                desc->streamDirection == 1 ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
            if (inAddress->mScope == streamScope) {
                *(AudioObjectID*)outData = desc->streamID;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID ids[2] = { desc->streamID, desc->volumeCtrlID };
            *outDataSize = 2 * sizeof(AudioObjectID);
            memcpy(outData, ids, *outDataSize);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList:
            *(AudioObjectID*)outData = desc->volumeCtrlID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *(Float64*)outData = POUET_SAMPLE_RATE;
            *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange* ranges = (AudioValueRange*)outData;
            ranges[0].mMinimum = POUET_SAMPLE_RATE;
            ranges[0].mMaximum = POUET_SAMPLE_RATE;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32* ch = (UInt32*)outData;
            ch[0] = 1; ch[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
            layout->mChannelBitmap    = 0;
            layout->mNumberChannelDescriptions = 0;
            *outDataSize = sizeof(AudioChannelLayout);
            return kAudioHardwareNoError;
        }
        }
    }

    // ---------------------------------------------------------------- Stream
    if (IsStream(inObjectID)) {
        const DeviceDesc* desc = DeviceDescForStreamID(inObjectID);
        DeviceState* st = desc ? StateForDevice(&gDriver, desc->deviceID) : NULL;
        if (!desc || !st) return kAudioHardwareUnknownPropertyError;

        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *(AudioObjectID*)outData = desc->deviceID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
            *(UInt32*)outData = st->ioRunning ? 1 : 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            *(UInt32*)outData = desc->streamDirection;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyTerminalType:
            *(UInt32*)outData = desc->terminalType;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyStartingChannel:
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyLatency:
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription asbd = MakeASBD(POUET_SAMPLE_RATE);
            *(AudioStreamBasicDescription*)outData = asbd;
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription* descs = (AudioStreamRangedDescription*)outData;
            descs[0].mFormat = MakeASBD(POUET_SAMPLE_RATE);
            descs[0].mSampleRateRange.mMinimum = POUET_SAMPLE_RATE;
            descs[0].mSampleRateRange.mMaximum = POUET_SAMPLE_RATE;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        }
    }

    // ---------------------------------------------------------- Volume ctrl
    if (IsVolume(inObjectID)) {
        const DeviceDesc* desc = DeviceDescForVolumeID(inObjectID);
        DeviceState* st = desc ? StateForDevice(&gDriver, desc->deviceID) : NULL;
        if (!desc || !st) return kAudioHardwareUnknownPropertyError;

        AudioObjectPropertyScope volScope =
            desc->streamDirection == 1 ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;

        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = kAudioLevelControlClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = kAudioVolumeControlClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *(AudioObjectID*)outData = desc->deviceID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            *(UInt32*)outData = volScope;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioControlPropertyElement:
            *(UInt32*)outData = kAudioObjectPropertyElementMain;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
            *(Float32*)outData = st->volume;
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelValue:
            *(Float32*)outData = (st->volume <= 0.0f) ? -96.0f :
                                  20.0f * log10f(st->volume);
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange* r = (AudioValueRange*)outData;
            r->mMinimum = -96.0; r->mMaximum = 0.0;
            *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            Float32 scalar = *(Float32*)outData;
            *(Float32*)outData = (scalar <= 0.0f) ? -96.0f : 20.0f * log10f(scalar);
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            Float32 db = *(Float32*)outData;
            *(Float32*)outData = (db <= -96.0f) ? 0.0f : powf(10.0f, db / 20.0f);
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        }
        }
    }

    return kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------------------
// SetPropertyData
// ---------------------------------------------------------------------------
static OSStatus Pouet_SetPropertyData(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress,
    UInt32 inQualDataSize, const void* inQualData,
    UInt32 inDataSize, const void* inData)
{
    (void)inDriver; (void)inClientPID;
    (void)inQualDataSize; (void)inQualData; (void)inDataSize;

    if (IsDevice(inObjectID)) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            // Accept the call but always stay at 48kHz — apps that try to
            // change the rate (e.g. Chrome/WebRTC) must not get an error.
            return kAudioHardwareNoError;
        }
    }

    if (IsVolume(inObjectID)) {
        const DeviceDesc* desc = DeviceDescForVolumeID(inObjectID);
        DeviceState* st = desc ? StateForDevice(&gDriver, desc->deviceID) : NULL;
        if (!st) return kAudioHardwareUnknownPropertyError;

        if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
            inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) {
                st->volume = *(Float32*)inData;
                if (st->volume < 0.0f) st->volume = 0.0f;
                if (st->volume > 1.0f) st->volume = 1.0f;
            } else {
                float db = *(Float32*)inData;
                st->volume = (db <= -96.0f) ? 0.0f : powf(10.0f, db / 20.0f);
            }

            // Notify host of both scalar and dB changes
            if (gDriver.host) {
                AudioObjectPropertyAddress changed[2] = {
                    { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                    { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                };
                gDriver.host->PropertiesChanged(gDriver.host, inObjectID, 2, changed);
            }
            return kAudioHardwareNoError;
        }
    }

    return kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------------------
// I/O lifecycle
// ---------------------------------------------------------------------------
static OSStatus Pouet_StartIO(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    const DeviceDesc* desc = DeviceDescForID(inDeviceObjectID);
    DeviceState* st = StateForDevice(&gDriver, inDeviceObjectID);
    if (!desc || !st) return kAudioHardwareBadDeviceError;

    pthread_mutex_lock(&gDriver.stateLock);
    if (st->ioRunning == 0) {
        atomic_store_explicit(&st->anchorHostTime, mach_absolute_time(), memory_order_release);
        atomic_store_explicit(&st->anchorSampleTime, 0, memory_order_release);
        SHM_OpenNamed(st, desc->shmName);
    }
    st->ioRunning++;
    pthread_mutex_unlock(&gDriver.stateLock);
    return kAudioHardwareNoError;
}

static OSStatus Pouet_StopIO(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    DeviceState* st = StateForDevice(&gDriver, inDeviceObjectID);
    if (!st) return kAudioHardwareBadDeviceError;

    pthread_mutex_lock(&gDriver.stateLock);
    if (st->ioRunning > 0) st->ioRunning--;
    pthread_mutex_unlock(&gDriver.stateLock);
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// Zero timestamp — drives the HAL clock
// ---------------------------------------------------------------------------
static OSStatus Pouet_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inDriver; (void)inClientID;
    DeviceState* st = StateForDevice(&gDriver, inDeviceObjectID);
    if (!st) return kAudioHardwareBadDeviceError;

    uint64_t anchor = atomic_load_explicit(&st->anchorHostTime, memory_order_acquire);
    double sr = POUET_SAMPLE_RATE;

    uint64_t now = mach_absolute_time();
    uint64_t elapsed = now - anchor;
    double elapsedNs = (double)elapsed * (double)gDriver.tbInfo.numer / (double)gDriver.tbInfo.denom;
    uint64_t elapsedFrames = (uint64_t)(elapsedNs * sr / 1e9);

    uint64_t period = POUET_BUFFER_FRAMES;
    uint64_t currentPeriod = elapsedFrames / period;

    *outSampleTime = (Float64)(currentPeriod * period);
    // Map the period boundary back to host time using nominal rate
    double nsPerPeriod = (double)period / sr * 1e9;
    uint64_t nsForPeriod = (uint64_t)((double)currentPeriod * nsPerPeriod);
    uint64_t ticksForPeriod = (uint64_t)((double)nsForPeriod * (double)gDriver.tbInfo.denom / (double)gDriver.tbInfo.numer);
    *outHostTime = anchor + ticksForPeriod;
    *outSeed = 1;

    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// I/O operations
// ---------------------------------------------------------------------------
static OSStatus Pouet_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inClientID;
    *outWillDoInPlace = true;

    if (inDeviceObjectID == kMicDeviceID) {
        *outWillDo = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    } else if (inDeviceObjectID == kSpkDeviceID) {
        *outWillDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    } else {
        *outWillDo = false;
    }
    return kAudioHardwareNoError;
}

static OSStatus Pouet_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver;(void)inDeviceObjectID;(void)inClientID;(void)inOperationID;
  (void)inIOBufferFrameSize;(void)inIOCycleInfo; return kAudioHardwareNoError; }

static OSStatus Pouet_DoIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
    void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID;
    (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    if (inDeviceObjectID == kMicDeviceID &&
        inOperationID == kAudioServerPlugInIOOperationReadInput) {
        SHM_Read(&gDriver.mic, (float*)ioMainBuffer, inIOBufferFrameSize);
    }
    else if (inDeviceObjectID == kSpkDeviceID &&
             inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        SHM_Write(&gDriver.spk, (const float*)ioMainBuffer, inIOBufferFrameSize);
    }
    return kAudioHardwareNoError;
}

static OSStatus Pouet_EndIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver;(void)inDeviceObjectID;(void)inClientID;(void)inOperationID;
  (void)inIOBufferFrameSize;(void)inIOCycleInfo; return kAudioHardwareNoError; }
