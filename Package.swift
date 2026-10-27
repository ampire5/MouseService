// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MouseService",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MouseService", targets: ["MouseService"]),
        // What apps link: the client and the contract's types.
        .library(name: "MouseClient", targets: ["MouseClient", "MouseContract"]),
    ],
    targets: [
        // What a press and a drag of the side buttons mean: pure, no AppKit, no events.
        .target(name: "GestureCore"),
        // Pointer and wheel rules per device and app (devices.json, LinearMouse's format): pure, no IOKit, no events.
        .target(name: "PointerCore"),
        // The XPC contract: messages and their encoding, no logic.
        .target(name: "MouseContract"),
        // Who owns the mouse and what it should be: pure, no hardware, no XPC.
        .target(name: "MouseCore", dependencies: ["MouseContract"]),
        // The service's XPC side over the arbiter and a mouse driver.
        .target(name: "MouseServiceKit", dependencies: ["MouseCore", "MouseContract"]),
        // The apps' side of the contract.
        .target(name: "MouseClient", dependencies: ["MouseContract"]),
        .executableTarget(name: "MouseService", dependencies: ["GestureCore", "PointerCore"]),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
        .testTarget(name: "PointerCoreTests", dependencies: ["PointerCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MouseContractTests", dependencies: ["MouseContract"]),
        .testTarget(name: "MouseCoreTests", dependencies: ["MouseCore", "MouseContract"]),
        .testTarget(name: "MouseServiceKitTests", dependencies: ["MouseServiceKit", "MouseClient", "MouseCore",
                                                                 "MouseContract"]),
    ],
    swiftLanguageModes: [.v6]
)
