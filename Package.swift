// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VirtualMicCli",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CSHMBridge",
            path: "Sources/CSHMBridge"
        ),
        .executableTarget(
            name: "VirtualMicCli",
            dependencies: [
                "CSHMBridge",
                .product(name: "Swifter", package: "swifter"),
            ],
            path: "Sources/VirtualMicCli",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
