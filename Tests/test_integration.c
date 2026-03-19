// test_integration.c — Integration tests against the installed Pouet loopback driver.
// Tests device properties for BOTH PouetMicrophone and PouetSpeaker.
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
// Find a Pouet device by name substring
// ---------------------------------------------------------------------------
static AudioDeviceID findDeviceByName(const char* needle) {
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
            if (strstr(buf, needle) != NULL) {
                found = devices[i];
                break;
            }
        }
    }
    free(devices);
    return found;
}

// ---------------------------------------------------------------------------
// Helpers
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

static UInt32 getStreamCount(AudioDeviceID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size) != noErr) return 0;
    return size / sizeof(AudioStreamID);
}

// ---------------------------------------------------------------------------
// Tests (parameterized by device)
// ---------------------------------------------------------------------------

static int test_default_rate_48k(AudioDeviceID dev) {
    Float64 rate = 0;
    OSStatus err = getRate(dev, &rate);
    ASSERT(err == 0, "GetPropertyData failed: %d", (int)err);
    ASSERT(rate == EXPECTED_SAMPLE_RATE, "expected %.0f, got %.0f", EXPECTED_SAMPLE_RATE, rate);
    return 1;
}

static int test_has_input_stream(AudioDeviceID dev) {
    UInt32 count = getStreamCount(dev, kAudioObjectPropertyScopeInput);
    ASSERT(count >= 1, "no input streams found (count=%u)", (unsigned)count);
    return 1;
}

static int test_has_output_stream(AudioDeviceID dev) {
    UInt32 count = getStreamCount(dev, kAudioObjectPropertyScopeOutput);
    ASSERT(count >= 1, "no output streams found (count=%u)", (unsigned)count);
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
           "sample rate: expected %.0f, got %.0f", EXPECTED_SAMPLE_RATE, asbd.mSampleRate);
    ASSERT(asbd.mChannelsPerFrame == EXPECTED_CHANNELS,
           "channels: expected %d, got %u", EXPECTED_CHANNELS, (unsigned)asbd.mChannelsPerFrame);
    ASSERT(asbd.mFormatID == kAudioFormatLinearPCM, "format is not LPCM");
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

#define RUN(label, fn, dev) do { \
    tests_run++; \
    printf("  %-50s ", label); \
    fflush(stdout); \
    if (fn(dev)) { \
        printf("OK\n"); \
        tests_passed++; \
    } else { \
        printf("FAIL\n"); \
    } \
} while(0)

static void runDeviceTests(const char* name, AudioDeviceID dev) {
    char label[80];
    #define DEVTEST(fn) do { \
        snprintf(label, sizeof(label), "%s: %s", name, #fn); \
        RUN(label, fn, dev); \
    } while(0)

    DEVTEST(test_default_rate_48k);
    DEVTEST(test_has_input_stream);
    DEVTEST(test_has_output_stream);
    DEVTEST(test_input_stream_format);
    DEVTEST(test_supports_multiple_rates);
    #undef DEVTEST
}

int main(void) {
    AudioDeviceID mic = findDeviceByName("PouetMicrophone");
    AudioDeviceID spk = findDeviceByName("PouetSpeaker");

    if (mic == kAudioObjectUnknown && spk == kAudioObjectUnknown) {
        printf("SKIP: Pouet driver not installed — install with 'make install' first\n");
        return 0;
    }

    printf("=== Integration Tests ===\n");

    if (mic != kAudioObjectUnknown) {
        printf("\n-- PouetMicrophone (device ID: %u) --\n", (unsigned)mic);
        runDeviceTests("Mic", mic);
    } else {
        printf("\nWARN: PouetMicrophone not found, skipping\n");
    }

    if (spk != kAudioObjectUnknown) {
        printf("\n-- PouetSpeaker (device ID: %u) --\n", (unsigned)spk);
        runDeviceTests("Spk", spk);
    } else {
        printf("\nWARN: PouetSpeaker not found, skipping\n");
    }

    printf("\n%d/%d integration tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
