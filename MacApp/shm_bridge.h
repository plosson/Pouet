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
