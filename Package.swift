// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MouseService",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MouseService", targets: ["MouseService"]),
    ],
    targets: [
        // What a press and a drag of the side buttons mean: pure, no AppKit, no events.
        .target(name: "GestureCore"),
        // Pointer and wheel rules per device and app (devices.json, LinearMouse's format): pure, no IOKit, no events.
        .target(name: "PointerCore"),
        .executableTarget(name: "MouseService", dependencies: ["GestureCore", "PointerCore"]),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
        .testTarget(name: "PointerCoreTests", dependencies: ["PointerCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
