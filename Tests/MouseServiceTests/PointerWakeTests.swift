import Foundation
import Testing
import PointerCore
@testable import MouseService

/// Only the IOKit boundary is replaced: rules, device bookkeeping and property writes run normally.
@MainActor private final class HIDService: PointerDeviceService {
    let id: UInt64
    let identity = DeviceIdentity(vendorID: 0x1234, productID: 0x5678, category: .mouse)
    let accelerationKey = "HIDMouseAcceleration"
    var acceptsWrites = true
    var properties: [String: CFTypeRef] = [
        "HIDPointerResolution": NSNumber(value: 400 * 65536),
        "HIDMouseAcceleration": NSNumber(value: 65536),
        "HIDUseLinearScalingMouseAcceleration": NSNumber(value: 1),
    ]
    var writes = 0

    init(_ id: UInt64) { self.id = id }
    func property(_ key: String) -> CFTypeRef? { properties[key] }
    func setProperty(_ key: String, _ value: CFTypeRef) -> Bool {
        writes += 1
        guard acceptsWrites else { return false }
        properties[key] = value
        return true
    }
}

@MainActor private func configuredPointer(_ services: @escaping () -> [any PointerDeviceService]?) throws -> PointerDevices {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
    try """
    devices:
      Mouse:
        id: 1234:5678
        speed: 0.5
        acceleration: 0.25
        reverse-scroll: vertical
    """.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let pointer = PointerDevices(configURL: url, services: services)
    pointer.reload()
    pointer.rescan()
    return pointer
}

@Test @MainActor func wakeRefreshesScrollSenderAndPointerService() throws {
    let before = HIDService(10)
    let after = HIDService(20)
    var current: [any PointerDeviceService] = [before]
    let pointer = try configuredPointer { current }
    #expect(pointer.scrollRules.rule(for: 10)?.reverseVertical == true)

    before.acceptsWrites = false
    current = [after]
    pointer.systemDidWake()

    #expect(pointer.scrollRules.rule(for: 10) == nil)
    #expect(pointer.scrollRules.rule(for: 20)?.decide(deltaX: 0, deltaY: 3, flags: [])
        == .negate(x: false, y: true))
    #expect((after.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384)
}

@Test @MainActor func wakeRefreshesHandleWithSameRegistryIDAndKeepsOriginalValues() throws {
    let before = HIDService(10)
    let after = HIDService(10)
    after.properties["HIDPointerResolution"] = NSNumber(value: 999)
    var current: [any PointerDeviceService] = [before]
    let pointer = try configuredPointer { current }
    before.acceptsWrites = false
    current = [after]
    pointer.systemDidWake()

    #expect((after.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384)
    pointer.restoreAll()
    #expect((after.properties["HIDPointerResolution"] as? NSNumber)?.intValue == 26214400)
}

@Test @MainActor func wakeReappliesAfterHIDFinishesResuming() async throws {
    let service = HIDService(10)
    let pointer = try configuredPointer { [service] }
    service.acceptsWrites = false
    pointer.systemDidWake()
    service.properties["HIDMouseAcceleration"] = NSNumber(value: 65536)
    service.acceptsWrites = true
    try await Task.sleep(for: .milliseconds(1200))
    #expect((service.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384)
    withExtendedLifetime(pointer) {}
}

@Test @MainActor func failedPropertyWriteIsRetriedOnNextScan() throws {
    let service = HIDService(10)
    service.acceptsWrites = false
    let pointer = try configuredPointer { [service] }
    service.acceptsWrites = true
    pointer.rescan()
    #expect((service.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384)
}

@Test @MainActor func hotplugDuringWakeKeepsTheForcedDelayedApply() async throws {
    let service = HIDService(10)
    let pointer = try configuredPointer { [service] }
    pointer.systemDidWake()
    pointer.deviceListChanged()
    // macOS can reset properties after the initial successful wake write.
    service.properties["HIDMouseAcceleration"] = NSNumber(value: 65536)
    try await Task.sleep(for: .milliseconds(1200))
    #expect((service.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384)
    withExtendedLifetime(pointer) {}
}

@Test @MainActor func delayedWakeScanFindsAServiceUnavailableAtWake() async throws {
    let before = HIDService(10)
    let after = HIDService(20)
    var current: [any PointerDeviceService]? = [before]
    let pointer = try configuredPointer { current }
    current = nil
    pointer.systemDidWake()
    current = [after]
    try await Task.sleep(for: .milliseconds(1200))
    #expect(pointer.scrollRules.rule(for: 10) == nil)
    #expect(pointer.scrollRules.rule(for: 20)?.reverseVertical == true)
    #expect((after.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384)
}

@Test @MainActor func emptyWakeEnumerationDoesNotReplaceOriginalProperties() async throws {
    let before = HIDService(10)
    let after = HIDService(10)
    var current: [any PointerDeviceService] = [before]
    let pointer = try configuredPointer { current }
    after.properties = before.properties
    current = []
    pointer.systemDidWake()
    #expect(pointer.scrollRules.isEmpty)
    current = [after]
    try await Task.sleep(for: .milliseconds(1200))
    #expect(pointer.scrollRules.rule(for: 10)?.reverseVertical == true)
    pointer.restoreAll()
    #expect((after.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 65536)
    #expect((after.properties["HIDPointerResolution"] as? NSNumber)?.intValue == 26214400)
}

@Test @MainActor func freshInstallCreatesConfigAndAppliesSavedOverrides() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("config.yaml")
    defer { try? FileManager.default.removeItem(at: directory) }
    let mouse = HIDService(100)
    let pointer = PointerDevices(configURL: url, services: { [mouse] })
    pointer.start()
    defer { pointer.restoreAll() }
    try #require(FileManager.default.fileExists(atPath: url.path))
    #expect((mouse.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 14745)
    try """
    devices:
      Mouse: { id: "1234:5678", speed: 0.5, acceleration: 0.25 }
    """.write(to: url, atomically: true, encoding: .utf8)
    for _ in 0..<100 {
        if (mouse.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect((mouse.properties["HIDMouseAcceleration"] as? NSNumber)?.intValue == 16384)
    #expect((mouse.properties["HIDPointerResolution"] as? NSNumber)?.intValue == 5073754)
}
