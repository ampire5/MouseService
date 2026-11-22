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
        var d100hDetentsMuted = false
        var d100hInputRequested: Bool?
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
    private var d100hDetentsMuted = false
    private var d100hRecipient: ClientID?
    private var d100hHelper: Peer?
    private var d100hSession: UInt64 = 0
    private var d100hCapture = D100HCapture()
    private var d100hStopping = false
    private var d100hSessionActive = true
    private var d100hDaemonAllowed = false
    private var d100hDaemonConnection: xpc_connection_t?
    private var d100hDaemonRetiring = false
    private var d100hRecoveryRequested = false
    private var d100hNeedsRecoveryLink = false
    private var d100hRecovering = false
    private(set) var d100hDaemonRetry: Task<Void, Never>?
    private var d100hDaemonAttempts = 0
    var makeD100HDaemonConnection: () -> xpc_connection_t = {
        xpc_connection_create_mach_service(D100HHelperMessage.daemonName, .main,
                                           UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
    }
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

    /// The effective detent request from clients in the foreground.
    public var onD100HDetentsMutedChange: ((Bool) -> Void)?

    /// Called after the reader confirms exclusive capture, and again to restore before it releases.
    public var configureD100HTurns: ((Bool, @escaping @MainActor @Sendable (Bool) -> Void) -> Void)?

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
        updateD100HRecipient()
        updateD100HDetents()
    }

    func d100hInput(_ input: D100HInput, time: Double) {
        guard let recipient = d100hRecipient else { return }
        send(.d100hInput(input, time: time), to: recipient)
    }

    public func pointer(_ place: PointerPlace?) { run(arbiter.pointer(place)) }
    public func releaseAll() { run(arbiter.releaseAll()) }

    public func stopD100HInput() {
        d100hStopping = true
        updateD100HRecipient()
    }

    public func allowD100HDaemon(_ allowed: Bool) {
        guard allowed != d100hDaemonAllowed else { return }
        d100hDaemonAllowed = allowed
        d100hDaemonAttempts = 0
        connectD100HDaemon()
    }

    public func setD100HSessionActive(_ active: Bool) {
        if active {
            // Unlock can precede the daemon's wake. The later workspace wake must
            // give it a fresh attempt even if the player and console are still active.
            d100hDaemonRetry?.cancel()
            d100hDaemonRetry = nil
            d100hDaemonAttempts = 0
        }
        if active != d100hSessionActive {
            d100hSessionActive = active
            updateD100HRecipient()
            updateD100HDetents()
        }
        if active { connectD100HDaemon() }
    }
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
            let daemon = peer.connection === d100hDaemonConnection
            guard daemon || object === XPC_ERROR_CONNECTION_INVALID else { return }
            if daemon {
                d100hNeedsRecoveryLink = !d100hCapture.restorationVerified || d100hRecovering
                d100hDaemonConnection = nil
                d100hDaemonRetiring = false
                d100hRecoveryRequested = false
                d100hRecovering = false
                xpc_connection_cancel(peer.connection)
                retryD100HDaemon()
            }
            newcomers[ObjectIdentifier(peer.connection)] = nil
            if d100hHelper === peer {
                d100hHelper = nil
                d100hInput(.cancelled, time: ProcessInfo.processInfo.systemUptime)
                updateD100HHelper()
            }
            if daemon {
                updateD100HRecipient()
            }
            if let id = peer.id {
                peers[id] = nil
                if swipeRecipient == id { swipeRecipient = nil }
                run(arbiter.disconnect(id))
                reportClientPIDs()
                updateD100HRecipient()
                updateD100HDetents()
            }
            return
        }
        guard let message = ClientMessage(xpc: object) else {
            if let helperMessage = D100HHelperMessage(xpc: object) { received(helperMessage, from: peer) }
            return
        }
        guard peer !== d100hHelper else { return }
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
        case let .d100hDetentsMuted(muted):
            guard peer.id != nil else { return }
            peer.d100hDetentsMuted = muted
            updateD100HDetents()
        case let .d100hInputRequested(requested):
            guard peer.id != nil else { return }
            peer.d100hInputRequested = requested
            updateD100HRecipient()
            updateD100HDetents()
        }
    }

    private func updateD100HRecipient() {
        let next = d100hStopping || !d100hSessionActive || d100hDaemonRetiring ? nil : frontmostPID.flatMap { pid in
            peers.lazy.filter { _, peer in
                peer.d100hInputRequested == true && xpc_connection_get_pid(peer.connection) == pid
            }.map(\.key).min()
        }
        let previous = d100hRecipient
        guard next != previous else { return }
        d100hInput(.cancelled, time: ProcessInfo.processInfo.systemUptime)
        d100hRecipient = next
        d100hSession += 1
        d100hDaemonAttempts = 0
        if next == nil {
            d100hDaemonRetry?.cancel()
            d100hDaemonRetry = nil
        }
        updateD100HHelper()
    }

    private func received(_ message: D100HHelperMessage, from peer: Peer) {
        switch message {
        case .hello, .managedHello:
            guard peer.id == nil, d100hHelper == nil, xpc_connection_get_euid(peer.connection) == 0,
                  (message == .managedHello) == (configureD100HTurns != nil) else {
                let connection = peer.connection
                let reason = "D100H reader requires administrator privileges, a dedicated connection and a matching mode"
                xpc_connection_send_message(connection, ServiceMessage.refused(reason: reason).xpc())
                xpc_connection_send_barrier(connection) { xpc_connection_cancel(connection) }
                return
            }
            d100hHelper = peer
            if peer.connection === d100hDaemonConnection {
                d100hDaemonAttempts = 0
                d100hNeedsRecoveryLink = false
            } else if message == .managedHello {
                sendD100HCapture(nil)
            }
            updateD100HHelper()
        case .recover:
            guard peer.connection === d100hDaemonConnection, xpc_connection_get_euid(peer.connection) == 0 else { return }
            d100hRecoveryRequested = true
            recoverD100HDaemon()
        case .suspend:
            guard peer === d100hHelper, peer.connection === d100hDaemonConnection else { return }
            let needsRelease = d100hCapture.hasCaptureCommand
            d100hDaemonRetiring = true
            updateD100HRecipient()
            if !needsRelease { sendD100HRelease(restored: d100hCapture.restorationVerified) }
        case let .captured(session, open):
            guard peer === d100hHelper, configureD100HTurns != nil else { return }
            if !open, d100hCapture.accepts(session) {
                d100hInput(.cancelled, time: ProcessInfo.processInfo.systemUptime)
            }
            runD100HCapture(d100hCapture.readerReported(session: session, open: open))
        case let .input(session, event, time):
            guard peer === d100hHelper, session == d100hSession,
                  configureD100HTurns == nil || d100hCapture.accepts(session) else { return }
            d100hInput(event, time: time)
        case .capture, .connect, .release:
            break
        }
    }

    private func updateD100HHelper() {
        let session = d100hRecipient == nil ? nil : d100hSession
        if configureD100HTurns != nil {
            runD100HCapture(d100hCapture.update(wanted: session, readerAvailable: d100hHelper != nil))
        } else {
            sendD100HCapture(session)
        }
        connectD100HDaemon()
    }

    private func connectD100HDaemon() {
        guard d100hDaemonAllowed, !d100hStopping, d100hSessionActive, d100hNeedsLink, configureD100HTurns != nil,
              d100hHelper == nil, d100hDaemonConnection == nil, d100hDaemonRetry == nil,
              d100hDaemonAttempts < 5 else { return }
        d100hDaemonAttempts += 1
        let connection = makeD100HDaemonConnection()
        d100hDaemonConnection = connection
        accept(connection)
        xpc_connection_send_message(connection, D100HHelperMessage.connect.xpc())
    }

    private func retryD100HDaemon() {
        guard d100hDaemonAllowed, d100hSessionActive, d100hNeedsLink, !d100hStopping, d100hDaemonAttempts < 5 else { return }
        let delay = Duration.seconds(1 << max(0, d100hDaemonAttempts - 1))
        d100hDaemonRetry = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.d100hDaemonRetry = nil
            self?.connectD100HDaemon()
        }
    }

    private var d100hNeedsLink: Bool { d100hRecipient != nil || d100hNeedsRecoveryLink }

    private func recoverD100HDaemon() {
        guard d100hRecoveryRequested, !d100hRecovering, !d100hCapture.restorationInProgress,
              let connection = d100hDaemonConnection else { return }
        d100hRecoveryRequested = false
        d100hRecovering = true
        nonisolated(unsafe) let source = connection // The completion is delivered on MainActor.
        configureD100HTurns?(false) { [weak self] restored in
            guard let self, source === d100hDaemonConnection else { return }
            d100hRecovering = false
            d100hNeedsRecoveryLink = !restored
            xpc_connection_send_message(source, D100HHelperMessage.release(restored: restored).xpc())
        }
    }

    private func runD100HCapture(_ actions: [D100HCapture.Action]) {
        for action in actions {
            switch action {
            case let .capture(session):
                sendD100HCapture(session)
            case let .release(restored):
                sendD100HRelease(restored: restored)
            case let .configure(enabled, revision):
                configureD100HTurns?(enabled) { [weak self] success in
                    guard let self else { return }
                    runD100HCapture(d100hCapture.configurationFinished(revision: revision, success: success))
                    recoverD100HDaemon()
                }
            }
        }
        updateD100HDetents()
    }

    private func sendD100HCapture(_ session: UInt64?) {
        if let d100hHelper {
            xpc_connection_send_message(d100hHelper.connection, D100HHelperMessage.capture(session).xpc())
        }
    }

    private func sendD100HRelease(restored: Bool) {
        guard let d100hHelper else { return }
        let message: D100HHelperMessage = d100hHelper.connection === d100hDaemonConnection
            ? .release(restored: restored) : .capture(nil)
        xpc_connection_send_message(d100hHelper.connection, message.xpc())
    }

    private func updateD100HDetents() {
        // On wake the client may regain focus before the HID daemon starts. Let the
        // turn profile open the Bluetooth settings session before muting detents.
        let ready = configureD100HTurns == nil || d100hCapture.accepts(d100hSession)
        let muted = d100hSessionActive && (frontmostPID.map { pid in
            peers.values.contains { peer in
                peer.d100hDetentsMuted && xpc_connection_get_pid(peer.connection) == pid
                    && (ready || peer.d100hInputRequested == nil)
            }
        } ?? false)
        guard muted != d100hDetentsMuted else { return }
        d100hDetentsMuted = muted
        onD100HDetentsMutedChange?(muted)
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
