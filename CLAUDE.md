# Pouet

macOS virtual microphone driver (C Audio Server Plugin) + companion Swift app. Proxies a real mic through shared memory, allows audio injection from soundboard files.

## Build

```bash
make          # build driver + app (unsigned)
make clean    # remove build/
make install  # install driver locally (sudo)
make uninstall
```

## Release

1. Update version in `App/Info.plist` (both `CFBundleShortVersionString` and `CFBundleVersion`)
2. Commit the version bump
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
- Swift app uses SwiftUI with a single-file UI (`ContentView.swift`) and service layer (`AppService.swift`).
- Build with `make` (not Xcode). Verify the build passes before considering a task done.
