import CoreGraphics
import Foundation
import Testing
import XPC
@testable import MouseContract

private let device = DeviceInfo(present: true,
                                controls: [ControlInfo(cid: 0x53, divertable: true, watchable: true),
                                           ControlInfo(cid: 0xC3, divertable: true, watchable: false)],
                                thumbWheelStepsPerRevolution: 18, haptics: true)
private let wish = WheelWish(window: 7, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)], highResolution: true,
                             mode: .freeSpin)

@Test func roundTripsEveryMessage() {
    let clients: [ClientMessage] = [
        .hello(version: ContractVersion(major: 1, minor: 3), bundleID: "local.framescrub"),
        .want(Want(divert: [0xC3, 0x53], watch: [0x56], thumbWheel: true, wheel: [wish])),
        .want(Want(divert: [], watch: [], thumbWheel: false,
                   wheel: [WheelWish(window: 9, rects: nil, highResolution: nil, mode: nil)])),
        .want(.none),
        .play(pattern: 5, strength: 80),
        .play(pattern: 0, strength: nil),
    ]
    for m in clients { #expect(ClientMessage(xpc: m.xpc()) == m) }
    let services: [ServiceMessage] = [
        .welcome(serviceVersion: "0.2", device: device),
        .welcome(serviceVersion: "0.2", device: .absent),
        .refused(reason: "no"),
        .owner(true), .owner(false),
        .watching([0x53, 0x56]), .watching([]),
        .button(cid: 0xC3, pressed: true, time: 12.5),
        .thumbWheel(delta: -3, touching: true, phase: .changed, time: 1),
        .wheel(highResolution: true, mode: .ratchet, byButton: true),
        .wheel(highResolution: false, mode: nil, byButton: false),
        .device(DeviceInfo(present: true, controls: [], thumbWheelStepsPerRevolution: nil, haptics: false)),
    ]
    for m in services { #expect(ServiceMessage(xpc: m.xpc()) == m) }
}

@Test func ignoresUnknownFields() throws {
    let want = Want(divert: [0xC3], watch: [], thumbWheel: false, wheel: [wish])
    let object = ClientMessage.want(want).xpc()
    xpc_dictionary_set_int64(object, "future", 1)
    #expect(ClientMessage(xpc: object) == .want(want))
}

@Test func unknownTypeIsNil() {
    let teleport = xpc_dictionary_create_empty()
    xpc_dictionary_set_string(teleport, "type", "teleport")
    #expect(ClientMessage(xpc: teleport) == nil)
    #expect(ServiceMessage(xpc: teleport) == nil)
    #expect(ServiceMessage(xpc: xpc_dictionary_create_empty()) == nil)
}

@Test func missingRequiredFieldIsNil() {
    let button = xpc_dictionary_create_empty()
    xpc_dictionary_set_string(button, "type", "button")
    xpc_dictionary_set_bool(button, "pressed", true)
    xpc_dictionary_set_double(button, "time", 1)
    #expect(ServiceMessage(xpc: button) == nil)
}

@Test func versionOrderAndText() {
    let v10 = ContractVersion(major: 1, minor: 0), v11 = ContractVersion(major: 1, minor: 1)
    #expect(v10 < v11)
    #expect(v11 < ContractVersion(major: 2, minor: 0))
    #expect(ContractVersion("1.2") == ContractVersion(major: 1, minor: 2))
    #expect(ContractVersion("x") == nil)
    #expect(ContractVersion.current.text == "1.0")
}
