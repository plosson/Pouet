# Pouet

macOS virtual microphone driver (C Audio Server Plugin) + companion Swift app. Proxies a real mic through shared memory, allows audio injection from soundboard files.

## Build

Pure Makefile build — no Xcode project. Swift app is built with Swift Package Manager (`swift build`), C driver with `clang`.

```bash
make          # build driver + app (ad-hoc signed)
make run      # build + launch app
make clean    # remove build/ and .build/
make install  # install driver locally (sudo)
make uninstall
```

Swift sources live in `Sources/Pouet/` (UI and Services) with C interop via `Sources/SHMBridge/`. Non-code assets (Info.plist, entitlements, icons) stay in `App/`.

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
