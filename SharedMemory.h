// SharedMemory.h
// Shared ring-buffer layout between VirtualMicDriver (coreaudiod side)
// and the companion VirtualMicApp (user side).
// Include this header in BOTH targets.
#pragma once
#include <stdint.h>
#include <stdatomic.h>

#define VIRTUALMICDRV_SHM_NAME    "/VirtualMicAudio"
#define VIRTUALMICDRV_SHM_SIZE    (4096 * 256)    // ~1 s at 48 kHz stereo f32
#define VIRTUALMICDRV_SAMPLE_RATE  48000.0
#define VIRTUALMICDRV_NUM_CHANNELS 2

// The shared memory region layout:
//   [VirtualMicSHM header]  (fixed size)
//   [float data[capacity]]  (ring buffer samples, interleaved stereo)
typedef struct {
    _Atomic uint64_t writePos;   // total samples written (producer)
    _Atomic uint64_t readPos;    // total samples consumed (driver)
    uint32_t         capacity;   // total float slots in data[]
    uint32_t         _pad;
    float            data[];     // interleaved L,R,L,R … samples
} VirtualMicSHM;

// Returns pointer to data array start (convenience)
static inline float* VirtualMicSHM_Data(VirtualMicSHM* shm) { return shm->data; }
