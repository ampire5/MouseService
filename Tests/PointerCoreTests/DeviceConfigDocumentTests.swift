import Testing
import Yams
@testable import PointerCore

private let documentMouse = DeviceIdentity(vendorID: 0x46d, productID: 0xc548, productName: "Mouse", category: .mouse)

@Test func documentCreatesAndReadsSettings() throws {
    var yaml = ""
    for (field, value) in [("speed", "0.7"), ("acceleration", "2.5"), ("disable-acceleration", "yes"),
                           ("reverse-scroll", "both"), ("ignore-vertical-scroll-with", "shift,command"),
                           ("ignore-horizontal-scroll-with", "")] {
        yaml = try DeviceConfigDocument.setting(field, to: value, for: documentMouse, in: yaml)
    }
    #expect(try DeviceConfigDocument.devices(in: yaml) == [documentMouse])
    #expect(try DeviceConfigDocument.setting("speed", for: documentMouse, in: yaml) == "0.7")
    #expect(try DeviceConfigDocument.setting("disable-acceleration", for: documentMouse, in: yaml) == "yes")
    #expect(try DeviceConfigDocument.setting("ignore-vertical-scroll-with", for: documentMouse, in: yaml) == "command,shift")
    #expect(try DeviceConfigDocument.setting("ignore-horizontal-scroll-with", for: documentMouse, in: yaml) == "")
    #expect(try DeviceConfigDocument.setting("speed", for: documentMouse, in: "") == "0.125")
}

@Test func documentPreservesFlowUnknownAndAppFields() throws {
    let original = """
    future: {enabled: true, values: [a, b]}
    devices:
      Mouse: {id: '46d:c548', speed: 0.1, custom: {x: [1, 2]}, apps: {editor: {speed: 0.9, future: keep}}}
    """
    let edited = try DeviceConfigDocument.setting("speed", to: "0.5", for: documentMouse, in: original)
    let before = try #require(try compose(yaml: original))
    let after = try #require(try compose(yaml: edited))
    #expect(before.mapping?["future"] == after.mapping?["future"])
    #expect(before.mapping?["devices"]?.mapping?["Mouse"]?.mapping?["custom"] == after.mapping?["devices"]?.mapping?["Mouse"]?.mapping?["custom"])
    #expect(before.mapping?["devices"]?.mapping?["Mouse"]?.mapping?["apps"] == after.mapping?["devices"]?.mapping?["Mouse"]?.mapping?["apps"])
    #expect(try DeviceRules(yaml: edited).resolve(documentMouse, app: "editor").pointer.speed == 0.9)
}

@Test func documentSeparatesSerialsAndDuplicateNames() throws {
    let original = "devices: {Mouse: {id: '46d:c548', speed: 0.1}}"
    var unit = documentMouse
    unit.serialNumber = "S:1"
    let edited = try DeviceConfigDocument.setting("speed", to: "0.6", for: unit, in: original)
    let devices = try DeviceConfigDocument.devices(in: edited)
    #expect(devices.count == 2)
    #expect(devices.last?.serialNumber == "S:1")
    #expect(try DeviceRules(yaml: edited).resolve(documentMouse, app: nil).pointer.speed == 0.1)
    #expect(try DeviceRules(yaml: edited).resolve(unit, app: nil).pointer.speed == 0.6)
    let twice = try DeviceConfigDocument.setting("speed", to: "0.8", for: unit, in: edited)
    #expect(try DeviceConfigDocument.devices(in: twice).count == 2)
}

@Test func documentOverlapChangesBaseAndKeepsAppPrecedence() throws {
    var unit = documentMouse
    unit.serialNumber = "one"
    let original = """
    devices:
      Exact: {id: '46d:c548', serial: one, speed: 0.1, apps: {editor: {acceleration: 9}}}
      Generic: {id: '46d:c548', speed: 0.3, apps: {editor: {speed: 0.9, custom: preserve}}}
    """
    let edited = try DeviceConfigDocument.setting("speed", to: "0.6", for: unit, in: original)
    let rules = try DeviceRules(yaml: edited)
    #expect(rules.resolve(unit, app: nil).pointer.speed == 0.6)
    #expect(rules.resolve(unit, app: "editor").pointer.speed == 0.9)
    #expect(rules.resolve(unit, app: "editor").pointer.acceleration == 9)
    #expect(rules.resolve(documentMouse, app: nil).pointer.speed == 0.3)
    let before = try #require(try compose(yaml: original))
    let after = try #require(try compose(yaml: edited))
    for key in ["Exact", "Generic"] {
        #expect(before.mapping?["devices"]?.mapping?[key]?.mapping?["apps"] == after.mapping?["devices"]?.mapping?[key]?.mapping?["apps"])
    }
}

@Test func documentRejectsInvalidValuesAndMalformedInput() throws {
    for (field, value) in [("speed", "1.1"), ("speed", "nan"), ("speed", "-0.1"),
                           ("acceleration", "41"), ("acceleration", "inf"), ("disable-acceleration", "true"),
                           ("reverse-scroll", "up"), ("ignore-vertical-scroll-with", "meta"), ("unknown", "x")] {
        #expect(throws: (any Error).self) { try DeviceConfigDocument.setting(field, to: value, for: documentMouse, in: "") }
    }
    for yaml in ["devices: [broken", "devices: {Mouse: {speed: 0.2}}", "- 1", "devices: []"] {
        #expect(throws: (any Error).self) { try DeviceConfigDocument.setting("speed", to: "0.5", for: documentMouse, in: yaml) }
    }
    #expect(try DeviceConfigDocument.devices(in: "# empty").isEmpty)
    let trackpad = try DeviceConfigDocument.devices(in: "devices: {'Magic Trackpad': {id: '05ac:0342', serial: '01:02'}}")
    #expect(trackpad.first?.category == .trackpad)
    #expect(trackpad.first?.vendorID == 0x5ac)
    #expect(trackpad.first?.serialNumber == "01:02")
}

@Test func documentRejectsAmbiguousDuplicateDeviceSections() {
    let yaml = """
    devices: {First: {id: '46d:c548', speed: 0.1}}
    devices: {Second: {id: '46d:c548', speed: 0.2}}
    """
    #expect(throws: (any Error).self) { try DeviceConfigDocument.devices(in: yaml) }
    #expect(throws: (any Error).self) { try DeviceConfigDocument.setting("speed", to: "0.4", for: documentMouse, in: yaml) }
}

@Test func documentKeepsExplicitAppValuesEqualToOldDefault() throws {
    var unit = documentMouse
    unit.serialNumber = "one"
    let original = """
    devices:
      Exact: {id: '46d:c548', serial: one, speed: 0.1}
      Generic: {id: '46d:c548', speed: 0.3, apps: {editor: {speed: 0.3}}}
    """
    let edited = try DeviceConfigDocument.setting("speed", to: "0.6", for: unit, in: original)
    #expect(try DeviceRules(yaml: edited).resolve(unit, app: "editor").pointer.speed == 0.3)
    #expect(try DeviceRules(yaml: edited).resolve(unit, app: nil).pointer.speed == 0.6)
}
