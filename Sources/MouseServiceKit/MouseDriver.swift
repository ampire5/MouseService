import MouseContract
import MouseCore

/// What the mouse reports, as the service needs it; the service stamps the time when it arrives.
public enum DriverEvent: Equatable, Sendable {
    case button(cid: UInt16, pressed: Bool)
    case thumbWheel(delta: Int, touching: Bool, phase: ThumbPhase)
    case wheel(highResolution: Bool, mode: WheelMode?, byButton: Bool)
    case device(DeviceInfo)
    /// The controls the mouse confirms it reports while their buttons still reach the system.
    case watching(Set<UInt16>)
}

/// The mouse behind the service: `LogiMouseDriver` in the app, a fake in the tests.
@MainActor public protocol MouseDriver: AnyObject {
    var device: DeviceInfo { get }
    var onEvent: ((DriverEvent) -> Void)? { get set }
    /// The whole wanted state; the driver writes what differs.
    func apply(_ state: MouseState)
    func play(pattern: UInt8, strength: UInt8?)
}
