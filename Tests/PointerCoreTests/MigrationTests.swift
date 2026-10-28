import Foundation
import Testing
@testable import PointerCore

/// Every device in the old rules × no app and every app named anywhere: the migrated file resolves as the old rules.
private func expectEquivalent(_ legacy: LegacyDeviceRules, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let yaml = DevicesMigration.yaml(from: legacy)
    let rules = try DeviceRules(yaml: yaml)
    let apps: [String?] = [nil] + legacy.apps
    #expect(!legacy.identities.isEmpty, sourceLocation: sourceLocation)
    for device in legacy.identities {
        for app in apps {
            #expect(rules.resolve(device, app: app) == legacy.resolve(device, app: app),
                    "\(device.productName ?? "?") \(app ?? "-")", sourceLocation: sourceLocation)
        }
    }
    // A device that is not in the file gets nothing in either.
    let stranger = DeviceIdentity(vendorID: 0x1915, productID: 0xeeee, category: .mouse)
    #expect(rules.resolve(stranger, app: nil) == ResolvedRules(), sourceLocation: sourceLocation)
}

@Test func migrationOfTheFixtureIsExact() throws {
    try expectEquivalent(legacyUserRules())
}

@Test func migrationOfTheRealFileIsExact() throws {
    guard let path = ProcessInfo.processInfo.environment["MOUSESERVICE_REAL_CONFIG"] else { return }
    try expectEquivalent(LegacyDeviceRules(json: Data(contentsOf: URL(fileURLWithPath: path))))
}

@Test func migrationKeepsSerialsAndPartialAppOverrides() throws {
    let json = """
    {"schemes": [
      {"if": {"device": {"vendorID": "0x4c", "productID": "0x265", "serialNumber": "AA:BB:CC:DD:EE:FF"}},
       "scrolling": {"reverse": true}, "pointer": {"speed": 0.3}},
      {"if": {"app": "x", "device": {"vendorID": "0x4c", "productID": "0x265", "serialNumber": "AA:BB:CC:DD:EE:FF"}},
       "scrolling": {"reverse": {"vertical": false}}}
    ]}
    """
    let legacy = try LegacyDeviceRules(json: Data(json.utf8))
    let yaml = DevicesMigration.yaml(from: legacy)
    #expect(yaml.contains("AA:BB:CC:DD:EE:FF"))
    try expectEquivalent(legacy)
}

@Test func migrationListsWhatItCannotCarry() throws {
    let json = """
    {"schemes": [
      {"if": {"app": "everywhere"}, "pointer": {"speed": 0.5}},
      {"if": {"display": "DELL"}, "scrolling": {"reverse": true}},
      {"if": {"device": {"vendorID": "0x46d", "productID": "0xc548", "productName": "Mouse: \\"one\\""}}, "pointer": {"speed": 0.2}}
    ]}
    """
    let yaml = DevicesMigration.yaml(from: try LegacyDeviceRules(json: Data(json.utf8)))
    #expect(yaml.hasPrefix("#"))
    #expect(yaml.contains("everywhere"))
    #expect(yaml.contains("display"))
    let rules = try DeviceRules(yaml: yaml)   // the quoted name came through
    #expect(rules.count == 1)
}

@Test func twoEntriesWithTheSameNameStayTwoEntries() throws {
    let json = """
    {"schemes": [
      {"if": {"device": {"vendorID": "0x46d", "productID": "0x1", "productName": "Same"}}, "pointer": {"speed": 0.1}},
      {"if": {"device": {"vendorID": "0x46d", "productID": "0x2", "productName": "Same"}}, "pointer": {"speed": 0.2}}
    ]}
    """
    try expectEquivalent(LegacyDeviceRules(json: Data(json.utf8)))
}
