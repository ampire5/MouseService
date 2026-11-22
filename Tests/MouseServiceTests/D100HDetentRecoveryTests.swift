import Foundation
import Testing
@testable import MouseService

@Test func d100hRecoveryRestoresOnlyIfTheDialStillHasTheOverride() {
    let dial = UUID()
    let saved = D100HDetentRecovery(device: dial, value: 0xff)
    #expect(D100HDetentRecovery.action(device: dial, current: 0, muted: false, saved: saved) == .write(0xff))
    #expect(D100HDetentRecovery.action(device: dial, current: 0xff, muted: false, saved: saved) == .forget)
    #expect(D100HDetentRecovery.action(device: dial, current: 2, muted: false, saved: saved) == .forget)
    #expect(D100HDetentRecovery.action(device: UUID(), current: 0, muted: false, saved: saved) == .idle)
}

@Test func d100hRecoverySavesTheExactSettingBeforeTurningOffDetents() {
    let dial = UUID()
    let saved = D100HDetentRecovery(device: dial, value: 0xff)
    #expect(D100HDetentRecovery.action(device: dial, current: 0xff, muted: true, saved: nil) == .save(saved))
    #expect(D100HDetentRecovery.action(device: dial, current: 0xff, muted: true, saved: saved) == .write(0))
    #expect(D100HDetentRecovery.action(device: dial, current: 0, muted: true, saved: saved) == .idle)
    #expect(D100HDetentRecovery.action(device: dial, current: 0, muted: true, saved: nil) == .idle)
    #expect(D100HDetentRecovery.action(device: dial, current: 2, muted: true, saved: saved) ==
            .save(D100HDetentRecovery(device: dial, value: 2)))
}
