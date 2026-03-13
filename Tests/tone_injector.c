// tone_injector.c — Writes test signals to Pouet SHM for automated testing.
// Supports multiple modes to test different audio paths.
//
// Usage: ./tone_injector <duration_seconds> <mode>
//   Modes:
//     mic      — 440Hz sine (simulates mic-only passthrough)
//     inject   — 1000Hz sine (simulates injection-only)
//     mix      — 440Hz + 1000Hz mixed (simulates mic + injection)
//     silence  — writes zeros (tests silence path)
//     sweep    — 200Hz→2000Hz sweep (tests frequency response)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <time.h>

#define SHM_NAME       "/PouetAudio"
#define SAMPLE_RATE    48000
#define NUM_CHANNELS   2
#define CHUNK_FRAMES   512
#define CHUNK_SAMPLES  (CHUNK_FRAMES * NUM_CHANNELS)
#define SHM_DATA_SIZE  (4096 * 256)

#define FREQ_MIC       440.0
#define FREQ_INJECT    1000.0
#define AMPLITUDE      0.5f

typedef struct {
    _Atomic uint64_t writePos;
    char             _pad1[56];
    _Atomic uint64_t readPos;
    char             _pad2[56];
    uint32_t         capacity;
    uint32_t         _pad;
    float            data[];
} PouetSHM;

enum Mode { MODE_MIC, MODE_INJECT, MODE_MIX, MODE_SILENCE, MODE_SWEEP };

static volatile int running = 1;
static void sighandler(int sig) { (void)sig; running = 0; }

static PouetSHM* open_shm(const char* name) {
    size_t total = sizeof(PouetSHM) + SHM_DATA_SIZE;
    int fd = shm_open(name, O_RDWR, 0666);
    if (fd < 0) {
        fd = shm_open(name, O_RDWR | O_CREAT, 0666);
        if (fd < 0) { perror("shm_open"); return NULL; }
        ftruncate(fd, (off_t)total);
    }
    void* mem = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mem == MAP_FAILED) { perror("mmap"); return NULL; }
    PouetSHM* shm = (PouetSHM*)mem;
    shm->capacity = SHM_DATA_SIZE / sizeof(float);
    atomic_store_explicit(&shm->writePos, 0, memory_order_release);
    atomic_store_explicit(&shm->readPos, 0, memory_order_release);
    return shm;
}

static float generate_sample(enum Mode mode, uint64_t frame, int duration) {
    double t = (double)frame / SAMPLE_RATE;
    switch (mode) {
        case MODE_MIC:
            return AMPLITUDE * (float)sin(2.0 * M_PI * FREQ_MIC * t);
        case MODE_INJECT:
            return AMPLITUDE * (float)sin(2.0 * M_PI * FREQ_INJECT * t);
        case MODE_MIX: {
            float mic = AMPLITUDE * (float)sin(2.0 * M_PI * FREQ_MIC * t);
            float inj = AMPLITUDE * (float)sin(2.0 * M_PI * FREQ_INJECT * t);
            float mixed = mic + inj;
            return fminf(1.0f, fmaxf(-1.0f, mixed));
        }
        case MODE_SILENCE:
            return 0.0f;
        case MODE_SWEEP: {
            // Linear sweep 200Hz → 2000Hz over duration
            double progress = t / (double)duration;
            double freq = 200.0 + (2000.0 - 200.0) * progress;
            return AMPLITUDE * (float)sin(2.0 * M_PI * freq * t);
        }
    }
    return 0.0f;
}

int main(int argc, char** argv) {
    int duration = 10;
    enum Mode mode = MODE_MIC;

    if (argc > 1) duration = atoi(argv[1]);
    if (duration <= 0) duration = 10;

    if (argc > 2) {
        if (strcmp(argv[2], "inject") == 0) mode = MODE_INJECT;
        else if (strcmp(argv[2], "mix") == 0) mode = MODE_MIX;
        else if (strcmp(argv[2], "silence") == 0) mode = MODE_SILENCE;
        else if (strcmp(argv[2], "sweep") == 0) mode = MODE_SWEEP;
    }

    const char* modeNames[] = { "mic (440Hz)", "inject (1000Hz)", "mix (440+1000Hz)", "silence", "sweep (200-2000Hz)" };

    signal(SIGINT, sighandler);
    signal(SIGTERM, sighandler);

    PouetSHM* shm = open_shm(SHM_NAME);
    if (!shm) return 1;

    fprintf(stderr, "tone_injector: mode=%s duration=%ds\n", modeNames[mode], duration);

    uint64_t totalFramesWritten = 0;
    uint64_t totalFrames = (uint64_t)duration * SAMPLE_RATE;
    uint32_t cap = shm->capacity;
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    while (running && totalFramesWritten < totalFrames) {
        float chunk[CHUNK_SAMPLES];
        for (int f = 0; f < CHUNK_FRAMES; f++) {
            float sample = generate_sample(mode, totalFramesWritten + f, duration);
            chunk[f * NUM_CHANNELS]     = sample;
            chunk[f * NUM_CHANNELS + 1] = sample;
        }

        uint64_t wp = atomic_load_explicit(&shm->writePos, memory_order_acquire);
        for (int i = 0; i < CHUNK_SAMPLES; i++) {
            shm->data[(uint32_t)((wp + i) % cap)] = chunk[i];
        }
        atomic_store_explicit(&shm->writePos, wp + CHUNK_SAMPLES, memory_order_release);

        totalFramesWritten += CHUNK_FRAMES;

        // Pace to real-time
        double elapsedAudio = (double)totalFramesWritten / SAMPLE_RATE;
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double ahead = elapsedAudio - ((now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9);
        if (ahead > 0.001) {
            struct timespec ts = { 0, (long)(ahead * 0.5 * 1e9) };
            nanosleep(&ts, NULL);
        }
    }

    fprintf(stderr, "tone_injector: done (%llu frames)\n", totalFramesWritten);
    munmap(shm, sizeof(PouetSHM) + SHM_DATA_SIZE);
    return 0;
}
