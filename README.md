# VirtualMic — macOS Virtual Microphone Driver

A minimal, production-ready **Audio Server Plugin** that creates a virtual
microphone on macOS. Feed it any MP3, AAC, WAV, or FLAC file from the command
line — it appears as a real mic input to every app on your Mac.

```
┌──────────────────────────────────────────────────────┐
│  VirtualMicApp (your process)                        │
│  • Decodes MP3/AAC/WAV via AVFoundation              │
│  • Resamples to 48 kHz stereo Float32                │
│  • Writes into shared memory ring buffer ──────────► │──┐
└──────────────────────────────────────────────────────┘  │  /VirtualMicAudio
                                                           │  (POSIX shm)
┌──────────────────────────────────────────────────────┐  │
│  VirtualMic.driver (inside coreaudiod)               │  │
│  • Audio Server Plugin (no kext, no SIP changes)     │◄─┘
│  • DoIOOperation reads ring buffer → HAL             │
│  • Appears as "VirtualMic" mic in System Settings    │
└──────────────────────────────────────────────────────┘
         ↓
   Zoom / Discord / FaceTime / any CoreAudio app
```

## Architecture

| Component | Language | What it does |
|-----------|----------|--------------|
| `VirtualMicDriver.c` | C | Audio Server Plugin — implements the 23-function HAL vtable, reads from shared memory on the real-time audio thread |
| `App/main.swift` | Swift | CLI — decodes audio files, resamples, writes to shared memory ring buffer |
| `SharedMemory.h` | C | Shared ring-buffer layout (included by both) |
| `Installer/` | pkg | One-click `.pkg` installer with postinstall script |

## Requirements

- macOS 12 Monterey or later (Intel or Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- Apple Developer Program membership (for signing + notarization)

## Build

```bash
# Clone / open the project folder
cd VirtualMicDriver

# Build driver bundle + CLI app (unsigned, for local testing)
make

# Build, sign, and create installer .pkg
make DEVID="Developer ID Application: Jane Smith (ABCD1234)" \
     INSTALLER_ID="Developer ID Installer: Jane Smith (ABCD1234)" \
     pkg

# Notarize (requires APPLE_ID, APPLE_APP_PASSWORD, TEAM_ID env vars)
make notarize
```

## Local install (no signing required for personal use)

```bash
make install        # requires sudo — copies driver + restarts coreaudiod
```

If macOS shows "not from identified developer", go to:
**System Settings → Privacy & Security → scroll down → Allow Anyway**

## Usage

```bash
# Inject an MP3 (plays once then drains)
VirtualMicApp inject ~/Music/track.mp3

# Loop audio continuously (Ctrl-C to stop)
VirtualMicApp stream ~/Music/background.mp3

# Stop / clear buffer
VirtualMicApp stop

# Check how full the ring buffer is
VirtualMicApp status
```

Then select **VirtualMic** as your microphone input in any app.

## Supported audio formats

Everything AVFoundation can decode: MP3, AAC (.m4a), WAV, AIFF, FLAC, ALAC,
Opus (macOS 13+). The app automatically resamples to **48 kHz stereo Float32**
before writing to the ring buffer.

## How it works in detail

### Driver side (`VirtualMicDriver.c`)

1. `VirtualMicDriverFactory()` is the bundle entry point — `coreaudiod` calls
   it when it discovers the `.driver` bundle in `/Library/Audio/Plug-Ins/HAL/`.
2. The driver returns a COM-style vtable (`AudioServerPlugInDriverInterface`)
   with 23 function pointers.
3. On `StartIO`, the driver opens (or creates) the POSIX shared memory region
   `/VirtualMicAudio` and anchors the HAL clock.
4. On every `DoIOOperation(ReadInput)` callback (real-time thread, ~512 frames
   @ 48 kHz ≈ every 10.7 ms), it reads from the lock-free ring buffer and
   fills the HAL's output buffer. If the ring is empty, silence is output.
5. `GetZeroTimeStamp` advances the HAL clock by computing elapsed host ticks
   since the anchor, quantised to buffer periods.

### App side (`App/main.swift`)

1. Opens the same shared memory region.
2. Decodes the audio file with `AVAudioFile` + `AVAudioConverter`
   (handles any sample rate and channel count → 48 kHz stereo).
3. Writes interleaved Float32 samples into the ring buffer using atomic
   `writePos` increments. The driver's `readPos` is also visible in shared
   memory so the app can back-pressure if the buffer fills up.

### Ring buffer layout

```
[writePos: uint64]  ← producer (app) increments
[readPos:  uint64]  ← consumer (driver) increments
[capacity: uint32]  ← total float slots
[pad:      uint32]
[data:     float[capacity]]  ← interleaved L,R,L,R …
```

Indices wrap via `pos % capacity`. The difference `writePos - readPos` gives
available samples. No mutex is needed — one producer, one consumer, atomic ops.

## Signing & distribution checklist

- [ ] Create App ID `com.virtualmicdrv.driver` in Apple Developer portal
- [ ] Download **Developer ID Application** certificate
- [ ] Download **Developer ID Installer** certificate
- [ ] Run `make pkg` with correct `DEVID` / `INSTALLER_ID`
- [ ] Run `make notarize` (set `APPLE_ID`, `APPLE_APP_PASSWORD`, `TEAM_ID`)
- [ ] Distribute `build/VirtualMic-1.0.0.pkg`

## Uninstall

```bash
make uninstall
# or manually:
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VirtualMic.driver
sudo rm -f  /usr/local/bin/VirtualMicApp
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
```

## License

MIT — see `Installer/License.txt`
