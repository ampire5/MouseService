import Foundation
import MouseContract
import MouseCore
import XPC

/// The service's side of the contract: each XPC peer is a client of the `Arbiter`, whose effects go to the peers and
/// the driver. Everything runs on the main actor (plan, "Threading"): the peers are targeted at the main queue, and
/// the driver (`LogiMouse`) lives there.
@MainActor public final class Service {
    /// Touched only on the main queue, where its connection's handler runs.
    private final class Peer: @unchecked Sendable {
        let connection: xpc_connection_t
        var id: ClientID?
        var bundleID = ""
        var swipeLifecycle = false
        init(_ connection: xpc_connection_t) { self.connection = connection }
    }

    private let driver: any MouseDriver
    private let version: String
    private var arbiter = Arbiter()
    private var peers: [ClientID: Peer] = [:]
    /// Connected, not yet said hello.
    private var newcomers: [ObjectIdentifier: Peer] = [:]
    private var nextID = 1
    private var followed = false
    private var frontmostPID: pid_t?
    /// The peer that received the current swipe's beginning.
    private var swipeRecipient: ClientID?
    /// Messages handled from clients: tests wait on it to know a message got through.
    private(set) var messagesHandled = 0

    /// Called when following the pointer starts or stops being needed (`Arbiter.followsPointer`).
    public var onFollowsPointerChange: ((Bool) -> Void)?

    /// Authenticated process IDs of the connected clients, updated on connect and disconnect.
    public var onClientPIDsChange: ((Set<pid_t>) -> Void)?

    /// Called when the user's SmartShift press set the global wheel mode: the app saves it.
    public var onGlobalModeChange: ((WheelMode) -> Void)?

    /// `globalMode`: the saved one. The first state, with the global mode in it, goes to the driver at once.
    public init(driver: any MouseDriver, version: String, globalMode: WheelMode = .ratchet) {
        self.driver = driver
        self.version = version
        driver.onEvent = { [weak self] event in self?.driverEvent(event) }
        _ = arbiter.setGlobalMode(globalMode)
        run(arbiter.start())
    }

    public var followsPointer: Bool { arbiter.followsPointer }

    /// For the menu.
    public var clients: [(bundleID: String, pid: pid_t, owner: Bool)] {
        peers.sorted { $0.key < $1.key }.map { id, peer in
            (peer.bundleID, xpc_connection_get_pid(peer.connection), id == arbiter.owner)
        }
    }

    /// A new peer from the listener.
    public func accept(_ connection: xpc_connection_t) {
        let peer = Peer(connection)
        newcomers[ObjectIdentifier(connection)] = peer
        xpc_connection_set_target_queue(connection, .main)
        xpc_connection_set_event_handler(connection) { [weak self, weak peer] object in
            nonisolated(unsafe) let object = object   // delivered on the main queue
            MainActor.assumeIsolated {
                guard let self, let peer else { return }
                self.received(object, from: peer)
            }
        }
        xpc_connection_resume(connection)
    }

    public func frontmost(pid: pid_t?) {
        frontmostPID = pid
        run(arbiter.frontmost(pid: pid))
    }

    public func pointer(_ place: PointerPlace?) { run(arbiter.pointer(place)) }
    public func releaseAll() { run(arbiter.releaseAll()) }
    /// The global wheel mode from the settings.
    public func setGlobalMode(_ mode: WheelMode) { run(arbiter.setGlobalMode(mode)) }

    /// Routes a side-button swipe to a subscribed peer in the app focused at its beginning.
    /// Pass the focus captured with the input event when available. Returns whether a peer was sent this phase.
    @discardableResult public func swipe(_ phase: SwipePhase, time: Double, targetPID: pid_t? = nil) -> Bool {
        switch phase {
        case .began:
            guard swipeRecipient == nil, let pid = targetPID ?? frontmostPID else { return false }
            swipeRecipient = peers.lazy.filter { _, peer in
                peer.swipeLifecycle && xpc_connection_get_pid(peer.connection) == pid
            }.map(\.key).min()
            guard let id = swipeRecipient else { return false }
            send(.swipe(phase: phase, time: time), to: id)
        case .ended, .cancelled:
            guard let id = swipeRecipient else { return false }
            swipeRecipient = nil
            send(.swipe(phase: phase, time: time), to: id)
        }
        return true
    }
    /// Cancels every peer: they see their connection end.
    public func cancelAll() {
        for peer in Array(peers.values) + Array(newcomers.values) { xpc_connection_cancel(peer.connection) }
    }

    // MARK: Private

    private func received(_ object: xpc_object_t, from peer: Peer) {
        if xpc_get_type(object) == XPC_TYPE_ERROR {
            guard object === XPC_ERROR_CONNECTION_INVALID else { return }   // interrupted: the peer stays
            newcomers[ObjectIdentifier(peer.connection)] = nil
            if let id = peer.id {
                peers[id] = nil
                if swipeRecipient == id { swipeRecipient = nil }
                run(arbiter.disconnect(id))
                reportClientPIDs()
            }
            return
        }
        guard let message = ClientMessage(xpc: object) else { return }
        messagesHandled += 1
        switch message {
        case let .hello(clientVersion, bundleID, swipeLifecycle):
            guard peer.id == nil else { return }
            guard clientVersion.major <= ContractVersion.current.major else {
                let reason = "contract \(clientVersion.text) not supported, service speaks \(ContractVersion.current.text)"
                xpc_connection_send_message(peer.connection, ServiceMessage.refused(reason: reason).xpc())
                xpc_connection_send_barrier(peer.connection) { xpc_connection_cancel(peer.connection) }
                return
            }
            let id = ClientID(raw: nextID)
            nextID += 1
            peer.id = id
            peer.bundleID = bundleID
            peer.swipeLifecycle = swipeLifecycle && clientVersion >= .swipeLifecycle
            newcomers[ObjectIdentifier(peer.connection)] = nil
            peers[id] = peer
            send(.welcome(serviceVersion: version, device: driver.device, swipeLifecycle: peer.swipeLifecycle), to: id)
            run(arbiter.connect(id, pid: xpc_connection_get_pid(peer.connection)))
            reportClientPIDs()
        case let .want(want):
            guard let id = peer.id else { return }
            run(arbiter.want(id, want))
        case let .play(pattern, strength):
            guard let id = peer.id else { return }
            run(arbiter.play(id, pattern: pattern, strength: strength))
        }
    }

    private func reportClientPIDs() {
        onClientPIDsChange?(Set(peers.values.map { xpc_connection_get_pid($0.connection) }))
    }

    private func driverEvent(_ event: DriverEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case let .button(cid, pressed):
            run(arbiter.button(cid: cid, pressed: pressed, time: now))
        case let .thumbWheel(delta, touching, phase):
            run(arbiter.thumbWheel(delta: delta, touching: touching, phase: phase, time: now))
        case let .wheel(highResolution, mode, byButton):
            run(arbiter.wheelState(highResolution: highResolution, mode: mode, byButton: byButton))
        case let .watching(cids):
            run(arbiter.watching(cids))
        case let .device(device):
            for id in peers.keys { send(.device(device), to: id) }
        }
    }

    private func run(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case let .send(id, message): send(message, to: id)
            case let .apply(state): driver.apply(state)
            case let .globalMode(mode): onGlobalModeChange?(mode)
            case let .play(pattern, strength): driver.play(pattern: pattern, strength: strength)
            }
        }
        if arbiter.followsPointer != followed {
            followed = arbiter.followsPointer
            onFollowsPointerChange?(followed)
        }
    }

    private func send(_ message: ServiceMessage, to id: ClientID) {
        guard let peer = peers[id] else { return }
        xpc_connection_send_message(peer.connection, message.xpc())
    }
}
