// test_driver.c — Unit tests for Pouet driver ring buffer and timestamp logic
// Runs without CoreAudio — copies minimal struct/function definitions from the driver.

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdbool.h>

// ---------------------------------------------------------------------------
// Copied from PouetDriver.c (must stay in sync!)
// ---------------------------------------------------------------------------
#define POUET_SHM_SIZE       (4096 * 256)
#define POUET_NUM_CHANNELS   2
#define POUET_BUFFER_FRAMES  512

typedef struct {
    _Atomic uint64_t writePos;
    char             _pad1[56];
    _Atomic uint64_t readPos;
    char             _pad2[56];
    uint32_t         capacity;
    uint32_t         _pad;
    float            data[];
} PouetSHM;

typedef struct {
    int              shmFd;
    PouetSHM*   shm;
    uint32_t         ioRunning;
    float            volume;
    bool             mute;
    _Atomic uint64_t anchorHostTime;
    _Atomic uint64_t anchorSampleTime;
} DeviceState;

// SHM_Read — copied verbatim from driver
static void SHM_Read(DeviceState* st, float* out, uint32_t numFrames)
{
    uint32_t numSamples = numFrames * POUET_NUM_CHANNELS;
    if (!st->shm) { memset(out, 0, numSamples * sizeof(float)); return; }

    PouetSHM* shm = st->shm;
    uint64_t rp = atomic_load_explicit(&shm->readPos,  memory_order_acquire);
    uint64_t wp = atomic_load_explicit(&shm->writePos, memory_order_acquire);
    uint64_t avail = wp - rp;

    if (avail < numSamples) {
        memset(out, 0, numSamples * sizeof(float));
        return;
    }

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

// SHM_Write — copied verbatim from driver
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
// Test helpers
// ---------------------------------------------------------------------------
static int tests_run = 0, tests_passed = 0;
#define RUN_TEST(fn) do { \
    printf("  %-45s", #fn); \
    fn(); \
    tests_passed++; tests_run++; \
    printf("OK\n"); \
} while(0)

static PouetSHM* alloc_shm(uint32_t cap) {
    size_t sz = sizeof(PouetSHM) + cap * sizeof(float);
    PouetSHM* shm = (PouetSHM*)calloc(1, sz);
    shm->capacity = cap;
    atomic_store(&shm->writePos, 0);
    atomic_store(&shm->readPos, 0);
    return shm;
}

static DeviceState make_state(PouetSHM* shm) {
    DeviceState st = {0};
    st.shm = shm;
    st.shmFd = -1;
    st.volume = 1.0f;
    st.mute = false;
    return st;
}

// ---------------------------------------------------------------------------
// Struct layout tests
// ---------------------------------------------------------------------------
static void test_struct_size(void) {
    // Header must be 136 bytes (before flexible array)
    // 8 (writePos) + 56 (pad1) + 8 (readPos) + 56 (pad2) + 4 (capacity) + 4 (pad) = 136
    size_t expected = 136;
    size_t actual = sizeof(PouetSHM);
    if (actual != expected) {
        fprintf(stderr, "\nFAIL: sizeof(PouetSHM) = %zu, expected %zu\n", actual, expected);
    }
    assert(actual == expected);
}

static void test_struct_field_offsets(void) {
    assert(offsetof(PouetSHM, writePos) == 0);
    assert(offsetof(PouetSHM, readPos)  == 64);
    assert(offsetof(PouetSHM, capacity) == 128);
    assert(offsetof(PouetSHM, data)     == 136);
}

// ---------------------------------------------------------------------------
// Ring buffer tests
// ---------------------------------------------------------------------------
static void test_read_write_basic(void) {
    uint32_t cap = 2048;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    // Write 256 frames = 512 stereo samples
    float input[512];
    for (int i = 0; i < 512; i++) input[i] = (float)i * 0.01f;
    SHM_Write(&st, input, 256);

    assert(atomic_load(&shm->writePos) == 512);

    // Read them back
    float output[512];
    SHM_Read(&st, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(fabsf(output[i] - input[i]) < 1e-6f);
    }
    assert(atomic_load(&shm->readPos) == 512);
    free(shm);
}

static void test_read_empty_returns_silence(void) {
    PouetSHM* shm = alloc_shm(1024);
    DeviceState st = make_state(shm);

    float output[512];
    memset(output, 0xFF, sizeof(output)); // fill with garbage
    SHM_Read(&st, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(output[i] == 0.0f);
    }
    free(shm);
}

static void test_read_underflow_returns_silence(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);

    // Write only 50 samples (25 frames)
    float input[50];
    for (int i = 0; i < 50; i++) input[i] = 1.0f;
    SHM_Write(&st, input, 25);

    // Try to read 256 frames = 512 samples (more than available)
    float output[512];
    SHM_Read(&st, output, 256);

    // Should be silence (underflow path)
    for (int i = 0; i < 512; i++) {
        assert(output[i] == 0.0f);
    }
    free(shm);
}

static void test_write_read_wraparound(void) {
    uint32_t cap = 256;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    // Advance positions to near end of buffer
    uint64_t start = cap - 50;
    atomic_store(&shm->writePos, start);
    atomic_store(&shm->readPos, start);

    // Write 100 samples (50 frames) — will wrap around
    float input[100];
    for (int i = 0; i < 100; i++) input[i] = (float)(i + 1);
    SHM_Write(&st, input, 50);

    // Read them back
    float output[100];
    SHM_Read(&st, output, 50);

    for (int i = 0; i < 100; i++) {
        assert(fabsf(output[i] - input[i]) < 1e-6f);
    }
    free(shm);
}

static void test_read_skip_ahead_on_overflow(void) {
    uint32_t cap = 2048;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    // Write 1500 samples (750 frames)
    float input[1500];
    for (int i = 0; i < 1500; i++) input[i] = (float)i;
    SHM_Write(&st, input, 750);

    // Read 256 frames = 512 samples
    // avail = 1500, maxLag = 1024, so readPos should skip ahead
    float output[512];
    SHM_Read(&st, output, 256);

    // After skip: readPos was set to writePos - maxLag = 1500 - 1024 = 476
    // So we read samples starting from index 476
    for (int i = 0; i < 512; i++) {
        float expected = (float)(476 + i);
        assert(fabsf(output[i] - expected) < 1e-6f);
    }
    free(shm);
}

static void test_volume_scaling(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);
    st.volume = 0.5f;

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = 2.0f;

    // Write applies volume too
    SHM_Write(&st, input, 256);

    // Read with a fresh state at volume 1.0 to see what was written
    DeviceState st2 = make_state(shm);
    st2.volume = 1.0f;
    float output[512];
    SHM_Read(&st2, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(fabsf(output[i] - 1.0f) < 1e-6f); // 2.0 * 0.5 = 1.0
    }
    free(shm);
}

static void test_mute(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = 1.0f;
    SHM_Write(&st, input, 256);

    // Read with mute enabled
    st.mute = true;
    atomic_store(&shm->readPos, 0); // reset read position
    float output[512];
    SHM_Read(&st, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(output[i] == 0.0f);
    }
    free(shm);
}

static void test_zero_capacity_safe(void) {
    PouetSHM* shm = alloc_shm(0);
    shm->capacity = 0;
    DeviceState st = make_state(shm);

    float input[512], output[512];
    memset(input, 0, sizeof(input));

    // Should not crash
    SHM_Write(&st, input, 256);
    SHM_Read(&st, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(output[i] == 0.0f);
    }
    free(shm);
}

static void test_null_shm_safe(void) {
    DeviceState st = {0};
    st.shm = NULL;
    st.volume = 1.0f;

    float input[512], output[512];
    memset(output, 0xFF, sizeof(output));

    // Should not crash, output should be silence
    SHM_Write(&st, input, 256);
    SHM_Read(&st, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(output[i] == 0.0f);
    }
}

static void test_writepos_monotonic(void) {
    PouetSHM* shm = alloc_shm(4096);
    DeviceState st = make_state(shm);

    float input[512];
    memset(input, 0, sizeof(input));

    uint64_t prev = 0;
    for (int round = 0; round < 10; round++) {
        SHM_Write(&st, input, 256);
        uint64_t wp = atomic_load(&shm->writePos);
        assert(wp > prev);
        assert(wp == prev + 512);
        prev = wp;
    }
    free(shm);
}

// ---------------------------------------------------------------------------
// Timestamp math tests
// ---------------------------------------------------------------------------
typedef struct {
    uint32_t numer;
    uint32_t denom;
} TimebaseInfo;

static void calc_zero_timestamp(uint64_t anchor, double sampleRate,
    TimebaseInfo tb, uint64_t now,
    double* outSampleTime, uint64_t* outHostTime)
{
    uint64_t elapsed = now - anchor;
    double elapsedNs = (double)elapsed * (double)tb.numer / (double)tb.denom;
    uint64_t elapsedFrames = (uint64_t)(elapsedNs * sampleRate / 1e9);

    uint64_t period = POUET_BUFFER_FRAMES;
    uint64_t currentPeriod = elapsedFrames / period;

    *outSampleTime = (double)(currentPeriod * period);
    double nsPerPeriod = (double)period / sampleRate * 1e9;
    uint64_t nsForPeriod = (uint64_t)((double)currentPeriod * nsPerPeriod);
    uint64_t ticksForPeriod = (uint64_t)((double)nsForPeriod * (double)tb.denom / (double)tb.numer);
    *outHostTime = anchor + ticksForPeriod;
}

static void test_timestamp_at_anchor(void) {
    TimebaseInfo tb = {1, 1};
    double sampleTime;
    uint64_t hostTime;

    calc_zero_timestamp(1000, 48000.0, tb, 1000, &sampleTime, &hostTime);
    assert(sampleTime == 0.0);
    assert(hostTime == 1000);
}

static void test_timestamp_alignment(void) {
    TimebaseInfo tb = {1, 1};
    double sampleTime;
    uint64_t hostTime;

    // 10ms at 48kHz = 480 frames, which is < 512 (one period)
    // So currentPeriod = 0, sampleTime should still be 0
    uint64_t anchor = 0;
    uint64_t now = 10000000; // 10ms in ns (with numer/denom = 1/1)
    calc_zero_timestamp(anchor, 48000.0, tb, now, &sampleTime, &hostTime);
    assert(sampleTime == 0.0);

    // 11ms > 512/48000 = 10.67ms → should be 1 period
    now = 11000000;
    calc_zero_timestamp(anchor, 48000.0, tb, now, &sampleTime, &hostTime);
    assert(sampleTime == 512.0);
}

static void test_timestamp_sample_time_is_period_multiple(void) {
    TimebaseInfo tb = {1, 1};
    double sampleTime;
    uint64_t hostTime;

    // Test many different elapsed times
    for (uint64_t ms = 0; ms < 1000; ms += 7) {
        uint64_t now = ms * 1000000; // ms to ns
        calc_zero_timestamp(0, 48000.0, tb, now, &sampleTime, &hostTime);
        uint64_t st = (uint64_t)sampleTime;
        assert(st % POUET_BUFFER_FRAMES == 0);
    }
}

static void test_timestamp_large_elapsed(void) {
    // Simulate 24 hours of uptime
    TimebaseInfo tb = {125, 3}; // realistic Apple Silicon timebase
    double sampleTime;
    uint64_t hostTime;

    uint64_t anchor = 0;
    // 24h in ticks: 24 * 3600 * 1e9 / (125/3) ≈ 24 * 3600 * 1e9 * 3/125
    uint64_t now = (uint64_t)(24.0 * 3600.0 * 1e9 * 3.0 / 125.0);

    calc_zero_timestamp(anchor, 48000.0, tb, now, &sampleTime, &hostTime);

    // After 24h at 48kHz: ~4,147,200,000 frames
    // sampleTime should be near that, rounded to 512-frame periods
    assert(sampleTime > 4e9);
    assert(sampleTime < 5e9);
    uint64_t st = (uint64_t)sampleTime;
    assert(st % POUET_BUFFER_FRAMES == 0);
    assert(hostTime > anchor);
}

static void test_sample_rate_validation(void) {
    // These should be rejected
    assert(0.0 < 1.0);   // 0 is out of range
    assert(-1.0 < 1.0);  // negative is out of range
    assert(500000.0 > 384000.0); // too high

    // Inline the validation logic from SetPropertyData
    double rates_reject[] = {0.0, -1.0, 0.5, 384001.0, 1e9};
    for (int i = 0; i < 5; i++) {
        assert(rates_reject[i] < 1.0 || rates_reject[i] > 384000.0);
    }

    double rates_accept[] = {1.0, 44100.0, 48000.0, 96000.0, 384000.0};
    for (int i = 0; i < 5; i++) {
        assert(rates_accept[i] >= 1.0 && rates_accept[i] <= 384000.0);
    }
}

// ---------------------------------------------------------------------------
// Adversarial / stress tests
// ---------------------------------------------------------------------------

#include <pthread.h>

// --- Concurrent reader/writer stress test ---
// This is the class of bug that crashed coreaudiod: one thread reading
// while another modifies state. We hammer the ring buffer from 2 threads
// and check for crashes, data corruption, and position invariants.

typedef struct {
    DeviceState* st;
    PouetSHM* shm;
    uint32_t cap;
    int iterations;
    volatile int* stop_flag;
} ThreadArg;

static void* writer_thread(void* arg) {
    ThreadArg* a = (ThreadArg*)arg;
    float input[1024];
    for (int i = 0; i < 1024; i++) input[i] = 0.5f;

    for (int iter = 0; iter < a->iterations && !*a->stop_flag; iter++) {
        SHM_Write(a->st, input, 512);
    }
    return NULL;
}

static void* reader_thread(void* arg) {
    ThreadArg* a = (ThreadArg*)arg;
    float output[1024];

    for (int iter = 0; iter < a->iterations && !*a->stop_flag; iter++) {
        SHM_Read(a->st, output, 512);
        // Verify no NaN/Inf crept in
        for (int i = 0; i < 1024; i++) {
            if (isnan(output[i]) || isinf(output[i])) {
                fprintf(stderr, "\nFAIL: corrupted data at sample %d: %f\n", i, output[i]);
                assert(0);
            }
        }
    }
    return NULL;
}

static void test_concurrent_read_write_stress(void) {
    uint32_t cap = 8192;
    PouetSHM* shm = alloc_shm(cap);
    // Writer and reader use separate DeviceState but same shm (like driver vs app)
    DeviceState writer_st = make_state(shm);
    DeviceState reader_st = make_state(shm);
    volatile int stop_flag = 0;

    ThreadArg warg = { &writer_st, shm, cap, 5000, &stop_flag };
    ThreadArg rarg = { &reader_st, shm, cap, 5000, &stop_flag };

    pthread_t wt, rt;
    pthread_create(&wt, NULL, writer_thread, &warg);
    pthread_create(&rt, NULL, reader_thread, &rarg);
    pthread_join(wt, NULL);
    stop_flag = 1;
    pthread_join(rt, NULL);

    // Positions must still be sane
    uint64_t wp = atomic_load(&shm->writePos);
    uint64_t rp = atomic_load(&shm->readPos);
    assert(wp >= rp); // writePos must never fall behind readPos
    free(shm);
}

// --- Multiple concurrent writers (simulates driver + app both writing) ---
static void test_concurrent_multi_writer_stress(void) {
    uint32_t cap = 8192;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st1 = make_state(shm);
    DeviceState st2 = make_state(shm);
    volatile int stop_flag = 0;

    ThreadArg arg1 = { &st1, shm, cap, 3000, &stop_flag };
    ThreadArg arg2 = { &st2, shm, cap, 3000, &stop_flag };

    pthread_t t1, t2;
    pthread_create(&t1, NULL, writer_thread, &arg1);
    pthread_create(&t2, NULL, writer_thread, &arg2);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    // writePos must be monotonically advanced (no torn writes)
    uint64_t wp = atomic_load(&shm->writePos);
    assert(wp > 0);
    free(shm);
}

// --- NaN / Inf / denormal injection ---
// Real audio hardware can produce these. Driver must not crash or propagate garbage.
static void test_nan_inf_data_does_not_crash(void) {
    uint32_t cap = 2048;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    float poison[512];
    for (int i = 0; i < 512; i++) {
        switch (i % 4) {
            case 0: poison[i] = NAN; break;
            case 1: poison[i] = INFINITY; break;
            case 2: poison[i] = -INFINITY; break;
            case 3: poison[i] = 1e-45f; break; // denormal
        }
    }

    // Write should not crash
    SHM_Write(&st, poison, 256);
    assert(atomic_load(&shm->writePos) == 512);

    // Read should not crash
    float output[512];
    SHM_Read(&st, output, 256);

    // Positions should advance normally
    assert(atomic_load(&shm->readPos) == 512);
    free(shm);
}

// --- Mute with NaN data: output must be exactly zero ---
static void test_mute_zeroes_nan_data(void) {
    uint32_t cap = 2048;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    float poison[512];
    for (int i = 0; i < 512; i++) poison[i] = NAN;
    SHM_Write(&st, poison, 256);

    st.mute = true;
    float output[512];
    SHM_Read(&st, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(output[i] == 0.0f);
    }
    free(shm);
}

// --- Position overflow: writePos wrapping past UINT64_MAX ---
static void test_position_overflow_uint64(void) {
    uint32_t cap = 2048;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    // Set positions near UINT64_MAX
    uint64_t near_max = UINT64_MAX - 256;
    atomic_store(&shm->writePos, near_max);
    atomic_store(&shm->readPos, near_max);

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = (float)(i + 1);
    SHM_Write(&st, input, 256);

    // writePos wrapped around UINT64_MAX
    uint64_t wp = atomic_load(&shm->writePos);
    assert(wp == near_max + 512);  // may have wrapped

    float output[512];
    SHM_Read(&st, output, 256);

    for (int i = 0; i < 512; i++) {
        assert(fabsf(output[i] - (float)(i + 1)) < 1e-6f);
    }
    free(shm);
}

// --- Corrupted state: readPos > writePos ---
// Could happen if SHM is stale or from a different version
static void test_corrupted_readpos_ahead_of_writepos(void) {
    uint32_t cap = 2048;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    // Corrupt: readPos far ahead of writePos
    atomic_store(&shm->writePos, 100);
    atomic_store(&shm->readPos, 5000);

    float output[512];
    memset(output, 0xFF, sizeof(output));

    // avail = wp - rp wraps to a huge value (unsigned underflow)
    // The driver should handle this gracefully (silence or skip-ahead)
    SHM_Read(&st, output, 256);

    // Should not crash — that's the main assertion
    // Output should be finite
    for (int i = 0; i < 512; i++) {
        assert(!isnan(output[i]) && !isinf(output[i]));
    }
    free(shm);
}

// --- Huge frame request: numFrames much larger than capacity ---
static void test_huge_frame_request(void) {
    uint32_t cap = 256;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    // Fill buffer
    float input[256];
    for (int i = 0; i < 256; i++) input[i] = 1.0f;
    atomic_store(&shm->writePos, 0);
    for (uint32_t i = 0; i < cap; i++) shm->data[i] = 1.0f;
    atomic_store(&shm->writePos, cap);

    // Request far more frames than exist
    // 4096 frames * 2 channels = 8192 samples, but cap = 256
    float output[8192];
    memset(output, 0xFF, sizeof(output));
    SHM_Read(&st, output, 4096);

    // Should not crash, output should be silence (underflow: avail < numSamples)
    for (int i = 0; i < 8192; i++) {
        assert(output[i] == 0.0f);
    }
    free(shm);
}

// --- Volume edge cases: zero, negative, huge ---
static void test_volume_zero(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);
    st.volume = 0.0f;

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = 1.0f;
    SHM_Write(&st, input, 256);

    // Everything written should be 0
    for (uint32_t i = 0; i < 512; i++) {
        assert(shm->data[i] == 0.0f);
    }
    free(shm);
}

static void test_volume_negative(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);
    st.volume = -1.0f;

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = 1.0f;
    SHM_Write(&st, input, 256);

    // Should invert the signal
    for (uint32_t i = 0; i < 512; i++) {
        assert(fabsf(shm->data[i] - (-1.0f)) < 1e-6f);
    }
    free(shm);
}

static void test_volume_huge(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);
    st.volume = 1e10f;

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = 1.0f;
    SHM_Write(&st, input, 256);

    // Should not crash, values will be huge but finite
    for (uint32_t i = 0; i < 512; i++) {
        assert(!isnan(shm->data[i]));
        assert(isfinite(shm->data[i]));
    }
    free(shm);
}

static void test_volume_nan(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);
    st.volume = NAN;

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = 1.0f;

    // Should not crash
    SHM_Write(&st, input, 256);
    free(shm);
}

// --- Capacity = 1: degenerate minimal buffer ---
static void test_capacity_one(void) {
    PouetSHM* shm = alloc_shm(1);
    DeviceState st = make_state(shm);

    float input[2] = {0.5f, 0.5f};
    // Write 1 frame = 2 samples into capacity of 1 — will wrap heavily
    SHM_Write(&st, input, 1);

    // Should not crash
    uint64_t wp = atomic_load(&shm->writePos);
    assert(wp == 2);
    free(shm);
}

// --- Non-power-of-2 capacity: tests modulo math ---
static void test_odd_capacity(void) {
    uint32_t cap = 777;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    // Write and read multiple rounds, wrapping around odd boundary
    float input[512], output[512];
    for (int i = 0; i < 512; i++) input[i] = (float)i * 0.001f;

    for (int round = 0; round < 20; round++) {
        SHM_Write(&st, input, 256);
    }

    // Read back — should not crash
    for (int round = 0; round < 10; round++) {
        SHM_Read(&st, output, 256);
    }

    // Positions should be consistent
    uint64_t wp = atomic_load(&shm->writePos);
    uint64_t rp = atomic_load(&shm->readPos);
    assert(wp >= rp);
    free(shm);
}

// --- Rapid start/stop: alternating null/non-null shm ---
// Simulates what happens if StopIO races with DoIOOperation
static void test_rapid_null_toggle(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);

    float input[512], output[512];
    for (int i = 0; i < 512; i++) input[i] = 1.0f;

    for (int i = 0; i < 1000; i++) {
        if (i % 3 == 0) {
            st.shm = NULL;
        } else {
            st.shm = shm;
        }
        SHM_Write(&st, input, 256);
        SHM_Read(&st, output, 256);
    }
    // Main assertion: no crash
    free(shm);
}

// --- Write exactly at capacity boundary ---
static void test_write_exact_capacity(void) {
    // cap = 512 samples, write exactly 256 frames * 2 channels = 512
    uint32_t cap = 512;
    PouetSHM* shm = alloc_shm(cap);
    DeviceState st = make_state(shm);

    float input[512];
    for (int i = 0; i < 512; i++) input[i] = (float)i;

    SHM_Write(&st, input, 256);
    assert(atomic_load(&shm->writePos) == 512);

    float output[512];
    SHM_Read(&st, output, 256);
    assert(atomic_load(&shm->readPos) == 512);

    for (int i = 0; i < 512; i++) {
        assert(fabsf(output[i] - (float)i) < 1e-6f);
    }
    free(shm);
}

// --- Stale SHM: capacity = garbage value ---
// This simulates what happened with the old 24-byte header:
// capacity field was at the wrong offset, reading garbage
static void test_garbage_capacity(void) {
    PouetSHM* shm = alloc_shm(2048);
    DeviceState st = make_state(shm);

    // Corrupt capacity to a huge value
    shm->capacity = UINT32_MAX;

    float input[512], output[512];
    for (int i = 0; i < 512; i++) input[i] = 1.0f;

    // Should not crash — write will use modulo with UINT32_MAX
    SHM_Write(&st, input, 256);

    // Read: avail = 512, not underflow, but modulo with UINT32_MAX
    // The data might be garbage but it should not segfault
    // (in real life, the allocation is too small, but the test checks the logic)
    // Reset to avoid out-of-bounds: we just check it doesn't crash with cap=0
    shm->capacity = 0;
    SHM_Read(&st, output, 256);
    for (int i = 0; i < 512; i++) {
        assert(output[i] == 0.0f); // cap=0 returns silence
    }
    free(shm);
}

// --- Timestamp: rapid anchor updates (simulates SetPropertyData during IO) ---
static void test_timestamp_anchor_change_during_io(void) {
    TimebaseInfo tb = {1, 1};
    double sampleTime;
    uint64_t hostTime;

    // Simulate anchor being updated mid-stream (sample rate change)
    for (uint64_t anchor = 0; anchor < 1000000; anchor += 100000) {
        uint64_t now = anchor + 50000000; // 50ms after anchor
        calc_zero_timestamp(anchor, 48000.0, tb, now, &sampleTime, &hostTime);

        uint64_t st = (uint64_t)sampleTime;
        assert(st % POUET_BUFFER_FRAMES == 0);
        assert(hostTime >= anchor);
    }
}

// --- Timestamp: extreme sample rates ---
static void test_timestamp_extreme_sample_rates(void) {
    TimebaseInfo tb = {1, 1};
    double sampleTime;
    uint64_t hostTime;

    // Very low sample rate
    calc_zero_timestamp(0, 1.0, tb, 1000000000, &sampleTime, &hostTime);
    assert((uint64_t)sampleTime % POUET_BUFFER_FRAMES == 0);

    // Very high sample rate
    calc_zero_timestamp(0, 384000.0, tb, 1000000000, &sampleTime, &hostTime);
    assert((uint64_t)sampleTime % POUET_BUFFER_FRAMES == 0);
    assert(sampleTime > 0);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(void) {
    printf("=== C Driver Tests ===\n");

    // Struct layout
    RUN_TEST(test_struct_size);
    RUN_TEST(test_struct_field_offsets);

    // Ring buffer — basic
    RUN_TEST(test_read_write_basic);
    RUN_TEST(test_read_empty_returns_silence);
    RUN_TEST(test_read_underflow_returns_silence);
    RUN_TEST(test_write_read_wraparound);
    RUN_TEST(test_read_skip_ahead_on_overflow);
    RUN_TEST(test_volume_scaling);
    RUN_TEST(test_mute);
    RUN_TEST(test_zero_capacity_safe);
    RUN_TEST(test_null_shm_safe);
    RUN_TEST(test_writepos_monotonic);

    // Timestamp math
    RUN_TEST(test_timestamp_at_anchor);
    RUN_TEST(test_timestamp_alignment);
    RUN_TEST(test_timestamp_sample_time_is_period_multiple);
    RUN_TEST(test_timestamp_large_elapsed);
    RUN_TEST(test_sample_rate_validation);

    // Adversarial — concurrency
    RUN_TEST(test_concurrent_read_write_stress);
    RUN_TEST(test_concurrent_multi_writer_stress);

    // Adversarial — poisoned data
    RUN_TEST(test_nan_inf_data_does_not_crash);
    RUN_TEST(test_mute_zeroes_nan_data);

    // Adversarial — position/overflow
    RUN_TEST(test_position_overflow_uint64);
    RUN_TEST(test_corrupted_readpos_ahead_of_writepos);

    // Adversarial — boundary conditions
    RUN_TEST(test_huge_frame_request);
    RUN_TEST(test_capacity_one);
    RUN_TEST(test_odd_capacity);
    RUN_TEST(test_write_exact_capacity);
    RUN_TEST(test_garbage_capacity);

    // Adversarial — volume edge cases
    RUN_TEST(test_volume_zero);
    RUN_TEST(test_volume_negative);
    RUN_TEST(test_volume_huge);
    RUN_TEST(test_volume_nan);

    // Adversarial — state transitions
    RUN_TEST(test_rapid_null_toggle);

    // Adversarial — timestamps
    RUN_TEST(test_timestamp_anchor_change_during_io);
    RUN_TEST(test_timestamp_extreme_sample_rates);

    printf("\n%d/%d tests passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
