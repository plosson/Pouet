// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VirtualMic",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "CSHMBridge",
            path: "Sources/CSHMBridge"
        ),
    ]
)
