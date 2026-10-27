import Foundation
import XPC

/// The service's XPC listener: the Mach service launchd gives the agent, or an anonymous one for tests. Each new peer
/// goes to the `Service`.
@MainActor public final class Listener {
    private let connection: xpc_connection_t
    private let anonymous: Bool

    public init(machService name: String, service: Service) {
        connection = xpc_connection_create_mach_service(name, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        anonymous = false
        listen(service)
    }

    public init(anonymous service: Service) {
        connection = xpc_connection_create(nil, .main)
        anonymous = true
        listen(service)
    }

    /// Where a client of the anonymous listener connects (`xpc_connection_create_from_endpoint`).
    public var endpoint: xpc_endpoint_t {
        precondition(anonymous, "a Mach service listener is found by its name")
        return xpc_endpoint_create(connection)
    }

    public func cancel() { xpc_connection_cancel(connection) }

    private func listen(_ service: Service) {
        xpc_connection_set_event_handler(connection) { [weak service] object in
            guard xpc_get_type(object) == XPC_TYPE_CONNECTION else { return }
            nonisolated(unsafe) let peer = object   // the handler runs on the main queue: no other thread sees it
            MainActor.assumeIsolated { service?.accept(peer) }
        }
        xpc_connection_resume(connection)
    }
}
