import AppKit
import MouseContract
import XPC

/// An app's connection to MouseService (core spec, "Contract v1"). The app states its whole wish (`want`) whenever it
/// changes and hears the mouse through the callbacks, on the main actor. The client keeps the last wish and sends it
/// again after every reconnect. When the service goes away it releases every control it reported held and says
/// `onOwner(false)`, so no press is left hanging. Without a service (not installed, or refused) the app has no
/// Logitech features; the client tries again on the app's next activation, never on a timer.
@MainActor public final class MouseClient {
    public static let serviceName = "local.mouseservice.xpc"

    /// Welcomed by a service now.
    public private(set) var isAvailable = false
    /// A connection is up and its hello not yet answered.
    public private(set) var isConnecting = false
    /// The app owns the buttons, haptics and thumb wheel now.
    public private(set) var isOwner = false
    public private(set) var device = DeviceInfo.absent
    /// The controls the mouse reports while the system still gets their buttons: drop the system's events of these.
    public private(set) var watching: Set<UInt16> = []
    /// The main wheel's state, as last heard (while the pointer is over a window the app declared).
    public private(set) var wheel: (highResolution: Bool, mode: WheelMode?) = (false, nil)

    public var onOwner: ((Bool) -> Void)?
    public var onButton: ((_ cid: UInt16, _ pressed: Bool, _ time: Double) -> Void)?
    public var onThumbWheel: ((_ delta: Int, _ touching: Bool, _ phase: ThumbPhase, _ time: Double) -> Void)?
    public var onWheel: ((_ highResolution: Bool, _ mode: WheelMode?, _ byButton: Bool) -> Void)?
    public var onDevice: ((DeviceInfo) -> Void)?
    public var onAvailability: ((Bool) -> Void)?
    public var onWatching: ((Set<UInt16>) -> Void)?

    private let bundleID: String
    private let makeConnection: () -> xpc_connection_t?
    private var connection: xpc_connection_t?
    /// The current connection got a welcome at some point: its end is a service that went away, worth one reconnect
    /// at once. A connection never welcomed ends quietly (no service), so there is no loop.
    private var welcomed = false
    private var wanted: Want?
    private var sent: Want?
    private var held: Set<UInt16> = []
    private var activationObserver: NSObjectProtocol?

    /// The installed service, by its Mach name.
    public convenience init(bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        self.init(bundleID: bundleID, makeConnection: {
            xpc_connection_create_mach_service(MouseClient.serviceName, .main, 0)
        })
    }

    /// A service on an anonymous listener (tests); the provider is asked again at each reconnect.
    public convenience init(bundleID: String, endpointProvider: @escaping () -> xpc_endpoint_t?) {
        self.init(bundleID: bundleID, makeConnection: { endpointProvider().map(xpc_connection_create_from_endpoint) })
    }

    private init(bundleID: String, makeConnection: @escaping () -> xpc_connection_t?) {
        self.bundleID = bundleID
        self.makeConnection = makeConnection
    }

    /// Connects and says hello; while unavailable, tries again on every activation of the app.
    public func start() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.connection == nil else { return }
                    self.connect()
                }
            }
        }
        connect()
    }

    /// Closes the connection: the service releases what the app held.
    public func stop() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        guard let connection else { return }
        self.connection = nil
        xpc_connection_cancel(connection)
        lost()
        isAvailable = false
        isConnecting = false
    }

    /// The app's whole wish; sent when it differs from the last one sent.
    public func want(_ want: Want) {
        wanted = want
        guard let connection, want != sent else { return }
        sent = want
        xpc_connection_send_message(connection, ClientMessage.want(want).xpc())
    }

    /// A haptic pattern; the service drops it unless the app owns haptics.
    public func play(pattern: UInt8, strength: UInt8? = nil) {
        guard let connection else { return }
        xpc_connection_send_message(connection, ClientMessage.play(pattern: pattern, strength: strength).xpc())
    }

    // MARK: Private

    private func connect() {
        guard connection == nil else { return }
        welcomed = false
        guard let connection = makeConnection() else {
            isConnecting = false
            setAvailable(false)
            return
        }
        self.connection = connection
        xpc_connection_set_target_queue(connection, .main)
        nonisolated(unsafe) let from = connection
        xpc_connection_set_event_handler(connection) { [weak self] object in
            nonisolated(unsafe) let object = object   // delivered on the main queue
            MainActor.assumeIsolated { self?.received(object, on: from) }
        }
        xpc_connection_resume(connection)
        hello()
    }

    /// Hello, then the last wish at once: messages on one connection keep their order.
    private func hello() {
        guard let connection else { return }
        isConnecting = true
        xpc_connection_send_message(connection, ClientMessage.hello(version: .current, bundleID: bundleID).xpc())
        sent = nil
        if let wanted { want(wanted) }
    }

    private func received(_ object: xpc_object_t, on from: xpc_connection_t) {
        guard from === connection else { return }   // a connection replaced since
        if xpc_get_type(object) == XPC_TYPE_ERROR {
            let reconnect = welcomed
            lost()
            welcomed = reconnect   // still the same connection: an interruption may come before its end
            if object === XPC_ERROR_CONNECTION_INTERRUPTED {
                hello()   // the service died; launchd starts it again for this message
            } else {
                connection = nil
                isConnecting = false
                setAvailable(false)
                if reconnect { connect() }   // a service that was there and went: try once more now
            }
            return
        }
        guard let message = ServiceMessage(xpc: object) else { return }
        switch message {
        case let .welcome(_, device):
            welcomed = true
            isConnecting = false
            self.device = device
            setAvailable(true)
            onDevice?(device)
        case .refused:
            welcomed = false
            isConnecting = false
            setAvailable(false)
            if let connection { xpc_connection_cancel(connection) }
        case let .owner(owner):
            guard owner != isOwner else { return }
            isOwner = owner
            onOwner?(owner)
        case let .watching(cids):
            watching = cids
            onWatching?(cids)
        case let .button(cid, pressed, time):
            if pressed { held.insert(cid) } else { held.remove(cid) }
            onButton?(cid, pressed, time)
        case let .thumbWheel(delta, touching, phase, time):
            onThumbWheel?(delta, touching, phase, time)
        case let .wheel(highResolution, mode, byButton):
            wheel = (highResolution, mode)
            onWheel?(highResolution, mode, byButton)
        case let .device(device):
            self.device = device
            onDevice?(device)
        }
    }

    /// The service went away: every held control released, ownership gone.
    private func lost() {
        let now = ProcessInfo.processInfo.systemUptime
        for cid in held.sorted() { onButton?(cid, false, now) }
        held = []
        if isOwner {
            isOwner = false
            onOwner?(false)
        }
        if !watching.isEmpty {
            watching = []
            onWatching?([])
        }
    }

    private func setAvailable(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        onAvailability?(available)
    }
}
