import MouseContract
import MouseCore
import MouseServiceKit

/// A mouse that records what the service asks of it and reports what a test tells it to.
@MainActor final class FakeDriver: MouseDriver {
    var device = DeviceInfo(present: true, controls: [ControlInfo(cid: 0xC3, divertable: true, watchable: false)],
                            thumbWheelStepsPerRevolution: 18, haptics: true)
    var onEvent: ((DriverEvent) -> Void)?
    private(set) var applied: [MouseState] = []
    private(set) var played: [(pattern: UInt8, strength: UInt8?)] = []

    func apply(_ state: MouseState) { applied.append(state) }
    func play(pattern: UInt8, strength: UInt8?) { played.append((pattern, strength)) }
    func emit(_ event: DriverEvent) { onEvent?(event) }
}
