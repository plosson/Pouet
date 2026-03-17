// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pouet",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SHMBridge",
            path: "Sources/SHMBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Pouet",
            dependencies: ["SHMBridge"],
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
