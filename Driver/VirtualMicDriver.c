// VirtualMicDriver.c
// Audio Server Plugin that creates a virtual microphone AND a virtual speaker device.
// VirtualMic (input):   App writes mic audio → SHM → driver serves to apps as microphone
// VirtualSpeaker (output): Apps play audio → driver writes to SHM → App reads for dashcam/proxy
// Install to: /Library/Audio/Plug-Ins/HAL/VirtualMic.driver

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <os/log.h>

// ---------------------------------------------------------------------------
// Shared memory layout (must match App side: SharedMemory.h)
// ---------------------------------------------------------------------------
#define VIRTUALMICDRV_SHM_NAME   "/VirtualMicAudio"
#define VIRTUALSPEAKER_SHM_NAME  "/VirtualSpeakerAudio"
#define VIRTUALMICDRV_SHM_SIZE   (4096 * 256)   // ~1 second at 48kHz stereo f32

#define VIRTUALMICDRV_SAMPLE_RATE    48000.0
#define VIRTUALMICDRV_NUM_CHANNELS   2
#define VIRTUALMICDRV_BUFFER_FRAMES  512

// Ring buffer header lives at the start of the shared memory region.
typedef struct {
    _Atomic uint64_t writePos;  // samples written (producer increments)
    char             _pad1[56]; // pad to 64-byte cache line boundary
    _Atomic uint64_t readPos;   // samples consumed (consumer increments)
    char             _pad2[56]; // pad to 64-byte cache line boundary
    uint32_t         capacity;  // total float samples in data[]
    uint32_t         _pad;
    float            data[];    // interleaved PCM frames follow
} VirtualMicSHM;

// ---------------------------------------------------------------------------
// Object IDs
// ---------------------------------------------------------------------------
#define kPluginObjectID         1

// VirtualMic (input device)
#define kMicDeviceID            2
#define kMicInputStreamID       3
#define kMicOutputStreamID      4   // unused loopback
#define kMicVolumeCtrlID        5

// VirtualSpeaker (output device)
#define kSpkDeviceID            6
#define kSpkOutputStreamID      7
#define kSpkVolumeCtrlID        8

// Backward compat aliases
#define kDeviceObjectID     kMicDeviceID
#define kInputStreamID      kMicInputStreamID
#define kOutputStreamID     kMicOutputStreamID
#define kMasterVolumeCtrlID kMicVolumeCtrlID

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
    .name            = "VirtualMic",
    .uid             = "VirtualMic-UID-001",
    .modelUID        = "VirtualMic-Model-001",
    .streamDirection = 1,
    .terminalType    = kAudioStreamTerminalTypeMicrophone,
    .defaultScope    = kAudioObjectPropertyScopeInput,
    .canBeDefaultSystem = false,
    .shmName         = VIRTUALMICDRV_SHM_NAME,
};

static const DeviceDesc kSpkDesc = {
    .deviceID        = kSpkDeviceID,
    .streamID        = kSpkOutputStreamID,
    .volumeCtrlID    = kSpkVolumeCtrlID,
    .name            = "VirtualSpeaker",
    .uid             = "VirtualSpeaker-UID-001",
    .modelUID        = "VirtualSpeaker-Model-001",
    .streamDirection = 0,
    .terminalType    = kAudioStreamTerminalTypeSpeaker,
    .defaultScope    = kAudioObjectPropertyScopeOutput,
    .canBeDefaultSystem = true,
    .shmName         = VIRTUALSPEAKER_SHM_NAME,
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
    VirtualMicSHM* shm;
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
    _Atomic double  sampleRate;
    mach_timebase_info_data_t tbInfo;

    DeviceState     mic;
    DeviceState     spk;
} VirtualMicDriver;

static DeviceState* StateForDevice(VirtualMicDriver* d, AudioObjectID devID)
{
    if (devID == kMicDeviceID) return &d->mic;
    if (devID == kSpkDeviceID) return &d->spk;
    return NULL;
}

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------
static HRESULT          VirtualMic_QueryInterface(void*, REFIID, LPVOID*);
static ULONG            VirtualMic_AddRef(void*);
static ULONG            VirtualMic_Release(void*);
static OSStatus         VirtualMic_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus         VirtualMic_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus         VirtualMic_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus         VirtualMic_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus         VirtualMic_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus         VirtualMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus         VirtualMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean          VirtualMic_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus         VirtualMic_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus         VirtualMic_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus         VirtualMic_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus         VirtualMic_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus         VirtualMic_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus         VirtualMic_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus         VirtualMic_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus         VirtualMic_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus         VirtualMic_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus         VirtualMic_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus         VirtualMic_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

// ---------------------------------------------------------------------------
// vtable
// ---------------------------------------------------------------------------
static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,                                           // _reserved
    VirtualMic_QueryInterface,
    VirtualMic_AddRef,
    VirtualMic_Release,
    VirtualMic_Initialize,
    VirtualMic_CreateDevice,
    VirtualMic_DestroyDevice,
    VirtualMic_AddDeviceClient,
    VirtualMic_RemoveDeviceClient,
    VirtualMic_PerformDeviceConfigurationChange,
    VirtualMic_AbortDeviceConfigurationChange,
    VirtualMic_HasProperty,
    VirtualMic_IsPropertySettable,
    VirtualMic_GetPropertyDataSize,
    VirtualMic_GetPropertyData,
    VirtualMic_SetPropertyData,
    VirtualMic_StartIO,
    VirtualMic_StopIO,
    VirtualMic_GetZeroTimeStamp,
    VirtualMic_WillDoIOOperation,
    VirtualMic_BeginIOOperation,
    VirtualMic_DoIOOperation,
    VirtualMic_EndIOOperation
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverInterface** gDriverInterfacePtrPtr = &gDriverInterfacePtr;

static VirtualMicDriver gDriver = {
    .driverInterface = &gDriverInterfacePtr,
    .sampleRate      = VIRTUALMICDRV_SAMPLE_RATE,
    .mic = { .shmFd = -1, .shm = NULL, .ioRunning = 0, .volume = 1.0f, .mute = false },
    .spk = { .shmFd = -1, .shm = NULL, .ioRunning = 0, .volume = 1.0f, .mute = false },
};

// ---------------------------------------------------------------------------
// Shared memory helpers
// ---------------------------------------------------------------------------
static void SHM_OpenNamed(DeviceState* st, const char* name)
{
    if (st->shm) return;  // already mapped

    size_t sz = sizeof(VirtualMicSHM) + VIRTUALMICDRV_SHM_SIZE;
    st->shmFd = shm_open(name, O_RDWR, 0600);
    if (st->shmFd < 0) {
        st->shmFd = shm_open(name, O_RDWR | O_CREAT, 0600);
        if (st->shmFd < 0) return;
        ftruncate(st->shmFd, (off_t)sz);
    }

    void* m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, st->shmFd, 0);
    if (m == MAP_FAILED) { close(st->shmFd); st->shmFd = -1; return; }
    st->shm = (VirtualMicSHM*)m;

    // Ensure capacity is initialized (may have been created by driver before app)
    uint32_t expectedCap = VIRTUALMICDRV_SHM_SIZE / sizeof(float);
    if (st->shm->capacity == 0) {
        st->shm->capacity = expectedCap;
        atomic_store_explicit(&st->shm->writePos, 0, memory_order_release);
        atomic_store_explicit(&st->shm->readPos,  0, memory_order_release);
    }
}

static void SHM_Close(DeviceState* st) {
    if (st->shm) {
        size_t sz = sizeof(VirtualMicSHM) + VIRTUALMICDRV_SHM_SIZE;
        munmap(st->shm, sz);
        st->shm = NULL;
    }
    if (st->shmFd >= 0) {
        close(st->shmFd);
        st->shmFd = -1;
    }
}

// Read `numFrames` stereo frames from ring buffer into `out` (for VirtualMic input).
// If not enough data: fill silence.
// If too much data buffered: skip ahead to the freshest samples to minimize latency.
static void SHM_Read(DeviceState* st, float* out, uint32_t numFrames)
{
    uint32_t numSamples = numFrames * VIRTUALMICDRV_NUM_CHANNELS;
    if (!st->shm) { memset(out, 0, numSamples * sizeof(float)); return; }

    VirtualMicSHM* shm = st->shm;
    uint64_t rp = atomic_load_explicit(&shm->readPos,  memory_order_acquire);
    uint64_t wp = atomic_load_explicit(&shm->writePos, memory_order_acquire);
    uint64_t avail = wp - rp;

    if (avail < numSamples) {
        memset(out, 0, numSamples * sizeof(float));
        return;
    }

    // Skip ahead if too much data buffered (keep only ~2 buffer periods worth)
    uint64_t maxLag = numSamples * 2;
    if (avail > maxLag) {
        rp = wp - maxLag;
        atomic_store_explicit(&shm->readPos, rp, memory_order_release);
    }

    uint32_t cap = shm->capacity;
    if (cap == 0) { memset(out, 0, numSamples * sizeof(float)); return; }
    for (uint32_t i = 0; i < numSamples; i++) {
        uint32_t idx = (uint32_t)((rp + i) % cap);
        float s = shm->data[idx];
        if (st->mute) s = 0.0f;
        out[i] = s * st->volume;
    }
    atomic_store_explicit(&shm->readPos, rp + numSamples, memory_order_release);
}

// Write `numFrames` stereo frames from apps into ring buffer (for VirtualSpeaker output).
static void SHM_Write(DeviceState* st, const float* in, uint32_t numFrames)
{
    uint32_t numSamples = numFrames * VIRTUALMICDRV_NUM_CHANNELS;
    if (!st->shm) return;

    VirtualMicSHM* shm = st->shm;
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
void* VirtualMicDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    pthread_mutex_init(&gDriver.stateLock, NULL);
    mach_timebase_info(&gDriver.tbInfo);
    gDriver.refCount = 1;
    return gDriverInterfacePtrPtr;
}

// ---------------------------------------------------------------------------
// COM boilerplate
// ---------------------------------------------------------------------------
static HRESULT VirtualMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID) ||
        CFEqual(uuid, IUnknownUUID)) {
        VirtualMic_AddRef(inDriver);
        *outInterface = inDriver;
        result = S_OK;
    }
    CFRelease(uuid);
    return result;
}
static ULONG VirtualMic_AddRef(void* inDriver)  { (void)inDriver; return (ULONG)__sync_add_and_fetch(&gDriver.refCount, 1); }
static ULONG VirtualMic_Release(void* inDriver) { (void)inDriver; return (ULONG)__sync_sub_and_fetch(&gDriver.refCount, 1); }

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------
static OSStatus VirtualMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gDriver.host = inHost;
    SHM_OpenNamed(&gDriver.mic, VIRTUALMICDRV_SHM_NAME);
    SHM_OpenNamed(&gDriver.spk, VIRTUALSPEAKER_SHM_NAME);
    return kAudioHardwareNoError;
}

static OSStatus VirtualMic_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef props,
    const AudioServerPlugInClientInfo* ci, AudioObjectID* outDevID)
{ (void)d;(void)props;(void)ci; *outDevID = kAudioObjectUnknown; return kAudioHardwareUnsupportedOperationError; }
static OSStatus VirtualMic_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id)
{ (void)d;(void)id; return kAudioHardwareUnsupportedOperationError; }
static OSStatus VirtualMic_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci)
{ (void)d;(void)id;(void)ci; return kAudioHardwareNoError; }
static OSStatus VirtualMic_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci)
{ (void)d;(void)id;(void)ci; return kAudioHardwareNoError; }
static OSStatus VirtualMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* data)
{ (void)d;(void)id;(void)action;(void)data; return kAudioHardwareNoError; }
static OSStatus VirtualMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* data)
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
static Boolean VirtualMic_HasProperty(AudioServerPlugInDriverRef inDriver,
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
static OSStatus VirtualMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
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
static OSStatus VirtualMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
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
            *outDataSize = sizeof(AudioValueRange) * 4; return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = sizeof(UInt32) * 2; return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 sz = offsetof(AudioChannelLayout, mChannelDescriptions[0]) +
                        VIRTUALMICDRV_NUM_CHANNELS * sizeof(AudioChannelDescription);
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
            *outDataSize = sizeof(AudioStreamRangedDescription) * 4; return kAudioHardwareNoError;
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
    asbd.mChannelsPerFrame = VIRTUALMICDRV_NUM_CHANNELS;
    asbd.mFramesPerPacket  = 1;
    asbd.mBytesPerFrame    = sizeof(float) * VIRTUALMICDRV_NUM_CHANNELS;
    asbd.mBytesPerPacket   = asbd.mBytesPerFrame;
    return asbd;
}

// ---------------------------------------------------------------------------
// GetPropertyData
// ---------------------------------------------------------------------------
static OSStatus VirtualMic_GetPropertyData(AudioServerPlugInDriverRef inDriver,
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
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "VirtualMic Plugin", kCFStringEncodingUTF8);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "VirtualMic", kCFStringEncodingUTF8);
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
                if (CFStringCompare(uid, CFSTR("VirtualMic-UID-001"), 0) == kCFCompareEqualTo)
                    result = kMicDeviceID;
                else if (CFStringCompare(uid, CFSTR("VirtualSpeaker-UID-001"), 0) == kCFCompareEqualTo)
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
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "VirtualMic", kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, desc->uid, kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, desc->modelUID, kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
            *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *(AudioObjectID*)outData = desc->deviceID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain:
            *(UInt32*)outData = 0;
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
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyIsHidden:
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *(UInt32*)outData = VIRTUALMICDRV_BUFFER_FRAMES;
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
            *(Float64*)outData = gDriver.sampleRate;
            *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            Float64 rates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
            AudioValueRange* ranges = (AudioValueRange*)outData;
            for (int i = 0; i < 4; i++) {
                ranges[i].mMinimum = rates[i];
                ranges[i].mMaximum = rates[i];
            }
            *outDataSize = 4 * sizeof(AudioValueRange);
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
            AudioStreamBasicDescription asbd = MakeASBD(gDriver.sampleRate);
            *(AudioStreamBasicDescription*)outData = asbd;
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            Float64 rates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
            AudioStreamRangedDescription* descs = (AudioStreamRangedDescription*)outData;
            for (int i = 0; i < 4; i++) {
                descs[i].mFormat = MakeASBD(rates[i]);
                descs[i].mSampleRateRange.mMinimum = rates[i];
                descs[i].mSampleRateRange.mMaximum = rates[i];
            }
            *outDataSize = 4 * sizeof(AudioStreamRangedDescription);
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
static OSStatus VirtualMic_SetPropertyData(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress,
    UInt32 inQualDataSize, const void* inQualData,
    UInt32 inDataSize, const void* inData)
{
    (void)inDriver; (void)inClientPID;
    (void)inQualDataSize; (void)inQualData; (void)inDataSize;

    if (IsDevice(inObjectID)) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            Float64 newRate = *(Float64*)inData;
            if (newRate < 1.0 || newRate > 384000.0) return kAudioHardwareIllegalOperationError;
            pthread_mutex_lock(&gDriver.stateLock);
            atomic_store_explicit(&gDriver.sampleRate, newRate, memory_order_release);
            pthread_mutex_unlock(&gDriver.stateLock);
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
static OSStatus VirtualMic_StartIO(AudioServerPlugInDriverRef inDriver,
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

static OSStatus VirtualMic_StopIO(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    DeviceState* st = StateForDevice(&gDriver, inDeviceObjectID);
    if (!st) return kAudioHardwareBadDeviceError;

    pthread_mutex_lock(&gDriver.stateLock);
    if (st->ioRunning > 0) {
        st->ioRunning--;
        if (st->ioRunning == 0) {
            SHM_Close(st);
        }
    }
    pthread_mutex_unlock(&gDriver.stateLock);
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// Zero timestamp — drives the HAL clock
// ---------------------------------------------------------------------------
static OSStatus VirtualMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inDriver; (void)inClientID;
    DeviceState* st = StateForDevice(&gDriver, inDeviceObjectID);
    if (!st) return kAudioHardwareBadDeviceError;

    uint64_t anchor = atomic_load_explicit(&st->anchorHostTime, memory_order_acquire);
    double sr = atomic_load_explicit(&gDriver.sampleRate, memory_order_relaxed);

    uint64_t now = mach_absolute_time();
    uint64_t elapsed = now - anchor;
    double elapsedNs = (double)elapsed * (double)gDriver.tbInfo.numer / (double)gDriver.tbInfo.denom;
    uint64_t elapsedFrames = (uint64_t)(elapsedNs * sr / 1e9);

    uint64_t period = VIRTUALMICDRV_BUFFER_FRAMES;
    uint64_t currentPeriod = elapsedFrames / period;

    *outSampleTime = (Float64)(currentPeriod * period);
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
static OSStatus VirtualMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
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

static OSStatus VirtualMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver;(void)inDeviceObjectID;(void)inClientID;(void)inOperationID;
  (void)inIOBufferFrameSize;(void)inIOCycleInfo; return kAudioHardwareNoError; }

static OSStatus VirtualMic_DoIOOperation(AudioServerPlugInDriverRef inDriver,
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

static OSStatus VirtualMic_EndIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver;(void)inDeviceObjectID;(void)inClientID;(void)inOperationID;
  (void)inIOBufferFrameSize;(void)inIOCycleInfo; return kAudioHardwareNoError; }
