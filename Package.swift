// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pouet",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Pouet",
            path: "Sources/Pouet",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
