import CoreGraphics

/// The contract's version, `major.minor` (core spec, "Contract v1"): a client with a higher major is refused; new
/// fields come in minor versions and old peers ignore them.
public struct ContractVersion: Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// `"1.2"`; nil for anything else.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    public static let current = ContractVersion(major: 1, minor: 0)

    public var text: String { "\(major).\(minor)" }

    public static func < (a: Self, b: Self) -> Bool { (a.major, a.minor) < (b.major, b.minor) }
}

/// The vertical wheel's mode under SmartShift; the raw values are `LogiHIDPP.WheelMode`'s.
public enum WheelMode: UInt8, Sendable {
    case freeSpin = 1
    case ratchet = 2
}

/// A client's wish for the main wheel over one of its windows, or parts of it (`rects`, in the window's coordinates,
/// origin at the bottom-left of its frame; nil: the whole window). A nil field asks nothing of the wheel.
public struct WheelWish: Equatable, Sendable {
    public var window: Int
    public var rects: [CGRect]?
    public var highResolution: Bool?
    public var mode: WheelMode?

    public init(window: Int, rects: [CGRect]? = nil, highResolution: Bool? = nil, mode: WheelMode? = nil) {
        self.window = window
        self.rects = rects
        self.highResolution = highResolution
        self.mode = mode
    }
}

/// A client's whole wish: each `want` replaces the previous one. Controls are HID++ control IDs. `divert`, `watch`
/// and `thumbWheel` hold while the client owns the buttons; `wheel` while the pointer is over the windows it names.
public struct Want: Equatable, Sendable {
    public var divert: Set<UInt16>
    public var watch: Set<UInt16>
    public var thumbWheel: Bool
    public var wheel: [WheelWish]

    public init(divert: Set<UInt16> = [], watch: Set<UInt16> = [], thumbWheel: Bool = false, wheel: [WheelWish] = []) {
        self.divert = divert
        self.watch = watch
        self.thumbWheel = thumbWheel
        self.wheel = wheel
    }

    public static let none = Want()
}

public struct ControlInfo: Equatable, Sendable {
    public let cid: UInt16
    public let divertable: Bool
    public let watchable: Bool

    public init(cid: UInt16, divertable: Bool, watchable: Bool) {
        self.cid = cid
        self.divertable = divertable
        self.watchable = watchable
    }
}

/// The mouse as the service sees it.
public struct DeviceInfo: Equatable, Sendable {
    public var present: Bool
    public var controls: [ControlInfo]
    /// Thumb-wheel steps per turn while it is diverted; nil without one.
    public var thumbWheelStepsPerRevolution: Int?
    public var haptics: Bool

    public init(present: Bool, controls: [ControlInfo], thumbWheelStepsPerRevolution: Int?, haptics: Bool) {
        self.present = present
        self.controls = controls
        self.thumbWheelStepsPerRevolution = thumbWheelStepsPerRevolution
        self.haptics = haptics
    }

    public static let absent = DeviceInfo(present: false, controls: [], thumbWheelStepsPerRevolution: nil, haptics: false)
}

public enum ThumbPhase: String, Sendable {
    case began, changed, ended
}

/// Client → service.
public enum ClientMessage: Equatable, Sendable {
    case hello(version: ContractVersion, bundleID: String)
    case want(Want)
    /// A haptic pattern (`LogiHIDPP.HapticPattern.rawValue`), at `strength` 0…100 once or the normal strength.
    case play(pattern: UInt8, strength: UInt8?)
}

/// Service → client. Times are `ProcessInfo.systemUptime`.
public enum ServiceMessage: Equatable, Sendable {
    case welcome(serviceVersion: String, device: DeviceInfo)
    case refused(reason: String)
    /// The client owns the buttons, haptics and thumb wheel now (true) or no longer.
    case owner(Bool)
    /// The controls the mouse confirms it reports while their buttons still reach the system: the client drops the
    /// system's events of these.
    case watching(Set<UInt16>)
    case button(cid: UInt16, pressed: Bool, time: Double)
    case thumbWheel(delta: Int, touching: Bool, phase: ThumbPhase, time: Double)
    /// The main wheel's state, to the client under the pointer; `byButton`: the user switched it with SmartShift.
    case wheel(highResolution: Bool, mode: WheelMode?, byButton: Bool)
    case device(DeviceInfo)
}
