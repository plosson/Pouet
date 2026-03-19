// test_integration.c — Integration tests against the installed Pouet loopback driver.
// Requires the driver to be loaded in coreaudiod. Skips gracefully if not found.
// Build: clang -framework CoreAudio -framework CoreFoundation -o test_integration test_integration.c
// Run:   ./test_integration

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
// Find the PouetMicrophone loopback device
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
            if (strstr(buf, "PouetMicrophone") != NULL) {
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

static int test_default_rate_48k(AudioDeviceID dev) {
    Float64 rate = 0;
    OSStatus err = getRate(dev, &rate);
    ASSERT(err == 0, "GetPropertyData failed: %d", (int)err);
    ASSERT(rate == EXPECTED_SAMPLE_RATE, "expected %.0f, got %.0f", EXPECTED_SAMPLE_RATE, rate);
    return 1;
}

static int test_has_input_stream(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size);
    ASSERT(err == 0, "GetPropertyDataSize(input streams) failed: %d", (int)err);
    ASSERT(size >= sizeof(AudioStreamID), "no input streams found");
    return 1;
}

static int test_has_output_stream(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size);
    ASSERT(err == 0, "GetPropertyDataSize(output streams) failed: %d", (int)err);
    ASSERT(size >= sizeof(AudioStreamID), "no output streams found");
    return 1;
}

static int test_input_stream_format(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    AudioStreamID stream;
    UInt32 size = sizeof(stream);
    OSStatus err = AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &stream);
    ASSERT(err == 0, "GetPropertyData(input streams) failed: %d", (int)err);

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

static int test_supports_multiple_rates(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size);
    ASSERT(err == 0, "GetPropertyDataSize failed: %d", (int)err);

    int count = (int)(size / sizeof(AudioValueRange));
    ASSERT(count > 1, "expected multiple sample rates, got %d", count);
    printf("(%d rates) ", count);
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
        printf("SKIP: PouetMicrophone driver not installed — install with 'make install' first\n");
        return 0;
    }
    printf("=== Integration Tests (PouetMicrophone device ID: %u) ===\n", (unsigned)dev);

    RUN(test_default_rate_48k, dev);
    RUN(test_has_input_stream, dev);
    RUN(test_has_output_stream, dev);
    RUN(test_input_stream_format, dev);
    RUN(test_supports_multiple_rates, dev);

    printf("\n%d/%d integration tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
