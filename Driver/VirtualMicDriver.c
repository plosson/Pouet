// VirtualMicDriver.c
// Audio Server Plugin that creates a virtual microphone device.
// Audio is fed via a named shared memory ring buffer from the companion app.
// Install to: /Library/Audio/Plug-Ins/HAL/VirtualMic.driver
//
// Build: see Makefile / Xcode project
// Requires macOS 10.12+, no kernel extension, no SIP modification needed.

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
#define VIRTUALMICDRV_SHM_SIZE   (4096 * 256)   // ~1 second at 48kHz stereo f32

#define VIRTUALMICDRV_SAMPLE_RATE    48000.0
#define VIRTUALMICDRV_NUM_CHANNELS   2
#define VIRTUALMICDRV_BUFFER_FRAMES  512

// Ring buffer header lives at the start of the shared memory region.
typedef struct {
    _Atomic uint64_t writePos;  // samples written (producer increments)
    _Atomic uint64_t readPos;   // samples consumed (consumer increments)
    uint32_t         capacity;  // total float samples in data[]
    uint32_t         _pad;
    float            data[];    // interleaved PCM frames follow
} VirtualMicSHM;

// ---------------------------------------------------------------------------
// Object IDs
// ---------------------------------------------------------------------------
#define kPluginObjectID     1
#define kDeviceObjectID     2
#define kInputStreamID      3
#define kOutputStreamID     4   // loopback output so apps can also play-through
#define kMasterVolumeCtrlID 5

// ---------------------------------------------------------------------------
// Driver state
// ---------------------------------------------------------------------------
typedef struct {
    AudioServerPlugInDriverInterface**  driverInterface;  // must be first
    CFUUIDRef                           factoryUUID;
    volatile int32_t                    refCount;

    // Shared memory
    int          shmFd;
    VirtualMicSHM* shm;

    // Device / stream state
    pthread_mutex_t stateLock;
    UInt32          ioRunning;
    Float64         sampleRate;
    Float32         masterVolume;
    Boolean         masterMute;

    // Zero timestamp tracking
    uint64_t        anchorHostTime;
    uint64_t        anchorSampleTime;
    mach_timebase_info_data_t tbInfo;
} VirtualMicDriver;

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
    .shmFd           = -1,
    .shm             = NULL,
    .ioRunning       = 0,
    .sampleRate      = VIRTUALMICDRV_SAMPLE_RATE,
    .masterVolume    = 1.0f,
    .masterMute      = false,
};

// ---------------------------------------------------------------------------
// Shared memory helpers
// ---------------------------------------------------------------------------
static void SHM_Open(VirtualMicDriver* d)
{
    if (d->shm) return;  // already mapped

    size_t sz = sizeof(VirtualMicSHM) + VIRTUALMICDRV_SHM_SIZE;
    d->shmFd = shm_open(VIRTUALMICDRV_SHM_NAME, O_RDWR, 0666);
    if (d->shmFd < 0) {
        d->shmFd = shm_open(VIRTUALMICDRV_SHM_NAME, O_RDWR | O_CREAT, 0666);
        if (d->shmFd < 0) return;
        ftruncate(d->shmFd, (off_t)sz);
    }

    void* m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, d->shmFd, 0);
    if (m == MAP_FAILED) { close(d->shmFd); d->shmFd = -1; return; }
    d->shm = (VirtualMicSHM*)m;
}

// Read `numFrames` stereo frames from ring buffer into `out`.
// If not enough data: fill silence.
static void SHM_Read(VirtualMicDriver* d, float* out, uint32_t numFrames)
{
    uint32_t numSamples = numFrames * VIRTUALMICDRV_NUM_CHANNELS;
    if (!d->shm) { memset(out, 0, numSamples * sizeof(float)); return; }

    VirtualMicSHM* shm = d->shm;
    uint64_t rp = atomic_load_explicit(&shm->readPos,  memory_order_acquire);
    uint64_t wp = atomic_load_explicit(&shm->writePos, memory_order_acquire);
    uint64_t avail = wp - rp;

    if (avail < numSamples) {
        // Underrun — output silence
        memset(out, 0, numSamples * sizeof(float));
        return;
    }

    uint32_t cap = shm->capacity;
    for (uint32_t i = 0; i < numSamples; i++) {
        uint32_t idx = (uint32_t)((rp + i) % cap);
        float s = shm->data[idx];
        if (d->masterMute) s = 0.0f;
        out[i] = s * d->masterVolume;
    }
    atomic_store_explicit(&shm->readPos, rp + numSamples, memory_order_release);
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
    (void)inDriver; (void)inHost;
    SHM_Open(&gDriver);
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
// Property dispatch helpers
// ---------------------------------------------------------------------------
static Boolean VirtualMic_HasProperty(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientPID;
    switch (inObjectID) {
    case kPluginObjectID:
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
        break;
    case kDeviceObjectID:
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
        break;
    case kInputStreamID:
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
        break;
    case kMasterVolumeCtrlID:
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
        break;
    }
    return false;
}

static OSStatus VirtualMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID, pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientPID;
    *outIsSettable = false;
    switch (inObjectID) {
    case kDeviceObjectID:
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
            *outIsSettable = true;
        break;
    case kInputStreamID:
        if (inAddress->mSelector == kAudioStreamPropertyIsActive ||
            inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)
            *outIsSettable = true;
        break;
    case kMasterVolumeCtrlID:
        if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
            inAddress->mSelector == kAudioLevelControlPropertyDecibelValue)
            *outIsSettable = true;
        break;
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

    switch (inObjectID) {
    // ---- Plugin ----
    case kPluginObjectID:
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
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        }
        break;
    // ---- Device ----
    case kDeviceObjectID:
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
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
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
        case kAudioDevicePropertyStreams:
            *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput) ?
                sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
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
        break;
    // ---- Stream ----
    case kInputStreamID:
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
        break;
    // ---- Volume control ----
    case kMasterVolumeCtrlID:
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
        break;
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

    switch (inObjectID) {
    // ---------------------------------------------------------------- Plugin
    case kPluginObjectID:
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
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID*)outData = kDeviceObjectID;
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "", kCFStringEncodingUTF8);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            *(AudioObjectID*)outData = kDeviceObjectID;
            return kAudioHardwareNoError;
        }
        break;
    // ---------------------------------------------------------------- Device
    case kDeviceObjectID:
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
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "VirtualMic", kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "VirtualMic", kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "VirtualMic-UID-001", kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            *(CFStringRef*)outData = CFStringCreateWithCString(NULL, "VirtualMic-Model-001", kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
            *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *(AudioObjectID*)outData = kDeviceObjectID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain:
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsRunning:
            *(UInt32*)outData = gDriver.ioRunning > 0 ? 1 : 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            *(UInt32*)outData = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 1 : 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *(UInt32*)outData = 0;
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
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                *(AudioObjectID*)outData = kInputStreamID;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID ids[3] = { kInputStreamID, kMasterVolumeCtrlID, 0 };
            UInt32 n = 2;
            *outDataSize = n * sizeof(AudioObjectID);
            memcpy(outData, ids, *outDataSize);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList:
            *(AudioObjectID*)outData = kMasterVolumeCtrlID;
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
        break;
    // ---------------------------------------------------------------- Stream
    case kInputStreamID:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *(AudioObjectID*)outData = kDeviceObjectID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
            *(UInt32*)outData = gDriver.ioRunning ? 1 : 0;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            *(UInt32*)outData = 1; // 1 = input
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyTerminalType:
            *(UInt32*)outData = kAudioStreamTerminalTypeMicrophone;
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
        break;
    // ---------------------------------------------------------- Volume ctrl
    case kMasterVolumeCtrlID:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = kAudioLevelControlClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = kAudioVolumeControlClassID;
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *(AudioObjectID*)outData = kDeviceObjectID;
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            *(UInt32*)outData = kAudioObjectPropertyScopeInput;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioControlPropertyElement:
            *(UInt32*)outData = kAudioObjectPropertyElementMain;
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
            *(Float32*)outData = gDriver.masterVolume;
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelValue:
            *(Float32*)outData = (gDriver.masterVolume <= 0.0f) ? -96.0f :
                                  20.0f * log10f(gDriver.masterVolume);
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange* r = (AudioValueRange*)outData;
            r->mMinimum = -96.0; r->mMaximum = 0.0;
            *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *(Float32*)outData = gDriver.masterVolume;
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        }
        break;
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

    switch (inObjectID) {
    case kDeviceObjectID:
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            pthread_mutex_lock(&gDriver.stateLock);
            gDriver.sampleRate = *(Float64*)inData;
            pthread_mutex_unlock(&gDriver.stateLock);
            return kAudioHardwareNoError;
        }
        break;
    case kMasterVolumeCtrlID:
        if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) {
            gDriver.masterVolume = *(Float32*)inData;
            if (gDriver.masterVolume < 0.0f) gDriver.masterVolume = 0.0f;
            if (gDriver.masterVolume > 1.0f) gDriver.masterVolume = 1.0f;
            return kAudioHardwareNoError;
        }
        if (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
            float db = *(Float32*)inData;
            gDriver.masterVolume = (db <= -96.0f) ? 0.0f : powf(10.0f, db / 20.0f);
            return kAudioHardwareNoError;
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------------------
// I/O lifecycle
// ---------------------------------------------------------------------------
static OSStatus VirtualMic_StartIO(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gDriver.stateLock);
    if (gDriver.ioRunning == 0) {
        // Anchor timestamps
        gDriver.anchorHostTime   = mach_absolute_time();
        gDriver.anchorSampleTime = 0;
        SHM_Open(&gDriver);
    }
    gDriver.ioRunning++;
    pthread_mutex_unlock(&gDriver.stateLock);
    return kAudioHardwareNoError;
}

static OSStatus VirtualMic_StopIO(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gDriver.stateLock);
    if (gDriver.ioRunning > 0) gDriver.ioRunning--;
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
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gDriver.stateLock);

    // Compute elapsed host ticks since anchor
    uint64_t now  = mach_absolute_time();
    uint64_t elapsed = now - gDriver.anchorHostTime;

    // Convert to nanoseconds then to frames
    uint64_t elapsedNs = elapsed * gDriver.tbInfo.numer / gDriver.tbInfo.denom;
    uint64_t elapsedFrames = (uint64_t)((double)elapsedNs * gDriver.sampleRate / 1e9);

    // Quantise to buffer period
    uint64_t period = VIRTUALMICDRV_BUFFER_FRAMES;
    uint64_t currentPeriod = elapsedFrames / period;

    *outSampleTime = (Float64)(currentPeriod * period);
    // Host time for this period's start
    double nsPerPeriod = (double)period / gDriver.sampleRate * 1e9;
    uint64_t nsForPeriod = (uint64_t)((double)currentPeriod * nsPerPeriod);
    uint64_t ticksForPeriod = nsForPeriod * gDriver.tbInfo.denom / gDriver.tbInfo.numer;
    *outHostTime = gDriver.anchorHostTime + ticksForPeriod;
    *outSeed = 1;

    pthread_mutex_unlock(&gDriver.stateLock);
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// I/O operations
// ---------------------------------------------------------------------------
static OSStatus VirtualMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    *outWillDo        = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
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
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID;
    (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        SHM_Read(&gDriver, (float*)ioMainBuffer, inIOBufferFrameSize);
    }
    return kAudioHardwareNoError;
}

static OSStatus VirtualMic_EndIOOperation(AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver;(void)inDeviceObjectID;(void)inClientID;(void)inOperationID;
  (void)inIOBufferFrameSize;(void)inIOCycleInfo; return kAudioHardwareNoError; }
