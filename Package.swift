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
        .executableTarget(name: "MouseService", dependencies: ["GestureCore"]),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
    ],
    swiftLanguageModes: [.v6]
)
