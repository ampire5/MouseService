import Foundation
import Testing
import PointerCore
@testable import MouseService

@Test @MainActor func deviceSelectionShowsOnlyMice() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = "MouseServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let file = DevicePreferencesFile(url: directory.appendingPathComponent("config.yaml"))
    let store = ServiceSettings(defaults: defaults)
    let model = DeviceSettingsController(file: file, preferences: store)
    let mouse = DeviceIdentity(vendorID: 0x1234, productID: 1, productName: "Mouse", category: .mouse)
    let trackpad = DeviceIdentity(vendorID: 0x1234, productID: 2, productName: "Built-in", category: .trackpad)
    let keyboard = DeviceIdentity(vendorID: 0x1234, productID: 6, productName: "Keyboard", category: .other)
    try await file.replace(with: """
    devices:
      Built-in: { id: '1234:2' }
      Office: { id: '1234:3', category: trackpad }
      Offline Mouse: { id: '1234:4', category: mouse, apps: { editor: { pointer-profile: linear } } }
      Unknown: { id: '1234:5' }
      Mistaken for a mouse: { id: '1234:6', category: mouse }
    """)
    model.connectedDevices = { [trackpad, mouse, keyboard] }
    await model.refresh()
    #expect(model.devices.map(\.identity.productID) == [1, 4])
    #expect(model.selectedDevice == mouse)
    #expect(model.speed == "0.125")
    #expect(await model.set("reverse-scroll", value: "vertical"))
    await model.select("1234:4/")
    #expect(model.speed == "0.125")
    #expect(model.reverse == "none")
    #expect(model.pointerProfile == .macOS)
    await model.set("pointer-profile", value: "libinput-adaptive")
    #expect(model.pointerProfile == .libinputAdaptive)
    #expect(await model.set("speed", value: "0.7", for: SettingsDevice.key(mouse)) == false)
    #expect(model.speed == "0.125")  // stale mouse editor must not write to the newly selected mouse
    let yaml = try await file.load()
    let rules = try DeviceRules(yaml: yaml)
    let offlineMouse = try #require(model.selectedDevice)
    #expect(rules.resolve(trackpad, app: nil).pointer.speed == nil)
    #expect(rules.resolve(offlineMouse, app: nil).pointer.profile == .libinputAdaptive)
    #expect(rules.resolve(offlineMouse, app: "editor").pointer.profile == .linear)
    await model.select(SettingsDevice.key(mouse))
    #expect(model.reverse == "vertical")
    #expect(model.pointerProfile == .macOS)
    model.connectedDevices = { [] }
    await model.refresh()
    #expect(model.devices.map(\.identity.productID) == [4, 1])
}

@Test @MainActor func onlyPrimaryMouseCollectionsCountAsMice() {
    #expect(SystemPointerDeviceService.pointerCategory(
        primaryPage: 1, primaryUsage: 6, vendor: 0x1234, product: 1,
        trackpad: false, mouse: true) == .other)
    #expect(SystemPointerDeviceService.pointerCategory(
        primaryPage: 1, primaryUsage: 2, vendor: 0x1915, product: 0xeeee,
        trackpad: false, mouse: true) == .other)
    #expect(SystemPointerDeviceService.pointerCategory(
        primaryPage: 1, primaryUsage: 2, vendor: 0x046d, product: 0xc548,
        trackpad: false, mouse: true) == .mouse)
    #expect(SystemPointerDeviceService.pointerCategory(
        primaryPage: 1, primaryUsage: 2, vendor: 0, product: 0,
        trackpad: true, mouse: true) == .trackpad)
}

@Test @MainActor func controllerImportRejectsInvalidPreferencesWithoutChangingAnything() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.yaml")
    let original = "devices:\n"
    try original.write(to: url, atomically: true, encoding: .utf8)
    let source = directory.appendingPathComponent("invalid.json")
    try Data(#"{"version":1,"config":"devices: {}","preferences":{"wheel-mode":"bad"}}"#.utf8).write(to: source)
    let name = "MouseServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ServiceSettings(defaults: defaults)
    let model = DeviceSettingsController(file: DevicePreferencesFile(url: url), preferences: store)
    await model.importSettings(from: source)
    #expect(model.transferError != nil)
    #expect(model.error == nil)
    #expect(store.wheelMode == .ratchet)
    #expect(try String(contentsOf: url, encoding: .utf8) == original)
}
