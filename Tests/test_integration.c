// test_integration.c — Integration tests against the installed Pouet driver.
// Requires the driver to be loaded in coreaudiod. Skips gracefully if not found.
// Build: clang -framework CoreAudio -o test_integration test_integration.c
// Run:   ./test_integration

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

#define EXPECTED_SAMPLE_RATE 48000.0
#define EXPECTED_CHANNELS    2

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        return 0; \
    } \
} while(0)

// ---------------------------------------------------------------------------
// Find the Pouet microphone device
// ---------------------------------------------------------------------------
static AudioDeviceID findPouetDevice(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    if (err != 0 || size == 0) return kAudioObjectUnknown;

    int count = (int)(size / sizeof(AudioDeviceID));
    AudioDeviceID *devices = malloc(size);
    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devices);
    if (err != 0) { free(devices); return kAudioObjectUnknown; }

    AudioDeviceID found = kAudioObjectUnknown;
    for (int i = 0; i < count; i++) {
        CFStringRef name = NULL;
        AudioObjectPropertyAddress nameAddr = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 nameSize = sizeof(name);
        err = AudioObjectGetPropertyData(devices[i], &nameAddr, 0, NULL, &nameSize, &name);
        if (err == 0 && name) {
            char buf[256];
            CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
            CFRelease(name);
            if (strstr(buf, "Pouet") != NULL) {
                found = devices[i];
                break;
            }
        }
    }
    free(devices);
    return found;
}

// ---------------------------------------------------------------------------
// Helper: get nominal sample rate
// ---------------------------------------------------------------------------
static OSStatus getRate(AudioDeviceID dev, Float64 *rate) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(*rate);
    return AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, rate);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

static int test_reports_48k(AudioDeviceID dev) {
    Float64 rate = 0;
    OSStatus err = getRate(dev, &rate);
    ASSERT(err == 0, "GetPropertyData failed: %d", (int)err);
    ASSERT(rate == EXPECTED_SAMPLE_RATE, "expected %.0f, got %.0f", EXPECTED_SAMPLE_RATE, rate);
    return 1;
}

static int test_set_44100_succeeds(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 newRate = 44100.0;
    OSStatus err = AudioObjectSetPropertyData(dev, &addr, 0, NULL, sizeof(newRate), &newRate);
    ASSERT(err == 0, "SetPropertyData(44100) returned error: %d", (int)err);
    return 1;
}

static int test_rate_unchanged_after_set(AudioDeviceID dev) {
    // Set to 44100 first
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 newRate = 44100.0;
    AudioObjectSetPropertyData(dev, &addr, 0, NULL, sizeof(newRate), &newRate);

    // Verify still 48000
    Float64 rate = 0;
    OSStatus err = getRate(dev, &rate);
    ASSERT(err == 0, "GetPropertyData failed: %d", (int)err);
    ASSERT(rate == EXPECTED_SAMPLE_RATE,
           "rate changed to %.0f after set(44100), expected %.0f", rate, EXPECTED_SAMPLE_RATE);
    return 1;
}

static int test_available_rates_only_48k(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size);
    ASSERT(err == 0, "GetPropertyDataSize failed: %d", (int)err);

    int count = (int)(size / sizeof(AudioValueRange));
    ASSERT(count == 1, "expected 1 available rate, got %d", count);

    AudioValueRange range;
    err = AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &range);
    ASSERT(err == 0, "GetPropertyData failed: %d", (int)err);
    ASSERT(range.mMinimum == EXPECTED_SAMPLE_RATE && range.mMaximum == EXPECTED_SAMPLE_RATE,
           "expected range [%.0f, %.0f], got [%.0f, %.0f]",
           EXPECTED_SAMPLE_RATE, EXPECTED_SAMPLE_RATE, range.mMinimum, range.mMaximum);
    return 1;
}

static int test_stream_format_48k_stereo(AudioDeviceID dev) {
    // Find the input stream
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size);
    ASSERT(err == 0, "GetPropertyDataSize(streams) failed: %d", (int)err);
    ASSERT(size >= sizeof(AudioStreamID), "no input streams found");

    AudioStreamID stream;
    size = sizeof(stream);
    err = AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &stream);
    ASSERT(err == 0, "GetPropertyData(streams) failed: %d", (int)err);

    // Get virtual format
    AudioObjectPropertyAddress fmtAddr = {
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription asbd;
    size = sizeof(asbd);
    err = AudioObjectGetPropertyData(stream, &fmtAddr, 0, NULL, &size, &asbd);
    ASSERT(err == 0, "GetPropertyData(VirtualFormat) failed: %d", (int)err);
    ASSERT(asbd.mSampleRate == EXPECTED_SAMPLE_RATE,
           "stream sample rate: expected %.0f, got %.0f", EXPECTED_SAMPLE_RATE, asbd.mSampleRate);
    ASSERT(asbd.mChannelsPerFrame == EXPECTED_CHANNELS,
           "stream channels: expected %d, got %u", EXPECTED_CHANNELS, (unsigned)asbd.mChannelsPerFrame);
    ASSERT(asbd.mFormatID == kAudioFormatLinearPCM, "stream format is not LPCM");
    ASSERT(asbd.mBitsPerChannel == 32, "expected 32-bit, got %u", (unsigned)asbd.mBitsPerChannel);
    return 1;
}

static int test_set_various_rates_all_succeed(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 rates[] = {8000, 16000, 22050, 44100, 48000, 88200, 96000, 192000};
    for (int i = 0; i < 8; i++) {
        OSStatus err = AudioObjectSetPropertyData(dev, &addr, 0, NULL, sizeof(rates[i]), &rates[i]);
        ASSERT(err == 0, "SetPropertyData(%.0f) returned error: %d", rates[i], (int)err);
    }
    // Must still report 48000
    Float64 rate = 0;
    OSStatus err = getRate(dev, &rate);
    ASSERT(err == 0, "GetPropertyData failed after sets: %d", (int)err);
    ASSERT(rate == EXPECTED_SAMPLE_RATE,
           "rate drifted to %.0f after multiple sets", rate);
    return 1;
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

#define RUN(fn, dev) do { \
    tests_run++; \
    if (fn(dev)) { \
        printf("  %-45s OK\n", #fn); \
        tests_passed++; \
    } else { \
        printf("  %-45s FAIL\n", #fn); \
    } \
} while(0)

int main(void) {
    AudioDeviceID dev = findPouetDevice();
    if (dev == kAudioObjectUnknown) {
        printf("SKIP: Pouet driver not installed — install with 'make install' first\n");
        return 0;
    }
    printf("=== Integration Tests (Pouet device ID: %u) ===\n", (unsigned)dev);

    RUN(test_reports_48k, dev);
    RUN(test_set_44100_succeeds, dev);
    RUN(test_rate_unchanged_after_set, dev);
    RUN(test_available_rates_only_48k, dev);
    RUN(test_stream_format_48k_stereo, dev);
    RUN(test_set_various_rates_all_succeed, dev);

    printf("\n%d/%d integration tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
