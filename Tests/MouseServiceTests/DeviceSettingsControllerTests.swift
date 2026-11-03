import Foundation
import Testing
import PointerCore
@testable import MouseService

@Test @MainActor func deviceSelectionKeepsTrackpadsAndMiceIndependent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = "MouseServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let file = DevicePreferencesFile(url: directory.appendingPathComponent("config.yaml"))
    let store = ServiceSettings(defaults: defaults)
    let model = DeviceSettingsController(file: file, preferences: store)
    let mouse = DeviceIdentity(vendorID: 0x1234, productID: 1, productName: "Mouse", category: .mouse)
    let trackpad = DeviceIdentity(vendorID: 0x1234, productID: 2, productName: "Trackpad", category: .trackpad)
    model.connectedDevices = { [trackpad, mouse] }
    await model.refresh()
    #expect(model.selectedDevice == mouse)
    #expect(model.speed == "0.125")
    await model.set("reverse-scroll", value: "vertical")
    await model.select(SettingsDevice.key(trackpad))
    #expect(model.speed == "")
    #expect(model.reverse == "none")
    await model.set("speed", value: "0.7", for: SettingsDevice.key(mouse))
    #expect(model.speed == "")  // stale mouse editor must not write to the newly selected trackpad
    let yaml = try await file.load()
    #expect(try DeviceRules(yaml: yaml).resolve(trackpad, app: nil).pointer.speed == nil)
    await model.select(SettingsDevice.key(mouse))
    #expect(model.reverse == "vertical")
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
    #expect(model.error != nil)
    #expect(store.wheelMode == .ratchet)
    #expect(try String(contentsOf: url, encoding: .utf8) == original)
}
