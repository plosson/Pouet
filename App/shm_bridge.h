// shm_bridge.h — C helpers for shm_open (variadic, unavailable in Swift)
#pragma once
#include <sys/mman.h>
#include <fcntl.h>

static inline int shm_open_rw(const char* name) {
    return shm_open(name, O_RDWR, 0666);
}

static inline int shm_open_create(const char* name) {
    return shm_open(name, O_RDWR | O_CREAT, 0666);
}

// Unlink then create fresh with correct permissions
static inline int shm_recreate(const char* name) {
    shm_unlink(name);
    return shm_open(name, O_RDWR | O_CREAT, 0666);
}

static inline void shm_cleanup(const char* name) {
    shm_unlink(name);
}

// --- Atomic helpers for shared memory positions ---
// Swift can't use C11 _Atomic directly; these inline functions bridge the gap.

#include <stdatomic.h>
#include <stdint.h>

typedef struct {
    _Atomic uint64_t writePos;
    char             _pad1[56];
    _Atomic uint64_t readPos;
    char             _pad2[56];
    uint32_t         capacity;
    uint32_t         _pad;
    // float data[] follows
} SHMHeaderC;

static inline uint64_t shm_load_write_pos(const void* header) {
    const SHMHeaderC* h = (const SHMHeaderC*)header;
    return atomic_load_explicit(&h->writePos, memory_order_acquire);
}

static inline uint64_t shm_load_read_pos(const void* header) {
    const SHMHeaderC* h = (const SHMHeaderC*)header;
    return atomic_load_explicit(&h->readPos, memory_order_acquire);
}

static inline void shm_store_write_pos(void* header, uint64_t val) {
    SHMHeaderC* h = (SHMHeaderC*)header;
    atomic_store_explicit(&h->writePos, val, memory_order_release);
}

static inline void shm_store_read_pos(void* header, uint64_t val) {
    SHMHeaderC* h = (SHMHeaderC*)header;
    atomic_store_explicit(&h->readPos, val, memory_order_release);
}

static inline void shm_memory_barrier(void) {
    atomic_thread_fence(memory_order_seq_cst);
}
