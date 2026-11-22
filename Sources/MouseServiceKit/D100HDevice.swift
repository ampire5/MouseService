import Foundation
import MouseContract
import MouseCore
import XPC

/// Firmware operations supplied by the app's Bluetooth adapter.
@MainActor public protocol D100HFirmware: AnyObject {
    var supportsTurnMapping: Bool { get }
    func recover()
    func setMuted(_ muted: Bool)
    func setTurnMapping(_ enabled: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func stop(completion: @escaping @Sendable () -> Void)
}

/// Coordinates the D100H's HID reader and Bluetooth settings as one device.
/// Foreground requests come from the host, which owns application focus and client identities.
@MainActor public final class D100HDevice {
    struct Request {
        // nil is a legacy detent-only client. An explicit input request waits for capture readiness.
        var input: Bool?
        var muteDetents = false
    }

    private let firmware: any D100HFirmware
    private var managesCapture: Bool { firmware.supportsTurnMapping }
    private var requests: [ClientID: Request] = [:]
    private var recipient: ClientID?
    private var detentsMuted = false
    private var sessionActive = true
    private var stopping = false
    private var session: UInt64 = 0
    private var capture = D100HCapture()

    private var reader: xpc_connection_t?
    private var daemon: xpc_connection_t?
    private var daemonAllowed = false
    private var daemonRetiring = false
    private var recoveryRequested = false
    private var needsRecoveryLink = false
    private var recovering = false
    private var daemonAttempts = 0
    private(set) var daemonRetry: Task<Void, Never>?
    var makeDaemonConnection: () -> xpc_connection_t = {
        xpc_connection_create_mach_service(D100HHelperMessage.daemonName, .main,
                                           UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
    }

    var onInput: ((ClientID, D100HInput, Double) -> Void)?

    public init(firmware: any D100HFirmware) { self.firmware = firmware }

    public func start() { firmware.recover() }

    public func stop(completion: @escaping @Sendable () -> Void) {
        stopping = true
        updateRecipient()
        updateDetents()
        firmware.stop(completion: completion)
    }

    public func allowDaemon(_ allowed: Bool) {
        guard allowed != daemonAllowed else { return }
        daemonAllowed = allowed
        daemonAttempts = 0
        connectDaemon()
    }

    public func setSessionActive(_ active: Bool) {
        if active {
            // A workspace wake can follow unlock. Give the daemon a fresh attempt on both.
            cancelRetry()
            daemonAttempts = 0
        }
        if active != sessionActive {
            sessionActive = active
            updateRecipient()
            updateDetents()
        }
        if active { connectDaemon() }
    }

    func updateForegroundRequests(_ requests: [ClientID: Request]) {
        self.requests = requests
        updateRecipient()
        updateDetents()
    }

    func deliver(_ input: D100HInput, time: Double) {
        guard let recipient else { return }
        onInput?(recipient, input, time)
    }

    func isReader(_ connection: xpc_connection_t) -> Bool { connection === reader }

    func cancelDaemonConnection() {
        cancelRetry()
        if let daemon { xpc_connection_cancel(daemon) }
    }

    func readerDisconnected(_ connection: xpc_connection_t) {
        guard isReader(connection) else { return }
        reader = nil
        cancelInput()
        updateReader()
    }

    func receive(_ message: D100HHelperMessage, from connection: xpc_connection_t, isClient: Bool) {
        receive(message, from: connection, isPrivilegedHelper: !isClient && xpc_connection_get_euid(connection) == 0)
    }

    func receive(_ message: D100HHelperMessage, from connection: xpc_connection_t,
                 isPrivilegedHelper: @autoclosure () -> Bool) {
        switch message {
        case .hello, .managedHello:
            guard isPrivilegedHelper(), reader == nil,
                  !recovering, daemon == nil || connection === daemon,
                  (message == .managedHello) == managesCapture else {
                let reason = "D100H reader requires administrator privileges, a matching mode and an available reader slot"
                xpc_connection_send_message(connection, ServiceMessage.refused(reason: reason).xpc())
                xpc_connection_send_barrier(connection) { xpc_connection_cancel(connection) }
                return
            }
            reader = connection
            if connection === daemon {
                daemonAttempts = 0
                needsRecoveryLink = false
            } else if message == .managedHello {
                sendCapture(nil)
            }
            updateReader()
        case .recover:
            guard connection === daemon, isPrivilegedHelper() else { return }
            needsRecoveryLink = true
            recoveryRequested = true
            recoverDaemon()
        case .suspend:
            guard isReader(connection), connection === daemon else { return }
            let needsRelease = capture.hasCaptureCommand
            daemonRetiring = true
            updateRecipient()
            if !needsRelease { sendRelease(restored: capture.restorationVerified) }
        case let .captured(session, open):
            guard isReader(connection), managesCapture else { return }
            if !open, capture.accepts(session) { cancelInput() }
            run(capture.readerReported(session: session, open: open))
        case let .input(session, event, time):
            guard isReader(connection), session == self.session,
                  !managesCapture || capture.acceptsInput(event, session: session, time: time) else { return }
            deliver(event, time: time)
        case .capture, .connect, .release:
            break
        }
    }

    private func updateRecipient() {
        let next = stopping || !sessionActive || daemonRetiring ? nil : requests.lazy
            .filter { $0.value.input == true }.map(\.key).min()
        guard next != recipient else { return }
        cancelInput()
        recipient = next
        session += 1
        daemonAttempts = 0
        if !needsDaemon { cancelRetry() }
        updateReader()
    }

    private func cancelInput() { deliver(.cancelled, time: ProcessInfo.processInfo.systemUptime) }

    private func updateReader() {
        let wanted = recipient == nil ? nil : session
        if managesCapture {
            run(capture.update(wanted: wanted, readerAvailable: reader != nil))
        } else {
            sendCapture(wanted)
        }
        connectDaemon()
    }

    private var needsDaemon: Bool { recipient != nil || needsRecoveryLink }

    private func connectDaemon() {
        guard daemonAllowed, !stopping, !recovering, sessionActive, needsDaemon, managesCapture,
              reader == nil, daemon == nil, daemonRetry == nil, daemonAttempts < 5 else { return }
        daemonAttempts += 1
        let connection = makeDaemonConnection()
        daemon = connection
        let id = ObjectIdentifier(connection)
        xpc_connection_set_target_queue(connection, .main)
        xpc_connection_set_event_handler(connection) { [weak self] object in
            nonisolated(unsafe) let object = object // Delivered on the main queue.
            MainActor.assumeIsolated { self?.receiveDaemon(object, id: id) }
        }
        xpc_connection_resume(connection)
        xpc_connection_send_message(connection, D100HHelperMessage.connect.xpc())
    }

    private func receiveDaemon(_ object: xpc_object_t, id: ObjectIdentifier) {
        guard let daemon, ObjectIdentifier(daemon) == id else { return }
        if xpc_get_type(object) == XPC_TYPE_ERROR {
            needsRecoveryLink = needsRecoveryLink || !capture.restorationVerified || recovering
            self.daemon = nil
            daemonRetiring = false
            recoveryRequested = false
            // Firmware recovery can outlive its XPC connection. Keep the reader blocked until its completion.
            xpc_connection_cancel(daemon)
            retryDaemon()
            readerDisconnected(daemon)
            updateRecipient()
        } else if let message = D100HHelperMessage(xpc: object) {
            receive(message, from: daemon, isClient: false)
        }
    }

    private func retryDaemon() {
        guard daemonAllowed, sessionActive, needsDaemon, !stopping, daemonAttempts < 5 else { return }
        let delay = Duration.seconds(1 << max(0, daemonAttempts - 1))
        daemonRetry = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.daemonRetry = nil
            self?.connectDaemon()
        }
    }

    private func cancelRetry() {
        daemonRetry?.cancel()
        daemonRetry = nil
    }

    private func recoverDaemon() {
        guard recoveryRequested, !stopping, !recovering, !capture.restorationInProgress, let daemon else { return }
        recoveryRequested = false
        recovering = true
        let id = ObjectIdentifier(daemon)
        firmware.setTurnMapping(false) { [weak self] restored in
            guard let self else { return }
            recovering = false
            guard let daemon = self.daemon, ObjectIdentifier(daemon) == id else {
                connectDaemon()
                return
            }
            // The daemon's next hello confirms it received a successful release.
            xpc_connection_send_message(daemon, D100HHelperMessage.release(restored: restored).xpc())
        }
    }

    private func run(_ actions: [D100HCapture.Action]) {
        for action in actions {
            switch action {
            case let .capture(session):
                sendCapture(session)
            case let .release(restored):
                sendRelease(restored: restored)
            case let .configure(enabled, revision):
                firmware.setTurnMapping(enabled) { [weak self] success in
                    guard let self else { return }
                    let time = ProcessInfo.processInfo.systemUptime
                    run(capture.configurationFinished(revision: revision, success: success, time: time))
                    recoverDaemon()
                }
            }
        }
        updateDetents()
    }

    private func sendCapture(_ session: UInt64?) {
        if let reader { xpc_connection_send_message(reader, D100HHelperMessage.capture(session).xpc()) }
    }

    private func sendRelease(restored: Bool) {
        guard let reader else { return }
        let message: D100HHelperMessage = reader === daemon ? .release(restored: restored) : .capture(nil)
        xpc_connection_send_message(reader, message.xpc())
    }

    private func updateDetents() {
        // On wake the player may regain focus before the reader captures the device and configures the profile.
        let ready = !managesCapture || capture.accepts(session)
        let muted = !stopping && sessionActive && requests.values.contains {
            $0.muteDetents && (ready || $0.input == nil)
        }
        guard muted != detentsMuted else { return }
        detentsMuted = muted
        firmware.setMuted(muted)
    }
}
