import Foundation
import Testing
@testable import PointerCore

/// The user's LinearMouse configuration of 2026-10-27, as imported.
private func userRules() throws -> DeviceRules {
    let url = try #require(Bundle.module.url(forResource: "linearmouse", withExtension: "json", subdirectory: "Fixtures"))
    return try DeviceRules(json: LinearMouseImport.convert(Data(contentsOf: url)))
}

private let mxMaster4 = DeviceIdentity(vendorID: 0x46d, productID: 0xc548, productName: "USB Receiver", category: .mouse)
private let internalTrackpad = DeviceIdentity(vendorID: 0x5ac, productID: 0x342,
                                              productName: "Apple Internal Keyboard / Trackpad", category: .trackpad)

@Test func mxMasterGetsItsPointerAndWheel() throws {
    let r = try userRules().resolve(mxMaster4, app: "com.apple.finder")
    #expect(abs(try #require(r.pointer.speed) - 0.125) < 1e-9)
    #expect(abs(try #require(r.pointer.acceleration) - 0.225) < 1e-9)
    #expect(r.pointer.disableAcceleration == false)
    #expect(r.scroll == ScrollRule(reverseVertical: true, reverseHorizontal: false, dropHorizontal: [.command, .control]))
}

@Test func appSchemeOverridesPointerOnly() throws {
    let r = try userRules().resolve(mxMaster4, app: "com.djhan.EdgeView-3")
    #expect(abs(try #require(r.pointer.speed) - 0.066) < 1e-9)   // JSON numbers come back within rounding
    #expect(abs(try #require(r.pointer.acceleration) - 1.5172) < 1e-9)
    #expect(r.scroll.reverseVertical)   // the base scheme's, kept
}

@Test func trackpadIsNotReversed() throws {
    let r = try userRules().resolve(internalTrackpad, app: nil)
    #expect(!r.scroll.reverseVertical)
    #expect(abs(try #require(r.pointer.speed) - 0.0689655172413792768) < 1e-9)
}

@Test func otherCategorySameIDsDoesNotMatch() throws {
    var device = mxMaster4
    device.category = .trackpad
    #expect(try userRules().resolve(device, app: nil) == ResolvedRules())
}

@Test func unknownDeviceGetsNothing() throws {
    let device = DeviceIdentity(vendorID: 0x1915, productID: 0xeeee, productName: "TourBox Lite BT", category: .mouse)
    #expect(try userRules().resolve(device, app: nil) == ResolvedRules())
}

@Test func importKeepsOnlyActedOnFields() throws {
    let rules = try userRules()
    #expect(rules.ignoredFields.isEmpty)
    #expect(rules.dependsOnApp)
    let url = try #require(Bundle.module.url(forResource: "linearmouse", withExtension: "json", subdirectory: "Fixtures"))
    let raw = try DeviceRules(json: Data(contentsOf: url))
    #expect(raw.ignoredFields.contains { $0.hasSuffix(".logitech") })
    #expect(raw.ignoredFields.contains { $0.hasSuffix(".scrolling.smoothed") })
}

@Test func laterReverseFieldOverridesPerAxis() throws {
    let json = """
    {"schemes": [
      {"if": {"device": {"vendorID": "0x46d", "productID": "0xc548"}}, "scrolling": {"reverse": true}},
      {"if": {"app": "x"}, "scrolling": {"reverse": {"vertical": false}}}
    ]}
    """
    let rules = try DeviceRules(json: Data(json.utf8))
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
    let rules = try DeviceRules(json: Data(json.utf8))
    #expect(rules.resolve(mxMaster4, app: "x").scroll.dropHorizontal == [])
    #expect(rules.resolve(mxMaster4, app: "y").scroll.dropHorizontal == [.command])
}

@Test func unsupportedConditionNeverMatches() throws {
    let json = #"{"schemes": [{"if": {"display": "DELL"}, "scrolling": {"reverse": true}}]}"#
    let rules = try DeviceRules(json: Data(json.utf8))
    #expect(rules.resolve(mxMaster4, app: nil) == ResolvedRules())
    #expect(rules.ignoredFields == ["schemes[0].if.display"])
}

@Test func conditionArrayMatchesAny() throws {
    let json = #"{"schemes": [{"if": [{"app": "a"}, {"app": "b"}], "pointer": {"speed": 0.5}}]}"#
    let rules = try DeviceRules(json: Data(json.utf8))
    #expect(rules.resolve(mxMaster4, app: "b").pointer.speed == 0.5)
    #expect(rules.resolve(mxMaster4, app: "c").pointer.speed == nil)
}

@Test func badValuesAreErrors() {
    #expect(throws: DeviceRules.RulesError.bad("schemes[0].pointer.speed")) {
        try DeviceRules(json: Data(#"{"schemes": [{"pointer": {"speed": "fast"}}]}"#.utf8))
    }
    #expect(throws: DeviceRules.RulesError.noSchemes) { try DeviceRules(json: Data("{}".utf8)) }
}

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
