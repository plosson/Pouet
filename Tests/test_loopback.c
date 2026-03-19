// test_loopback.c — Unit tests for Pouet loopback driver ring buffer isolation.
// Compiles the driver source directly (like BlackHole's tests) — no installation needed.
// Validates the three core audio behaviours:
//   1. Sound injection:  write sine → PouetMicrophone → read back → verify signal
//   2. Audio dashcam:    write sine → PouetSpeaker → read back → verify signal
//   3. Device isolation: write to one device → read from the other → verify silence
//
// Build: clang -O0 -g -framework CoreAudio -framework CoreFoundation -framework Accelerate -o test_loopback test_loopback.c
// Run:   ./test_loopback

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Include the driver source directly (BlackHole test pattern)
#include "../Driver/PouetLoopback.c"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define TONE_FREQ       440.0f
#define TEST_FRAMES     512       // one IO buffer worth
#define RMS_SIGNAL_THRESHOLD  0.01f
#define RMS_SILENCE_THRESHOLD 0.001f

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("  FAIL: " fmt "\n", ##__VA_ARGS__); \
        return 0; \
    } \
} while(0)

#define RUN(fn) do { \
    tests_run++; \
    printf("  %-50s ", #fn); \
    fflush(stdout); \
    if (fn()) { \
        printf("OK\n"); \
        tests_passed++; \
    } else { \
        printf("FAIL\n"); \
    } \
} while(0)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static float computeRMS(const Float32* buffer, int count) {
    double sum = 0.0;
    for (int i = 0; i < count; i++) {
        sum += (double)buffer[i] * (double)buffer[i];
    }
    return (float)sqrt(sum / (double)count);
}

static void generateSine(Float32* buffer, int frames, int channels) {
    for (int i = 0; i < frames; i++) {
        Float32 sample = sinf(2.0f * (float)M_PI * TONE_FREQ * (float)i / (float)gDevice_SampleRate);
        for (int ch = 0; ch < channels; ch++) {
            buffer[i * channels + ch] = sample;
        }
    }
}

// Helper: do a write+read cycle on given devices through the driver
// writeDevice/readDevice: kObjectID_Device or kObjectID_Device2
static int doLoopbackCycle(AudioObjectID writeDevice, AudioObjectID readDevice,
                           float* outWriteRMS, float* outReadRMS)
{
    int bufSize = TEST_FRAMES * kNumber_Of_Channels;
    Float32* writeBuf = calloc((size_t)bufSize, sizeof(Float32));
    Float32* readBuf  = calloc((size_t)bufSize, sizeof(Float32));

    // Generate sine wave in write buffer
    generateSine(writeBuf, TEST_FRAMES, kNumber_Of_Channels);
    *outWriteRMS = computeRMS(writeBuf, bufSize);

    // Build IOCycleInfo with valid timestamps
    AudioServerPlugInIOCycleInfo cycleInfo = {0};
    cycleInfo.mInputTime.mSampleTime = 0;
    cycleInfo.mOutputTime.mSampleTime = 0;
    cycleInfo.mCurrentTime.mSampleTime = 0;

    // Write to the write device's output
    OSStatus err = PouetLoopback_DoIOOperation(
        gAudioServerPlugInDriverRef,
        writeDevice,
        kObjectID_Stream_Output,
        0,                                          // clientID
        kAudioServerPlugInIOOperationWriteMix,
        TEST_FRAMES,
        &cycleInfo,
        writeBuf,
        NULL
    );
    if (err != noErr) {
        printf("  FAIL: WriteMix error %d\n", (int)err);
        free(writeBuf); free(readBuf);
        return 0;
    }

    // Read from the read device's input
    err = PouetLoopback_DoIOOperation(
        gAudioServerPlugInDriverRef,
        readDevice,
        kObjectID_Stream_Input,
        0,
        kAudioServerPlugInIOOperationReadInput,
        TEST_FRAMES,
        &cycleInfo,
        readBuf,
        NULL
    );
    if (err != noErr) {
        printf("  FAIL: ReadInput error %d\n", (int)err);
        free(writeBuf); free(readBuf);
        return 0;
    }

    *outReadRMS = computeRMS(readBuf, bufSize);

    free(writeBuf);
    free(readBuf);
    return 1;
}

// ---------------------------------------------------------------------------
// Setup / teardown: start and stop IO for both devices
// ---------------------------------------------------------------------------

static int setupIO(void) {
    OSStatus err;
    err = PouetLoopback_StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 0);
    if (err != noErr) { printf("  FAIL: StartIO device1 error %d\n", (int)err); return 0; }
    err = PouetLoopback_StartIO(gAudioServerPlugInDriverRef, kObjectID_Device2, 0);
    if (err != noErr) { printf("  FAIL: StartIO device2 error %d\n", (int)err); return 0; }
    return 1;
}

static void teardownIO(void) {
    PouetLoopback_StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 0);
    PouetLoopback_StopIO(gAudioServerPlugInDriverRef, kObjectID_Device2, 0);
}

// ---------------------------------------------------------------------------
// Test 1: Sound injection path (PouetMicrophone loopback)
// The app writes mic+inject audio to PouetMicrophone output.
// Zoom/Meet reads from PouetMicrophone input.
// Verify: write sine to Device1 output → read from Device1 input → signal present.
// ---------------------------------------------------------------------------

static int test_inject_sound(void) {
    if (!setupIO()) return 0;

    float writeRMS = 0, readRMS = 0;
    int ok = doLoopbackCycle(kObjectID_Device, kObjectID_Device, &writeRMS, &readRMS);
    teardownIO();
    if (!ok) return 0;

    ASSERT(readRMS > RMS_SIGNAL_THRESHOLD,
           "no signal on PouetMicrophone loopback (RMS=%.6f, need >%.4f)", readRMS, RMS_SIGNAL_THRESHOLD);

    printf("(write=%.4f read=%.4f) ", writeRMS, readRMS);
    return 1;
}

// ---------------------------------------------------------------------------
// Test 2: Audio dashcam capture path (PouetSpeaker loopback)
// Zoom/Meet outputs audio to PouetSpeaker.
// The app reads from PouetSpeaker input to fill the rolling dashcam buffer.
// Verify: write sine to Device2 output → read from Device2 input → signal present.
// ---------------------------------------------------------------------------

static int test_dashcam_audio_capture(void) {
    if (!setupIO()) return 0;

    float writeRMS = 0, readRMS = 0;
    int ok = doLoopbackCycle(kObjectID_Device2, kObjectID_Device2, &writeRMS, &readRMS);
    teardownIO();
    if (!ok) return 0;

    ASSERT(readRMS > RMS_SIGNAL_THRESHOLD,
           "no signal on PouetSpeaker loopback (RMS=%.6f, need >%.4f)", readRMS, RMS_SIGNAL_THRESHOLD);

    printf("(write=%.4f read=%.4f) ", writeRMS, readRMS);
    return 1;
}

// ---------------------------------------------------------------------------
// Test 3: Device isolation (Mic → Speaker must be silent)
// Write to PouetMicrophone, read from PouetSpeaker → must be silence.
// This is the bug the separate ring buffers fix.
// ---------------------------------------------------------------------------

static int test_device_isolation(void) {
    if (!setupIO()) return 0;

    float writeRMS = 0, readRMS = 0;
    int ok = doLoopbackCycle(kObjectID_Device, kObjectID_Device2, &writeRMS, &readRMS);
    teardownIO();
    if (!ok) return 0;

    ASSERT(readRMS < RMS_SILENCE_THRESHOLD,
           "crosstalk: PouetMicrophone → PouetSpeaker (RMS=%.6f, need <%.4f)", readRMS, RMS_SILENCE_THRESHOLD);

    printf("(RMS=%.6f) ", readRMS);
    return 1;
}

// ---------------------------------------------------------------------------
// Test 4: Reverse isolation (Speaker → Mic must be silent)
// ---------------------------------------------------------------------------

static int test_device_isolation_reverse(void) {
    if (!setupIO()) return 0;

    float writeRMS = 0, readRMS = 0;
    int ok = doLoopbackCycle(kObjectID_Device2, kObjectID_Device, &writeRMS, &readRMS);
    teardownIO();
    if (!ok) return 0;

    ASSERT(readRMS < RMS_SILENCE_THRESHOLD,
           "crosstalk: PouetSpeaker → PouetMicrophone (RMS=%.6f, need <%.4f)", readRMS, RMS_SILENCE_THRESHOLD);

    printf("(RMS=%.6f) ", readRMS);
    return 1;
}

// ---------------------------------------------------------------------------
// Test 5: Data integrity — read-back matches what was written
// ---------------------------------------------------------------------------

static int test_data_integrity(void) {
    if (!setupIO()) return 0;

    int bufSize = TEST_FRAMES * kNumber_Of_Channels;
    Float32* writeBuf = calloc((size_t)bufSize, sizeof(Float32));
    Float32* readBuf  = calloc((size_t)bufSize, sizeof(Float32));
    generateSine(writeBuf, TEST_FRAMES, kNumber_Of_Channels);

    AudioServerPlugInIOCycleInfo cycleInfo = {0};
    cycleInfo.mOutputTime.mSampleTime = 0;
    cycleInfo.mInputTime.mSampleTime = 0;
    cycleInfo.mCurrentTime.mSampleTime = 0;

    // Temporarily disable volume control influence (set volume to 1.0)
    Float32 savedVol = gVolume_Master_Value;
    gVolume_Master_Value = 1.0f;
    Boolean savedMute = gMute_Master_Value;
    gMute_Master_Value = false;

    PouetLoopback_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device,
        kObjectID_Stream_Output, 0, kAudioServerPlugInIOOperationWriteMix,
        TEST_FRAMES, &cycleInfo, writeBuf, NULL);

    PouetLoopback_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device,
        kObjectID_Stream_Input, 0, kAudioServerPlugInIOOperationReadInput,
        TEST_FRAMES, &cycleInfo, readBuf, NULL);

    gVolume_Master_Value = savedVol;
    gMute_Master_Value = savedMute;
    teardownIO();

    // Compare sample-by-sample
    float maxDiff = 0;
    for (int i = 0; i < bufSize; i++) {
        float diff = fabsf(writeBuf[i] - readBuf[i]);
        if (diff > maxDiff) maxDiff = diff;
    }

    free(writeBuf);
    free(readBuf);

    ASSERT(maxDiff < 0.0001f,
           "data mismatch (max sample diff=%.6f, need <0.0001)", maxDiff);

    printf("(max_diff=%.8f) ", maxDiff);
    return 1;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(void) {
    printf("=== Loopback Unit Tests (no driver install needed) ===\n");

    RUN(test_inject_sound);
    RUN(test_dashcam_audio_capture);
    RUN(test_device_isolation);
    RUN(test_device_isolation_reverse);
    RUN(test_data_integrity);

    printf("\n%d/%d loopback tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
