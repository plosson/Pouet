// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pouet",
    platforms: [.macOS(.v13)],
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
