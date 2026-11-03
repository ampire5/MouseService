import Foundation
import Testing
import PointerCore
@testable import MouseService

@Test func deviceFileEditsLatestContentsAndKeepsOriginalBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.yaml")
    let original = "# original comment\ndevices:\n  Mouse: {id: '1234:5678', speed: 0.1}\n"
    try original.write(to: url, atomically: true, encoding: .utf8)
    let file = DevicePreferencesFile(url: url)
    let mouse = DeviceIdentity(vendorID: 0x1234, productID: 0x5678, category: .mouse)
    _ = try await file.edit("speed", value: "0.2", device: mouse)
    #expect(try String(contentsOf: url.appendingPathExtension("before-ui"), encoding: .utf8) == original)
    try "devices:\n  Mouse: {id: '1234:5678', speed: 0.3, reverse-scroll: vertical}\n"
        .write(to: url, atomically: true, encoding: .utf8)
    let yaml = try await file.edit("acceleration", value: "0.4", device: mouse)
    let rules = try DeviceRules(yaml: yaml).resolve(mouse, app: nil)
    #expect(rules.pointer.speed == 0.3)
    #expect(rules.pointer.acceleration == 0.4)
    #expect(rules.scroll.reverseVertical)
    #expect(try String(contentsOf: url.appendingPathExtension("before-ui"), encoding: .utf8) == original)
}

@Test func failedImportLeavesConfigIntact() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.yaml")
    let original = "devices:\n"
    try original.write(to: url, atomically: true, encoding: .utf8)
    let file = DevicePreferencesFile(url: url)
    await #expect(throws: (any Error).self) { try await file.replace(with: "devices: [") }
    #expect(try String(contentsOf: url, encoding: .utf8) == original)
}

@Test func importBacksUpCurrentConfigurationAndPreferencesEveryTime() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.yaml")
    let original = "devices:\n  Mouse: {id: '1234:5678', speed: 0.2}\n"
    try original.write(to: url, atomically: true, encoding: .utf8)
    let source = directory.appendingPathComponent("new.json")
    try SettingsTransfer.encode(config: "devices:\n", preferences: ["wheel-mode": "ratchet"])
        .write(to: source)
    let file = DevicePreferencesFile(url: url)
    _ = try await file.importBundle(from: source, currentPreferences: ["wheel-mode": "free-spin"])
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("config.yaml.before-import-") }
    let backup = try #require(backups.first)
    let decoded = try SettingsTransfer.decode(Data(contentsOf: backup))
    #expect(decoded.config == original)
    #expect(decoded.preferences["wheel-mode"] == "free-spin")
    _ = try await file.importBundle(from: source, currentPreferences: ["wheel-mode": "ratchet"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("config.yaml.before-import-") }.count == 2)
}
