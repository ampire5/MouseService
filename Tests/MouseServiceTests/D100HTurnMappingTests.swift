import Foundation
import Testing
@testable import MouseService

@Test func d100hAssignmentPacketsMatchHardwareTrial() {
    let tail = Data([0x38, 0x90, 0xc4, 0x99, 0xa3, 0x60, 0xaa, 0xad, 0, 0, 0, 0])
    #expect(D100HProtocol.readAssignment(.left) == Data([0x1e, 0x73, 0xb3, 0x1d, 0xc1, 0x5c, 0x07, 0x57]) + tail)
    #expect(D100HProtocol.assignmentReply(Data([0xeb, 0xe9, 0x65, 0x91, 0xe5, 0xdd, 0x38, 0x5b]) + tail)
            == .write(.left, 0x15))
    #expect(D100HProtocol.assignmentReply(Data([0x72, 0xd3, 0x71, 0x61, 0xdd, 0x31, 0xbe, 0xfd]) + tail)
            == .read(.left, 0x15))
    #expect(D100HProtocol.assignmentReply(Data([0x09, 0x1d]) + tail) == nil)
}

@Test func d100hPairIsJournaledBeforeWritingAndRestoresPartialChanges() {
    let device = UUID()
    let originals = D100HTurnMapping.Assignments(left: 0x0d, right: 0x0c)
    let saved = D100HTurnMapping(device: device, original: originals)
    #expect(D100HTurnMapping.action(device: device, current: originals, enabled: true, saved: nil) == .save(saved))
    #expect(D100HTurnMapping.action(device: device, current: originals, enabled: true, saved: saved) == .write(.left, 0x15))
    #expect(D100HTurnMapping.action(device: device, current: .init(left: 0x15, right: 0x0c), enabled: false, saved: saved)
            == .write(.left, 0x0d))
    #expect(D100HTurnMapping.action(device: device, current: .init(left: 0x07, right: 0x60), enabled: false, saved: saved)
            == .write(.right, 0x0c))
    #expect(D100HTurnMapping.action(device: device, current: .init(left: 0x07, right: 0x0c), enabled: false, saved: saved)
            == .forget)
    #expect(D100HTurnMapping.action(device: UUID(), current: originals, enabled: true, saved: saved) == .conflict)
    #expect(D100HTurnMapping.action(device: device, current: .init(left: 0x15, right: 0x60), enabled: true, saved: nil)
            == .ready)
}
