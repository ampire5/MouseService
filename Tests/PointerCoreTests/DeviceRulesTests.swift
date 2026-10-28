import Foundation
import Testing
@testable import PointerCore

@Test func speedMapsToMeasuredResolution() {
    // Measured 2026-10-27 on the MX Master 4 with LinearMouse's speed 0.125: HIDPointerResolution 17003935 / 65536.
    #expect(abs(PointerMath.resolution(speed: 0.125) - 17003935.0 / 65536) < 0.01)
    #expect(abs(PointerMath.speed(resolution: PointerMath.resolution(speed: 0.4)) - 0.4) < 1e-9)
    #expect(PointerMath.resolution(speed: 0) == 1200)
    #expect(abs(PointerMath.resolution(speed: 1) - 40) < 1e-9)
}

@Test func scrollDecisions() {
    let rule = ScrollRule(reverseVertical: true, dropHorizontal: [.command, .control])
    #expect(rule.decide(deltaX: 0, deltaY: 3, flags: []) == .negate(x: false, y: true))
    #expect(rule.decide(deltaX: 2, deltaY: 0, flags: [.command]) == .drop)
    #expect(rule.decide(deltaX: 2, deltaY: 0, flags: [.control, .shift]) == .drop)
    #expect(rule.decide(deltaX: 0, deltaY: 3, flags: [.command]) == .negate(x: false, y: true))   // vertical: not dropped
    #expect(rule.decide(deltaX: 2, deltaY: 0, flags: [.option]) == .negate(x: false, y: true))
    #expect(ScrollRule.none.decide(deltaX: 1, deltaY: 1, flags: [.command]) == .pass)
}

// MARK: config.yaml (docs/superpowers/specs/2026-10-28-yaml-config-design.md)

private let example = """
devices:
  MX Master 4:
    id: 46d:c548
    speed: 0.125
    acceleration: 0.225
    disable-acceleration: false
    reverse-scroll: vertical
    ignore-horizontal-scroll-with: [command, control]
    apps:
      com.example.App:
        speed: 0.066
      com.example.Reversed: { reverse-scroll: none }
  Trackpad:
    id: 5ac:342
    speed: 0.07
  Magic Trackpad:
    id: 4c:265
    serial: "AA:BB:CC:DD:EE:FF"
    acceleration: 1.28
"""

@Test func yamlExampleResolves() throws {
    let rules = try DeviceRules(yaml: example)
    #expect(rules.count == 3)
    #expect(rules.dependsOnApp)
    let r = rules.resolve(mxMaster4, app: "com.apple.finder")
    #expect(r.pointer == PointerSettings(speed: 0.125, acceleration: 0.225, disableAcceleration: false))
    #expect(r.scroll == ScrollRule(reverseVertical: true, dropHorizontal: [.command, .control]))
    #expect(rules.resolve(mxMaster4, app: "com.example.App").pointer.speed == 0.066)
    #expect(rules.resolve(mxMaster4, app: "com.example.App").pointer.acceleration == 0.225)   // not named: kept
    #expect(rules.resolve(mxMaster4, app: "com.example.Reversed").scroll
        == ScrollRule(reverseVertical: false, dropHorizontal: [.command, .control]))
}

@Test func serialWithColonsAndOnlyThatUnit() throws {
    let rules = try DeviceRules(yaml: example)
    let mine = DeviceIdentity(vendorID: 0x4c, productID: 0x265, serialNumber: "AA:BB:CC:DD:EE:FF", category: .trackpad)
    var other = mine
    other.serialNumber = "00:00:00:00:00:00"
    #expect(rules.resolve(mine, app: nil).pointer.acceleration == 1.28)
    #expect(rules.resolve(other, app: nil) == ResolvedRules())
}

@Test func nameAndCategoryAreNotMatched() throws {
    let rules = try DeviceRules(yaml: example)
    let renamed = DeviceIdentity(vendorID: 0x46d, productID: 0xc548, productName: "Something else", category: .trackpad)
    #expect(rules.resolve(renamed, app: nil).pointer.speed == 0.125)
}

@Test func idsYamlWouldReadAsNumbers() throws {
    let rules = try DeviceRules(yaml: "devices:\n  A:\n    id: 1234:5678\n    speed: 0.5\n  B:\n    id: 0046:0265\n    speed: 0.25\n")
    #expect(rules.resolve(DeviceIdentity(vendorID: 0x1234, productID: 0x5678, category: .mouse), app: nil).pointer.speed == 0.5)
    #expect(rules.resolve(DeviceIdentity(vendorID: 0x46, productID: 0x265, category: .mouse), app: nil).pointer.speed == 0.25)
}

@Test func matchingEntriesApplyInFileOrder() throws {
    let rules = try DeviceRules(yaml: """
    devices:
      Any of them:
        id: 46d:c548
        speed: 0.1
        acceleration: 0.2
      This unit:
        id: 46d:c548
        serial: "S1"
        speed: 0.9
    """)
    var unit = mxMaster4
    unit.serialNumber = "S1"
    #expect(rules.resolve(unit, app: nil).pointer == PointerSettings(speed: 0.9, acceleration: 0.2))
    #expect(rules.resolve(mxMaster4, app: nil).pointer == PointerSettings(speed: 0.1, acceleration: 0.2))
}

@Test func reverseAndIgnoreListsReplaceAsAWhole() throws {
    let rules = try DeviceRules(yaml: """
    devices:
      M:
        id: 46d:c548
        reverse-scroll: both
        ignore-vertical-scroll-with: [shift, option]
        apps:
          x: { reverse-scroll: horizontal, ignore-vertical-scroll-with: [] }
    """)
    #expect(rules.resolve(mxMaster4, app: nil).scroll
        == ScrollRule(reverseVertical: true, reverseHorizontal: true, dropVertical: [.shift, .option]))
    #expect(rules.resolve(mxMaster4, app: "x").scroll == ScrollRule(reverseVertical: false, reverseHorizontal: true))
}

@Test func emptyFileIsNoRules() throws {
    #expect(try DeviceRules(yaml: "").count == 0)
    #expect(try DeviceRules(yaml: "# only a comment\n").count == 0)
}

@Test func badFilesNameThePath() {
    #expect(throws: DeviceRules.RulesError.bad("devices.A.speed")) {
        try DeviceRules(yaml: "devices:\n  A:\n    id: 46d:c548\n    speed: fast\n")
    }
    #expect(throws: DeviceRules.RulesError.bad("devices.A.id")) {
        try DeviceRules(yaml: "devices:\n  A:\n    id: 46d\n")
    }
    #expect(throws: DeviceRules.RulesError.bad("devices.A.id")) {
        try DeviceRules(yaml: "devices:\n  A:\n    speed: 0.5\n")
    }
    #expect(throws: DeviceRules.RulesError.bad("devices.A.reverse-scroll")) {
        try DeviceRules(yaml: "devices:\n  A:\n    id: 46d:c548\n    reverse-scroll: sideways\n")
    }
    #expect(throws: DeviceRules.RulesError.bad("devices.A.ignore-horizontal-scroll-with")) {
        try DeviceRules(yaml: "devices:\n  A:\n    id: 46d:c548\n    ignore-horizontal-scroll-with: [meta]\n")
    }
    #expect(throws: DeviceRules.RulesError.bad("devices.A.apps.x.speed")) {
        try DeviceRules(yaml: "devices:\n  A:\n    id: 46d:c548\n    apps:\n      x: { speed: [1] }\n")
    }
    #expect {
        try DeviceRules(yaml: "devices: [unclosed")
    } throws: { error in
        if case DeviceRules.RulesError.syntax = error { true } else { false }
    }
}

@Test func numbersAreClamped() throws {
    let rules = try DeviceRules(yaml: "devices:\n  A:\n    id: 46d:c548\n    speed: 3\n    acceleration: -1\n")
    #expect(rules.resolve(mxMaster4, app: nil).pointer == PointerSettings(speed: 1, acceleration: 0))
}

@Test func unknownKeysAreIgnoredAndCounted() throws {
    let rules = try DeviceRules(yaml: "devices:\n  A:\n    id: 46d:c548\n    color: red\n    apps:\n      x: { size: 1 }\nextra: 1\n")
    #expect(rules.ignoredFields == ["devices.A.color", "devices.A.apps.x.size", "extra"])
}
