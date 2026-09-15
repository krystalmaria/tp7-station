// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TP7Kit", targets: ["TP7Kit"]),
        .library(name: "AudioMetaKit", targets: ["AudioMetaKit"]),
        .library(name: "InboxKit", targets: ["InboxKit"]),
    ],
    targets: [
        .target(name: "TP7Kit"),
        .target(name: "AudioMetaKit"),
        .target(name: "InboxKit", dependencies: ["TP7Kit", "AudioMetaKit"]),
        .testTarget(name: "TP7KitTests", dependencies: ["TP7Kit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AudioMetaKitTests", dependencies: ["AudioMetaKit"]),
        .testTarget(name: "InboxKitTests", dependencies: ["InboxKit"]),
    ]
)
