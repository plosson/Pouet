# Pouet

## What Pouet does

Pouet is a macOS audio man-in-the-middle for video calls. It sits between the user's real audio hardware and all other applications, enabling sound injection into the microphone stream, local monitoring of injected sounds, and dashcam-style recording.

### The problem

During video calls (Zoom, Meet, Teams…), users want to:
1. **Inject sounds** (soundboard) into their microphone feed — other participants hear the sound as if it came from the mic, and the user hears it too (local monitoring).
2. **Dashcam-record** the last N seconds on demand — capture what was just said without running a full recording. The recording should include both the remote participant's audio AND the injected sounds.
3. **Dashcam-record video** of a selected window the same way, with the full audio mix.

### How it works

Pouet installs a CoreAudio HAL driver that creates two virtual audio devices:
- **PouetMicrophone** — set as the system default *input* (what apps see as "the mic")
- **PouetSpeaker** — set as the system default *output* (where apps send their audio)

The companion Swift app acts as a transparent proxy between real hardware and these virtual devices:

```
Mic path (input):
  Real mic ──▶ Pouet app (mix in soundboard) ──▶ PouetMicrophone ──▶ Zoom reads as "mic"

Speaker path (output):
  Zoom ──▶ PouetSpeaker ──▶ Pouet app (rolling buffer + dashcam) ──▶ Real speakers

Sound injection (both paths):
  Sound file ──▶ PouetMicrophone (remote hears it)
              ──▶ PouetSpeaker (user hears it via speaker proxy)
```

The app itself never uses the virtual devices for its own I/O — it talks directly to the real hardware chosen by the user. Other apps are unaware of the proxy; they just see PouetMicrophone/PouetSpeaker as normal audio devices.

On shutdown (or crash recovery), the app restores the original system default devices so the user isn't left with silent virtual devices.

### Why two virtual devices?

- **PouetMicrophone** is needed so the app can mix real mic + injected sounds and present them as a single mic input to Zoom/Meet.
- **PouetSpeaker** is needed for two reasons:
  1. **Local monitoring**: injected sounds are also played to PouetSpeaker so the user hears them through the speaker proxy → real speakers.
  2. **Audio dashcam**: the speaker proxy captures the full device-level mix on PouetSpeaker (remote audio + injected sounds). ScreenCaptureKit alone can't do this — it captures per-app audio only, so it would get Zoom's output but miss the injected sounds from the Pouet app.

### Key features

- **Soundboard**: drop audio files into a folder, click to inject into the mic stream with adjustable volume. Injected sounds go to both PouetMicrophone (remote) and PouetSpeaker (local monitoring).
- **Audio dashcam**: rolling buffer of the full PouetSpeaker mix; hotkey saves the last N seconds as M4A.
- **Video dashcam**: ScreenCaptureKit-based window capture with rolling segment buffer; hotkey saves as MP4. Audio comes from the speaker proxy (full mix), not from ScreenCaptureKit's per-app audio.
- **Global hotkeys**: Cmd+key for audio snapshot, double-tap for video snapshot.
- **Zero-config proxy**: auto-selects real devices, switches system defaults on start, restores on quit.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  CoreAudio HAL Driver (C)                                        │
│  Driver/PouetLoopback.c — single AudioServerPlugin binary        │
│  Creates: PouetMicrophone (device 1) + PouetSpeaker (device 2)  │
│  Each device has its own ring buffer (independent loopback)      │
└──────────────────────────────────────────────────────────────────┘
         ▲ write output         ▲ read input
         │                      │
┌────────┴──────────────────────┴──────────────────────────────────┐
│  Swift App (SPM + SwiftUI)                                       │
│                                                                   │
│  AudioService  — two AVAudioEngine instances:                    │
│    • Mic proxy:     real mic → mixer (+ inject) → PouetMic      │
│    • Speaker proxy: PouetSpeaker input → real speakers           │
│                     + rolling buffer for audio dashcam           │
│                                                                   │
│  AppService    — config persistence, state, polling, lifecycle   │
│  VideoService  — ScreenCaptureKit window capture (video only)    │
│  HotkeyService — global Cmd+key event monitors                  │
└──────────────────────────────────────────────────────────────────┘
```

### Audio flow detail

```
                    ┌─────────────┐
  Real mic ────────▶│             │──▶ PouetMicrophone ──▶ Zoom reads as mic
                    │  Mic proxy  │
  Sound file ──┬──▶│  (Engine 1) │
               │   └─────────────┘
               │
               │   ┌─────────────────┐
               └──▶│                 │──▶ Real speakers (user hears inject)
  Zoom audio ─────▶│  Speaker proxy  │
  (PouetSpeaker)   │  (Engine 2)    │──▶ Rolling dashcam buffer
                   └─────────────────┘
```

## Build

Pure Makefile build — no Xcode project. Swift app is built with Swift Package Manager (`swift build`), C driver with `clang`.

```bash
make              # build driver + app
make run          # build + launch app
make clean        # remove build/ and .build/
make install      # install driver locally (sudo, restarts coreaudiod)
make uninstall    # remove driver (sudo)
```

Swift sources live in `Sources/Pouet/` (UI and Services). Driver is a single C file (`Driver/PouetLoopback.c`). Non-code assets (Info.plist, entitlements, icons) stay in `App/`.

## Testing

Tests are C-based, following the BlackHole pattern. No Xcode or XCTest needed.

```bash
make test                # run all tests
make test-loopback       # driver unit tests (no install needed)
make test-integration    # device property tests (requires installed driver)
```

**Loopback tests** (`Tests/test_loopback.c`): Compile the driver source directly (`#include "../Driver/PouetLoopback.c"`) and call driver functions in-process. Tests:
- Sound injection path: write sine → PouetMicrophone → read back → verify signal
- Dashcam capture path: write sine → PouetSpeaker → read back → verify signal
- Device isolation: write to one device → read from other → verify silence (no crosstalk)
- Data integrity: sample-perfect round-trip

**Integration tests** (`Tests/test_integration.c`): Test both devices' CoreAudio properties (sample rate, streams, format) against the installed driver.

## Release

1. Version is derived from the latest git tag (`git describe`)
2. Commit changes
3. Tag and push:

```bash
git tag v1.x.x && git push origin main --tags
```

CI (.github/workflows/build.yml) will automatically: build → sign → notarize → create GitHub Release with the `.pkg` installer.

## Code guidelines

- Keep it simple. No over-engineering, no premature abstractions.
- Go step by step. Never do large refactors in one shot — test stability at each step.
- Prefer editing existing files over creating new ones.
- Run the `code-simplifier` agent after each task to clean up.
- No backward-compatibility shims — if something is unused, delete it.
- Driver code (C) runs on the real-time audio thread — no allocations, no locks, no syscalls.
- Swift app is split into `Sources/Pouet/UI/` (SwiftUI views) and `Sources/Pouet/Services/` (audio, state, logic).
- Build with `make` to verify the build passes before considering a task done.
- Run `make test-loopback` after any driver changes to verify ring buffer correctness.
