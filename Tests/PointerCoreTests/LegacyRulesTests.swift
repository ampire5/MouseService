import Foundation
import Testing
@testable import PointerCore

/// The user's LinearMouse configuration of 2026-10-27 (scrubbed), read by the legacy parser.
func legacyUserRules() throws -> LegacyDeviceRules {
    let url = try #require(Bundle.module.url(forResource: "linearmouse", withExtension: "json", subdirectory: "Fixtures"))
    return try LegacyDeviceRules(json: Data(contentsOf: url))
}

let mxMaster4 = DeviceIdentity(vendorID: 0x46d, productID: 0xc548, productName: "USB Receiver", category: .mouse)
let internalTrackpad = DeviceIdentity(vendorID: 0x5ac, productID: 0x342,
                                      productName: "Apple Internal Keyboard / Trackpad", category: .trackpad)

@Test func mxMasterGetsItsPointerAndWheel() throws {
    let r = try legacyUserRules().resolve(mxMaster4, app: "com.apple.finder")
    #expect(abs(try #require(r.pointer.speed) - 0.125) < 1e-9)
    #expect(abs(try #require(r.pointer.acceleration) - 0.225) < 1e-9)
    #expect(r.pointer.disableAcceleration == false)
    #expect(r.scroll == ScrollRule(reverseVertical: true, reverseHorizontal: false, dropHorizontal: [.command, .control]))
}

@Test func appSchemeOverridesPointerOnly() throws {
    let r = try legacyUserRules().resolve(mxMaster4, app: "com.djhan.EdgeView-3")
    #expect(abs(try #require(r.pointer.speed) - 0.066) < 1e-9)   // JSON numbers come back within rounding
    #expect(abs(try #require(r.pointer.acceleration) - 1.5172) < 1e-9)
    #expect(r.scroll.reverseVertical)   // the base scheme's, kept
}

@Test func trackpadIsNotReversed() throws {
    let r = try legacyUserRules().resolve(internalTrackpad, app: nil)
    #expect(!r.scroll.reverseVertical)
    #expect(abs(try #require(r.pointer.speed) - 0.0689655172413792768) < 1e-9)
}

@Test func otherCategorySameIDsDoesNotMatch() throws {
    var device = mxMaster4
    device.category = .trackpad
    #expect(try legacyUserRules().resolve(device, app: nil) == ResolvedRules())
}

@Test func unknownDeviceGetsNothing() throws {
    let device = DeviceIdentity(vendorID: 0x1915, productID: 0xeeee, productName: "TourBox Lite BT", category: .mouse)
    #expect(try legacyUserRules().resolve(device, app: nil) == ResolvedRules())
}

@Test func fieldsNotActedOnAreIgnoredAndCounted() throws {
    let rules = try legacyUserRules()
    #expect(rules.dependsOnApp)
    #expect(rules.ignoredFields.contains { $0.hasSuffix(".logitech") })
    #expect(rules.ignoredFields.contains { $0.hasSuffix(".scrolling.smoothed") })
}

@Test func laterReverseFieldOverridesPerAxis() throws {
    let json = """
    {"schemes": [
      {"if": {"device": {"vendorID": "0x46d", "productID": "0xc548"}}, "scrolling": {"reverse": true}},
      {"if": {"app": "x"}, "scrolling": {"reverse": {"vertical": false}}}
    ]}
    """
    let rules = try LegacyDeviceRules(json: Data(json.utf8))
    #expect(rules.resolve(mxMaster4, app: "x").scroll == ScrollRule(reverseVertical: false, reverseHorizontal: true))
    #expect(rules.resolve(mxMaster4, app: "y").scroll == ScrollRule(reverseVertical: true, reverseHorizontal: true))
}

@Test func laterModifierActionClearsDrop() throws {
    let json = """
    {"schemes": [
      {"scrolling": {"modifiers": {"horizontal": {"command": {"type": "preventDefault"}}}}},
      {"if": {"app": "x"}, "scrolling": {"modifiers": {"horizontal": {"command": {"type": "auto"}}}}}
    ]}
    """
    let rules = try LegacyDeviceRules(json: Data(json.utf8))
    #expect(rules.resolve(mxMaster4, app: "x").scroll.dropHorizontal == [])
    #expect(rules.resolve(mxMaster4, app: "y").scroll.dropHorizontal == [.command])
}

@Test func unsupportedConditionNeverMatches() throws {
    let json = #"{"schemes": [{"if": {"display": "DELL"}, "scrolling": {"reverse": true}}]}"#
    let rules = try LegacyDeviceRules(json: Data(json.utf8))
    #expect(rules.resolve(mxMaster4, app: nil) == ResolvedRules())
    #expect(rules.ignoredFields == ["schemes[0].if.display"])
}

@Test func conditionArrayMatchesAny() throws {
    let json = #"{"schemes": [{"if": [{"app": "a"}, {"app": "b"}], "pointer": {"speed": 0.5}}]}"#
    let rules = try LegacyDeviceRules(json: Data(json.utf8))
    #expect(rules.resolve(mxMaster4, app: "b").pointer.speed == 0.5)
    #expect(rules.resolve(mxMaster4, app: "c").pointer.speed == nil)
}

@Test func badValuesAreErrors() {
    #expect(throws: LegacyDeviceRules.RulesError.bad("schemes[0].pointer.speed")) {
        try LegacyDeviceRules(json: Data(#"{"schemes": [{"pointer": {"speed": "fast"}}]}"#.utf8))
    }
    #expect(throws: LegacyDeviceRules.RulesError.noSchemes) { try LegacyDeviceRules(json: Data("{}".utf8)) }
}

