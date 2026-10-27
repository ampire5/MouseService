import AppKit
import LogiHIDPP
import MouseContract
import MouseCore
import MouseServiceKit
import os

/// `mx-panel-force`: how hard the MX Master 4's haptic panel must be pressed (FrameScrub's `PanelForceSetting`).
/// `0…100` goes linearly over the mouse's range, `default` writes the factory value, `keep` never writes it.
enum PanelForce: Equatable {
    case keep, factoryDefault, percent(Int)

    /// The force to write, in the mouse's units, given what the mouse reports; nil for `keep`.
    func value(range: ClosedRange<UInt16>, defaultValue: UInt16) -> UInt16? {
        switch self {
        case .keep: return nil
        case .factoryDefault: return defaultValue
        case .percent(let p):
            let span = Double(range.upperBound - range.lowerBound)
            return range.lowerBound + UInt16((Double(min(max(p, 0), 100)) * span / 100).rounded())
        }
    }

    var text: String {
        switch self {
        case .keep: "keep"
        case .factoryDefault: "default"
        case .percent(let p): String(p)
        }
    }

    /// `keep`, `default` (any case) or a whole number 0…100; nil otherwise.
    static func parse(_ text: String) -> PanelForce? {
        switch text.lowercased() {
        case "keep": return .keep
        case "default": return .factoryDefault
        default:
            guard let p = Int(text), (0...100).contains(p) else { return nil }
            return .percent(p)
        }
    }
}

/// The service's one `LogiMouse`: always active (the service is not an app in front; the arbiter decides who owns
/// what), the wanted state from `Service`, the mouse's events back as `DriverEvent`s, and the two device settings
/// that are the service's alone. On its first contact with the mouse it releases every control and the thumb wheel,
/// whatever a crashed predecessor or another program left diverted (core spec, "Service crashes").
@MainActor final class LogiMouseDriver: MouseDriver {
    var onEvent: ((DriverEvent) -> Void)?
    private(set) var device = DeviceInfo.absent

    private let mouse = LogiMouse()
    private var state = MouseState.released
    private var cleanStartDone = false
    private var reportedWatching: Set<UInt16> = []
    private var watchCheck: DispatchWorkItem?
    private var hapticStrength: UInt8?
    private var panelForce: PanelForce
    private var wakeObserver: NSObjectProtocol?
    private static let log = Logger(subsystem: "local.mouseservice", category: "Mouse")

    init(hapticStrength: UInt8?, panelForce: PanelForce) {
        self.hapticStrength = hapticStrength
        self.panelForce = panelForce
        if let hapticStrength { mouse.setHapticStrength(hapticStrength) }
        mouse.start()
        mouse.setActive(true)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouse.systemDidWake() }
        }
        Task { @MainActor [weak self] in
            guard let events = self?.mouse.events else { return }
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    func apply(_ state: MouseState) {
        self.state = state
        push()
        // The mouse confirms a watch with its reply, which no event announces: look once a moment later.
        watchCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.reportWatching() }
        watchCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
    }

    func play(pattern: UInt8, strength: UInt8?) {
        guard let pattern = HapticPattern(pattern) else { return }
        mouse.play(haptic: pattern, strength: strength)
    }

    /// nil keeps the mouse's own strength.
    func setHapticStrength(_ strength: UInt8?) {
        guard strength != hapticStrength else { return }
        hapticStrength = strength
        if let strength { mouse.setHapticStrength(strength) }
    }

    func setPanelForce(_ force: PanelForce) {
        panelForce = force
        applyPanelForce()
    }

    /// At quit: everything back to the mouse before the process ends.
    func releaseAllSync() { mouse.releaseAllSync() }

    // MARK: Private

    /// The whole state to the package, which writes only what differs from the mouse.
    private func push() {
        mouse.divert(Set(state.divert.map(CID.init(rawValue:))))
        mouse.watch(Set(state.watch.map(CID.init(rawValue:))))
        mouse.divertThumbWheel(state.thumbWheel)
        mouse.wantHighResolutionWheel(state.highResolution)
        mouse.wantWheelMode(state.mode.flatMap { LogiHIDPP.WheelMode(rawValue: $0.rawValue) })
    }

    private func handle(_ event: MouseEvent) {
        switch event {
        case let .pressed(cid, _):
            onEvent?(.button(cid: cid.rawValue, pressed: true))
        case let .released(cid, _):
            onEvent?(.button(cid: cid.rawValue, pressed: false))
        case let .thumbWheel(delta, touching, phase, _):
            let p: ThumbPhase = switch phase {
            case .began: .began
            case .changed: .changed
            case .ended: .ended
            }
            onEvent?(.thumbWheel(delta: delta, touching: touching, phase: p))
        case .connected:
            Self.log.info("connected")
            if !cleanStartDone {
                cleanStartDone = true
                // Taken and released at once: the package releases what it wants, so this releases everything.
                mouse.divert(Set(mouse.controls.filter(\.divertable).map(\.cid)))
                mouse.watch(Set(mouse.controls.filter(\.watchable).map(\.cid)))
                mouse.divertThumbWheel(true)
                mouse.releaseAll()
                push()
            }
            applyPanelForce()
            updateDevice()
        case .disconnected:
            Self.log.info("disconnected")
            updateDevice()
        case let .highResolutionWheel(on):
            onEvent?(.wheel(highResolution: on, mode: mode(mouse.wheelMode), byButton: false))
        case let .wheelMode(m, byButton):
            onEvent?(.wheel(highResolution: mouse.isHighResolution, mode: mode(m), byButton: byButton))
        }
        reportWatching()
    }

    private func mode(_ m: LogiHIDPP.WheelMode?) -> MouseContract.WheelMode? {
        m.flatMap { MouseContract.WheelMode(rawValue: $0.rawValue) }
    }

    private func updateDevice() {
        let now = DeviceInfo(present: mouse.isConnected,
                             controls: mouse.controls.map {
                                 ControlInfo(cid: $0.cid.rawValue, divertable: $0.divertable, watchable: $0.watchable)
                             },
                             thumbWheelStepsPerRevolution: mouse.stepsPerRevolution,
                             haptics: mouse.hapticStrength != nil)
        guard now != device else { return }
        device = now
        onEvent?(.device(now))
    }

    private func reportWatching() {
        let now = Set(mouse.watching.map(\.rawValue))
        guard now != reportedWatching else { return }
        reportedWatching = now
        onEvent?(.watching(now))
    }

    /// The panel force over the range the mouse reported: nothing before it is set up, for `keep`, for a force that
    /// cannot change, or when the mouse already has that value (Loupe's `applyPanelForce`).
    private func applyPanelForce() {
        guard let force = mouse.panelForce, force.info.changeable,
              let value = panelForce.value(range: force.info.range, defaultValue: force.info.defaultValue),
              value != force.current else { return }
        Self.log.info("panel force \(force.current) -> \(value)")
        mouse.setPanelForce(value)
    }
}
