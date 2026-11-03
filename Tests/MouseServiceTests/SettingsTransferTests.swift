import Foundation
import Testing
@testable import MouseService

@Test @MainActor func settingsTransferRoundTripsConfigAndAllPreferences() throws {
    let name = "MouseServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ServiceSettings(defaults: defaults)
    try store.setValue("no", forKey: ServiceSettings.gesturesKey)
    try store.setValue("35", forKey: ServiceSettings.hapticStrengthKey)
    try store.setValue("default", forKey: ServiceSettings.panelForceKey)
    try store.setValue("free-spin", forKey: ServiceSettings.wheelModeKey)
    let yaml = "devices:\n  Example: { id: '1234:5678', speed: 0.3 }\n"
    let data = try SettingsTransfer.encode(config: yaml, preferences: store.exportedValues)
    let decoded = try SettingsTransfer.decode(data)
    #expect(decoded.config == yaml)
    #expect(decoded.preferences == store.exportedValues)
    try store.setValue("yes", forKey: ServiceSettings.gesturesKey)
    store.applyImportedValues(decoded.preferences)
    #expect(!store.gesturesEnabled)
    #expect(store.hapticStrength == 35)
    #expect(store.panelForce == .factoryDefault)
    #expect(store.wheelMode == .freeSpin)
}

@Test @MainActor func legacyGestureBoolRemainsReadable() throws {
    let name = "MouseServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ServiceSettings(defaults: defaults)
    #expect(store.gesturesEnabled)
    defaults.set(false, forKey: "gesturesOn")
    #expect(!store.gesturesEnabled)
    try store.setValue("yes", forKey: ServiceSettings.gesturesKey)
    #expect(store.gesturesEnabled)
    #expect(store.validate("sometimes", forKey: ServiceSettings.gesturesKey) != nil)
}

@Test func settingsTransferRejectsInvalidContentBeforeApplying() throws {
    let invalid = [
        #"{"version":2,"config":"devices:\n","preferences":{}}"#,
        #"{"version":1,"config":"devices: [","preferences":{}}"#,
        #"{"version":1,"config":"devices:\n","preferences":{"wheel-mode":"other"}}"#,
        #"{"version":1,"config":"devices:\n","preferences":{"unrelated":"secret"}}"#,
        #"{"version":1,"config":"devices:\n","preferences":{"haptic-strength":"101"}}"#,
    ]
    for json in invalid {
        #expect(throws: (any Error).self) { try SettingsTransfer.decode(Data(json.utf8)) }
    }
}
