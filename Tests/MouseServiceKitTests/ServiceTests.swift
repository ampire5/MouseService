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
    @Test func dialReaderRejectsUnprivilegedPeers() async {
        guard geteuid() != 0 else { return }
        let rig = Rig()
        defer { rig.shutDown() }
        let connection = xpc_connection_create_from_endpoint(rig.listener.endpoint)
        xpc_connection_set_target_queue(connection, .main)
        var refused = false
        xpc_connection_set_event_handler(connection) { object in
            if case .refused = ServiceMessage(xpc: object) {
                MainActor.assumeIsolated { refused = true }
            }
        }
        xpc_connection_resume(connection)
        defer { xpc_connection_cancel(connection) }
        xpc_connection_send_message(connection, D100HHelperMessage.hello.xpc())
        await eventually("reject the unprivileged reader") { refused }
    }

    @Test func dialEventsFollowTheSubscribedForegroundClient() async {
        let rig = Rig()
        defer { rig.shutDown() }
        let first = MouseClient(bundleID: "test.player", endpointProvider: { rig.listener.endpoint })
        let second = MouseClient(bundleID: "test.observer", endpointProvider: { rig.listener.endpoint })
        var firstEvents: [D100HInput] = []
        var secondEvents: [D100HInput] = []
        first.onD100HInput = { event, _ in firstEvents.append(event) }
        second.onD100HInput = { event, _ in secondEvents.append(event) }
        first.setD100HInputRequested(true)
        first.start()
        second.start()
        await eventually("input request") { rig.service.messagesHandled == 3 }

        let press = D100HInput.button(.topLeft, pressed: true)
        rig.service.d100hInput(press, time: 1)
        rig.service.frontmost(pid: getpid())
        rig.service.d100hInput(press, time: 2)
        rig.service.frontmost(pid: nil)
        rig.service.d100hInput(.button(.topLeft, pressed: false), time: 3)
        await eventually("cancel on focus loss") { firstEvents.count == 2 }
        #expect(firstEvents == [press, .cancelled])
        #expect(secondEvents.isEmpty)

        rig.service.frontmost(pid: getpid())
        first.stop()
        await eventually("drop the input recipient when the client disconnects") {
            rig.service.clients.map(\.bundleID) == ["test.observer"]
        }
    }

    @Test func dialMuteFollowsFocusAndDisconnectIndependentlyOfMouseOwnership() async {
        let rig = Rig()
        defer { rig.shutDown() }
        rig.service.configureD100HTurns = { _, finish in finish(true) }
        let client = MouseClient(bundleID: "test.dial", endpointProvider: { rig.listener.endpoint })
        var states: [Bool] = []
        rig.service.onD100HDetentsMutedChange = { states.append($0) }
        client.setD100HDetentsMuted(true)
        client.start()
        await eventually("detent request") { rig.service.messagesHandled >= 2 }
        #expect(states.isEmpty)

        rig.service.frontmost(pid: getpid())
        #expect(states == [true])
        #expect(rig.driver.applied.last == MouseState(mode: .ratchet))
        rig.service.frontmost(pid: nil)
        #expect(states == [true, false])
        rig.service.frontmost(pid: getpid())
        #expect(states == [true, false, true])
        client.setD100HDetentsMuted(false)
        await eventually("explicit detent release") { states == [true, false, true, false] }
        client.setD100HDetentsMuted(true)
        await eventually("new detent request") { states == [true, false, true, false, true] }
        client.stop()
        await eventually("detent release on disconnect") { states == [true, false, true, false, true, false] }
    }

    @Test func dialCancelsOnSleepAndResumesOnlyForTheActiveSession() async {
        let rig = Rig()
        defer { rig.shutDown() }
        let client = MouseClient(bundleID: "test.player", endpointProvider: { rig.listener.endpoint })
        var input: [D100HInput] = []
        var muted: [Bool] = []
        rig.service.onD100HDetentsMutedChange = { muted.append($0) }
        client.onD100HInput = { event, _ in input.append(event) }
        client.setD100HInputRequested(true)
        client.setD100HDetentsMuted(true)
        client.start()
        await eventually("D100H requests") { rig.service.messagesHandled == 3 }
        rig.service.frontmost(pid: getpid())
        rig.service.setD100HSessionActive(false)
        rig.service.frontmost(pid: getpid())
        let turn = D100HInput.turn(.right, knobPressed: false)
        rig.service.d100hInput(turn, time: 1)
        rig.service.setD100HSessionActive(true)
        rig.service.d100hInput(turn, time: 2)
        await eventually("sleep cancellation and first resumed gesture") { input.count == 2 }
        #expect(input == [.cancelled, turn])
        #expect(muted == [true, false, true])
    }

    @Test func dialWakeRetriesDaemonWhenThePlayerAlreadyHasFocus() async {
        let rig = Rig()
        defer { rig.shutDown() }
        let unavailableDaemon = Listener(anonymous: rig.service)
        let endpoint = unavailableDaemon.endpoint
        unavailableDaemon.cancel()
        let client = MouseClient(bundleID: "test.player", endpointProvider: { rig.listener.endpoint })
        defer { client.stop() }
        var connections = 0
        rig.service.makeD100HDaemonConnection = {
            connections += 1
            return xpc_connection_create_from_endpoint(endpoint)
        }
        rig.service.configureD100HTurns = { _, complete in complete(true) }
        rig.service.allowD100HDaemon(true)
        client.setD100HInputRequested(true)
        client.start()
        await eventually("D100H request") { rig.service.messagesHandled == 2 }
        rig.service.frontmost(pid: getpid())

        // Unlock resumes the client before the system daemon can serve it.
        await eventually("first connection rejected") { rig.service.d100hDaemonRetry != nil }
        #expect(connections == 1)
        rig.service.setD100HSessionActive(true)
        #expect(connections == 2)
    }

    @Test func managedDialDefersMutingUntilItsViewingProfileIsReady() async {
        let rig = Rig()
        defer { rig.shutDown() }
        rig.service.configureD100HTurns = { _, finish in finish(true) }
        var muted: [Bool] = []
        rig.service.onD100HDetentsMutedChange = { muted.append($0) }
        let client = MouseClient(bundleID: "test.player", endpointProvider: { rig.listener.endpoint })
        defer { client.stop() }
        client.setD100HInputRequested(true)
        client.setD100HDetentsMuted(true)
        client.start()
        await eventually("D100H requests") { rig.service.messagesHandled == 3 }
        rig.service.frontmost(pid: getpid())
        rig.service.setD100HSessionActive(false)
        rig.service.setD100HSessionActive(true)

        #expect(muted.isEmpty)
    }

    @Test func helloGetsWelcomeAndDevice() async {
        let rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        client.start()
        await eventually("welcome") { client.isAvailable }
        #expect(client.device == rig.driver.device)
        #expect(rig.service.clients.map(\.bundleID) == ["test.a"])
        rig.shutDown()
    }

    @Test(arguments: [SwipePhase.ended, .cancelled])
    func swipeTerminalPhaseStaysWithTheOriginalClient(_ terminal: SwipePhase) async {
        let rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        var phases: [SwipePhase] = []
        var times: [Double] = []
        client.onSwipe = { phase, time in
            phases.append(phase)
            times.append(time)
        }
        client.start()
        await eventually("swipe negotiation") { client.receivesSwipeLifecycle }

        rig.service.frontmost(pid: nil)
        #expect(!rig.service.swipe(.began, time: 1))
        rig.service.frontmost(pid: getpid())
        #expect(!rig.service.swipe(.began, time: 1, targetPID: 1))
        #expect(rig.service.swipe(.began, time: 2, targetPID: getpid()))
        rig.service.frontmost(pid: nil)
        #expect(rig.service.swipe(terminal, time: 3))
        #expect(!rig.service.swipe(terminal, time: 4))
        await eventually("swipe lifecycle") { phases.count >= 2 }
        #expect(phases == [.began, terminal])
        #expect(times == [2, 3])
        rig.shutDown()
    }

    @Test func focusedClientWithoutSwipeCallbackUsesLegacyPath() async {
        let rig = Rig()
        let client = MouseClient(bundleID: "test.a", endpointProvider: { rig.listener.endpoint })
        client.start()
        await eventually("welcome") { client.isAvailable }
        rig.service.frontmost(pid: getpid())
        #expect(!client.receivesSwipeLifecycle)
        #expect(!rig.service.swipe(.began, time: 1))
        #expect(!rig.service.swipe(.ended, time: 2))
        rig.shutDown()
    }

    @Test func connectionLossCancelsAnActiveSwipe() async {
        let rig = Rig()
        var endpoint: xpc_endpoint_t? = rig.listener.endpoint
        let client = MouseClient(bundleID: "test.a", endpointProvider: { endpoint })
        var phases: [SwipePhase] = []
        client.onSwipe = { phase, _ in phases.append(phase) }
        client.start()
        await eventually("swipe negotiation") { client.receivesSwipeLifecycle }
        rig.service.frontmost(pid: getpid())
        #expect(rig.service.swipe(.began, time: 1))
        await eventually("swipe began") { phases == [.began] }

        endpoint = nil
        rig.shutDown()
        await eventually("lost service") { !client.isAvailable }
        #expect(!client.receivesSwipeLifecycle)
        #expect(phases == [.began, .cancelled])
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
        #expect(heard.replies == [.refused(reason: "contract 2.0 not supported, service speaks \(ContractVersion.current.text)")])
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
        var clientPIDs: Set<pid_t> = []
        rig.service.onClientPIDsChange = { clientPIDs = $0 }
        client.start()
        client.want(Want(divert: [gesture]))
        rig.service.frontmost(pid: getpid())
        await eventually("applied") { rig.driver.applied.last == MouseState(divert: [gesture], mode: .ratchet) }
        #expect(clientPIDs == [getpid()])
        client.stop()
        await eventually("released") { rig.driver.applied.last == MouseState(mode: .ratchet) }
        #expect(rig.service.clients.isEmpty)
        #expect(clientPIDs.isEmpty)
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
