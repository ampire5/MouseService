import AppKit
import Foundation
import Testing
@testable import MouseCore
import XPC
@testable import MouseClient
import MouseContract
import MouseCore
@testable import MouseServiceKit

/// Waits until `condition` holds, letting the main queue run the XPC handlers; fails after 2 s.
@MainActor func eventually(_ what: String = "", _ condition: () -> Bool) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition() {
        if ProcessInfo.processInfo.systemUptime > deadline {
            Issue.record("timed out waiting \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A service on an anonymous listener with a fake mouse.
@MainActor final class Rig {
    let driver = FakeDriver()
    let service: Service
    let listener: Listener

    init() {
        service = Service(driver: driver, version: "test")
        listener = Listener(anonymous: service)
    }

    func shutDown() {
        listener.cancel()
        service.cancelAll()
    }
}

private let gesture: UInt16 = 0xC3

@MainActor @Suite(.serialized) struct ServiceTests {
    @Test func helloGetsWelcomeAndDevice() async {
        let rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        client.start()
        await eventually("welcome") { client.isAvailable }
        #expect(client.device == rig.driver.device)
        #expect(rig.service.clients.map(\.bundleID) == ["test.a"])
        rig.shutDown()
    }

    @Test func theGlobalModeIsOnTheMouseAtOnceAndAPressIsSaved() async {
        let rig = Rig()
        #expect(rig.driver.applied == [MouseState(mode: .ratchet)])
        var saved: [WheelMode] = []
        rig.service.onGlobalModeChange = { saved.append($0) }
        rig.driver.emit(.wheel(highResolution: false, mode: .freeSpin, byButton: true))
        #expect(saved == [.freeSpin])
        #expect(rig.driver.applied.last == MouseState(mode: .freeSpin))
        rig.service.setGlobalMode(.ratchet)
        #expect(rig.driver.applied.last == MouseState(mode: .ratchet))
        #expect(saved == [.freeSpin])   // the settings' own change is not saved again
        rig.shutDown()
    }

    @Test func refusesHigherMajor() async {
        let rig = Rig()
        let connection = xpc_connection_create_from_endpoint(rig.listener.endpoint)
        final class Heard: @unchecked Sendable {   // written and read on the main queue only
            var replies: [ServiceMessage] = []
            var invalid = false
        }
        let heard = Heard()
        xpc_connection_set_target_queue(connection, .main)
        xpc_connection_set_event_handler(connection) { object in
            if xpc_get_type(object) == XPC_TYPE_ERROR {
                heard.invalid = true
            } else if let m = ServiceMessage(xpc: object) {
                heard.replies.append(m)
            }
        }
        xpc_connection_resume(connection)
        xpc_connection_send_message(connection,
                                    ClientMessage.hello(version: ContractVersion(major: 2, minor: 0), bundleID: "x").xpc())
        await eventually("refusal") { heard.invalid }
        #expect(heard.replies == [.refused(reason: "contract 2.0 not supported, service speaks 1.0")])
        #expect(rig.service.clients.isEmpty)
        rig.shutDown()
    }

    @Test func ownerFlowEndToEnd() async {
        let rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        var owner: [Bool] = []
        var buttons: [(UInt16, Bool, Double)] = []
        client.onOwner = { owner.append($0) }
        client.onButton = { buttons.append(($0, $1, $2)) }
        client.start()
        client.want(Want(divert: [gesture]))
        await eventually("welcome") { client.isAvailable }
        rig.service.frontmost(pid: getpid())
        await eventually("owner") { client.isOwner }
        #expect(owner == [true])
        #expect(rig.driver.applied.last == MouseState(divert: [gesture], mode: .ratchet))
        rig.driver.emit(.button(cid: gesture, pressed: true))
        await eventually("button") { !buttons.isEmpty }
        #expect(buttons.first?.0 == gesture)
        #expect(buttons.first?.1 == true)
        #expect(abs((buttons.first?.2 ?? 0) - ProcessInfo.processInfo.systemUptime) < 0.1)
        rig.shutDown()
    }

    @Test func peerCancelReleases() async {
        let rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        client.start()
        client.want(Want(divert: [gesture]))
        rig.service.frontmost(pid: getpid())
        await eventually("applied") { rig.driver.applied.last == MouseState(divert: [gesture], mode: .ratchet) }
        client.stop()
        await eventually("released") { rig.driver.applied.last == MouseState(mode: .ratchet) }
        #expect(rig.service.clients.isEmpty)
        rig.shutDown()
    }

    @Test func clientRecoversAfterServiceRestart() async {
        var rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        var events: [String] = []
        client.onOwner = { events.append("owner \($0)") }
        client.onButton = { cid, pressed, _ in events.append("button \(cid) \(pressed)") }
        client.start()
        client.want(Want(divert: [gesture]))
        rig.service.frontmost(pid: getpid())
        await eventually("owner") { client.isOwner }
        rig.driver.emit(.button(cid: gesture, pressed: true))
        await eventually("press") { events.contains("button \(gesture) true") }

        let old = rig
        rig = Rig()   // the provider now gives the new service's endpoint
        rig.service.frontmost(pid: getpid())
        old.shutDown()
        await eventually("lost") { events.last == "owner false" }
        // The restarted service announces itself, as the app does once it listens.
        DistributedNotificationCenter.default().postNotificationName(MouseClient.serviceStarted, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        await eventually("new driver applied") { rig.driver.applied.last == MouseState(divert: [gesture], mode: .ratchet) }
        #expect(events == ["owner true", "button \(gesture) true", "button \(gesture) false", "owner false", "owner true"])
        rig.shutDown()
    }

    @Test func unavailableServiceRetriesOnActivation() async {
        var rig: Rig?
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig?.listener.endpoint })
        client.start()
        await eventually("settled") { !client.isConnecting }
        #expect(!client.isAvailable)
        rig = Rig()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await eventually("welcome") { client.isAvailable }
        rig?.shutDown()
    }

    @Test func serviceStartAnnouncementReconnects() async {
        // A service that went away (quit, or crashed and restarted by launchd) is not woken by its clients: the
        // started service says so, and they come back then.
        var rig: Rig?
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig?.listener.endpoint })
        client.start()
        await eventually("settled") { !client.isConnecting }
        #expect(!client.isAvailable)
        rig = Rig()
        DistributedNotificationCenter.default().postNotificationName(MouseClient.serviceStarted, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        await eventually("welcome") { client.isAvailable }
        rig?.shutDown()
    }

    @Test func playFromNonOwnerDropped() async {
        let rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        client.start()
        await eventually("welcome") { client.isAvailable }
        let handled = rig.service.messagesHandled
        client.play(pattern: 3)
        await eventually("first play handled") { rig.service.messagesHandled > handled }
        rig.service.frontmost(pid: getpid())
        await eventually("owner") { client.isOwner }
        client.play(pattern: 4, strength: 90)
        await eventually("play") { !rig.driver.played.isEmpty }
        #expect(rig.driver.played.map(\.pattern) == [4])
        #expect(rig.driver.played.first?.strength == 90)
        rig.shutDown()
    }
}
