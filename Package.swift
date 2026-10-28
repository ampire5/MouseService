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
    dependencies: [
        .package(url: "https://github.com/ampire5/LogiHIDPP.git", from: "0.1.0"),
        .package(url: "https://github.com/ampire5/SettingsKit.git", from: "0.7.0"),
        // The devices config (config.yaml).
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // What a press and a drag of the side buttons mean: pure, no AppKit, no events.
        .target(name: "GestureCore"),
        // Pointer and wheel rules per device and app (config.yaml): pure, no IOKit, no events.
        .target(name: "PointerCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        // The XPC contract: messages and their encoding, no logic.
        .target(name: "MouseContract"),
        // Who owns the mouse and what it should be: pure, no hardware, no XPC.
        .target(name: "MouseCore", dependencies: ["MouseContract"]),
        // The service's XPC side over the arbiter and a mouse driver.
        .target(name: "MouseServiceKit", dependencies: ["MouseCore", "MouseContract"]),
        // The apps' side of the contract.
        .target(name: "MouseClient", dependencies: ["MouseContract"]),
        .executableTarget(name: "MouseService", dependencies: [
            "GestureCore", "PointerCore", "MouseServiceKit", "MouseCore", "MouseContract", "MouseClient",
            .product(name: "LogiHIDPP", package: "LogiHIDPP"),
            .product(name: "SettingsKit", package: "SettingsKit"),
        ]),
        // A test client: takes buttons, declares wheel areas, prints events with their latency (docs/bench.md).
        .executableTarget(name: "mouse-client-probe", dependencies: ["MouseClient", "MouseContract"]),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
        .testTarget(name: "PointerCoreTests", dependencies: ["PointerCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MouseContractTests", dependencies: ["MouseContract"]),
        .testTarget(name: "MouseCoreTests", dependencies: ["MouseCore", "MouseContract"]),
        .testTarget(name: "MouseServiceKitTests", dependencies: ["MouseServiceKit", "MouseClient", "MouseCore",
                                                                 "MouseContract"]),
    ],
    swiftLanguageModes: [.v6]
)
