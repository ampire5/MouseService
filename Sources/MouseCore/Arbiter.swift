import Foundation
import MouseContract

/// A connected client, as the service numbers them.
public struct ClientID: Hashable, Comparable, Sendable {
    public let raw: Int
    public init(raw: Int) { self.raw = raw }
    public static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
}

/// What the mouse should be: the service writes the difference from what it is.
public struct MouseState: Equatable, Sendable {
    public var divert: Set<UInt16>
    public var watch: Set<UInt16>
    public var thumbWheel: Bool
    public var highResolution: Bool
    /// nil: the mouse's own mode. The arbiter always wants one: the global mode where no client asks for another.
    public var mode: WheelMode?

    public init(divert: Set<UInt16> = [], watch: Set<UInt16> = [], thumbWheel: Bool = false,
                highResolution: Bool = false, mode: WheelMode? = nil) {
        self.divert = divert
        self.watch = watch
        self.thumbWheel = thumbWheel
        self.highResolution = highResolution
        self.mode = mode
    }

    /// Nothing taken: the mouse as the system's.
    public static let released = MouseState()
}

/// The window under the pointer: its number, its owner's pid and the point in its coordinates (origin at the
/// bottom-left of its frame).
public struct PointerPlace: Equatable, Sendable {
    public var window: Int
    public var pid: pid_t
    public var point: CGPoint

    public init(window: Int, pid: pid_t, point: CGPoint) {
        self.window = window
        self.pid = pid
        self.point = point
    }
}

public enum Effect: Equatable, Sendable {
    case send(ClientID, ServiceMessage)
    /// The global wheel mode changed by the user's SmartShift press: to be saved.
    case globalMode(WheelMode)
    /// The whole new state, emitted only when it changed.
    case apply(MouseState)
    case play(pattern: UInt8, strength: UInt8?)
}

/// Who owns the mouse and what it should be (core spec, "Arbitration and data flow"): pure, every input an event,
/// every output an `Effect`. The owner of buttons, haptics and the thumb wheel is the frontmost app if it is a client;
/// an owner change releases every control it holds before it is told, and the new owner is told after the mouse has
/// its wishes. The main wheel's mode is that of the window under the pointer, from its client's declared areas, and
/// the global mode (ratchet at start) wherever no client asks for another; the client under the pointer hears the
/// wheel's state.
public struct Arbiter: Sendable {
    struct Client: Sendable {
        let pid: pid_t
        var want = Want.none
    }

    /// The SmartShift button's control ID (`LogiHIDPP.CID.smartShift`).
    static let smartShift: UInt16 = 0xC4

    var clients: [ClientID: Client] = [:]
    private var frontmostPID: pid_t?
    /// "Release All": no owner until the next activation.
    private var suspended = false
    public private(set) var owner: ClientID?
    /// The owner's controls pressed and not yet released.
    private var held: Set<UInt16> = []
    /// The newest event time seen: the time of releases the arbiter makes itself.
    private var lastTime = 0.0
    private var watchingNow: Set<UInt16> = []
    public private(set) var wanted = MouseState.released
    private var place: PointerPlace?
    /// The client whose declared window is under the pointer: it hears the wheel's state.
    private var wheelReceiver: ClientID?
    /// The wheel's state as the mouse last reported it.
    private var wheel: (highResolution: Bool, mode: WheelMode?) = (false, nil)
    /// The mode wanted where no client's wish reaches: ratchet until the settings or a SmartShift press say another.
    public private(set) var globalMode = WheelMode.ratchet
    /// Where the mode wanted came from.
    private enum ModeSource: Equatable { case global, client(ClientID, WheelMode) }
    /// The source under which the user last pressed SmartShift. `LogiHIDPP` took the press as the mouse's wanted mode,
    /// so the arbiter's `wanted` and the mouse differ until the source changes: then the state is applied once more
    /// even if it equals `wanted`. Moves inside the same area apply nothing and leave the press in force.
    private var pressSource: ModeSource?

    public init() {}

    /// Whether some client declared wheel areas: only then does the service follow the pointer.
    public var followsPointer: Bool { clients.values.contains { !$0.want.wheel.isEmpty } }

    /// The window under the pointer moved or changed; nil: no window, or none of a client.
    public mutating func pointer(_ place: PointerPlace?) -> [Effect] {
        guard place != self.place else { return [] }
        self.place = place
        return update()
    }

    /// The mouse reported its wheel: to the client under the pointer. A press of the button where no client's wish sets
    /// the mode is the user's choice of the global mode.
    public mutating func wheelState(highResolution: Bool, mode: WheelMode?, byButton: Bool) -> [Effect] {
        wheel = (highResolution, mode)
        var effects: [Effect] = []
        if byButton {
            let source = modeSource()
            pressSource = source
            if source == .global, let mode, mode != globalMode {
                globalMode = mode
                effects.append(.globalMode(mode))
                effects += update()
            }
        }
        if let wheelReceiver {
            effects.append(.send(wheelReceiver, .wheel(highResolution: highResolution, mode: mode, byButton: byButton)))
        }
        return effects
    }

    /// The global mode from the settings (or the saved one at launch).
    public mutating func setGlobalMode(_ mode: WheelMode) -> [Effect] {
        guard mode != globalMode else { return [] }
        globalMode = mode
        return update()
    }

    /// The first state, so the global mode is on the mouse before any client or app switch.
    public mutating func start() -> [Effect] { update() }

    public mutating func connect(_ id: ClientID, pid: pid_t) -> [Effect] {
        clients[id] = Client(pid: pid)
        return update()
    }

    public mutating func disconnect(_ id: ClientID) -> [Effect] {
        clients[id] = nil
        return update()
    }

    public mutating func want(_ id: ClientID, _ want: Want) -> [Effect] {
        guard clients[id] != nil, clients[id]?.want != want else { return [] }
        clients[id]?.want = want
        return update()
    }

    public mutating func frontmost(pid: pid_t?) -> [Effect] {
        frontmostPID = pid
        suspended = false
        return update()
    }

    public mutating func releaseAll() -> [Effect] {
        suspended = true
        return update()
    }

    public mutating func button(cid: UInt16, pressed: Bool, time: Double) -> [Effect] {
        lastTime = max(lastTime, time)
        guard let owner else { return [] }
        if pressed { held.insert(cid) } else { held.remove(cid) }
        return [.send(owner, .button(cid: cid, pressed: pressed, time: time))]
    }

    public mutating func thumbWheel(delta: Int, touching: Bool, phase: ThumbPhase, time: Double) -> [Effect] {
        lastTime = max(lastTime, time)
        guard let owner else { return [] }
        return [.send(owner, .thumbWheel(delta: delta, touching: touching, phase: phase, time: time))]
    }

    public mutating func watching(_ cids: Set<UInt16>) -> [Effect] {
        watchingNow = cids
        guard let owner else { return [] }
        return [.send(owner, .watching(cids))]
    }

    public mutating func play(_ id: ClientID, pattern: UInt8, strength: UInt8?) -> [Effect] {
        id == owner ? [.play(pattern: pattern, strength: strength)] : []
    }

    // MARK: Private

    private func ownerNow() -> ClientID? {
        guard !suspended, let frontmostPID else { return nil }
        return clients.filter { $0.value.pid == frontmostPID }.keys.min()
    }

    /// The state from the owner's wish and the wishes over the window under the pointer.
    func computeWanted() -> MouseState {
        var state = MouseState.released
        let (receiver, entries) = wheelEntries()
        if let owner, let want = clients[owner]?.want {
            state.divert = want.divert
            // SmartShift belongs to the wheel: a client that declares wheel areas takes it to set the wheel itself,
            // over those areas' window only; elsewhere the button switches the mouse's own mode.
            if !want.wheel.isEmpty, receiver != owner { state.divert.remove(Self.smartShift) }
            state.watch = want.watch
            state.thumbWheel = want.thumbWheel
        }
        state.mode = entries.lazy.compactMap(\.mode).first ?? globalMode
        state.highResolution = entries.lazy.compactMap(\.highResolution).first ?? false
        return state
    }

    private func modeSource() -> ModeSource {
        let (receiver, entries) = wheelEntries()
        guard let receiver, let mode = entries.lazy.compactMap(\.mode).first else { return .global }
        return .client(receiver, mode)
    }

    /// The client whose window is under the pointer and its entries that cover the point, in its order. A rect holds
    /// its min edges and not its max ones.
    private func wheelEntries() -> (ClientID?, [WheelWish]) {
        guard let place else { return (nil, []) }
        let matches = clients.filter { $0.value.pid == place.pid && $0.value.want.wheel.contains { $0.window == place.window } }
        guard let id = matches.keys.min(), let want = clients[id]?.want else { return (nil, []) }
        let p = place.point
        let entries = want.wheel.filter { wish in
            wish.window == place.window && (wish.rects.map { rects in
                rects.contains { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }
            } ?? true)
        }
        return (id, entries)
    }

    /// The owner change in one step (core spec, rule 3), then the mouse's state if it changed.
    mutating func update() -> [Effect] {
        var effects: [Effect] = []
        let newOwner = ownerNow()
        let ownerChanged = newOwner != owner
        if ownerChanged {
            if let old = owner, clients[old] != nil {
                for cid in held.sorted() {
                    effects.append(.send(old, .button(cid: cid, pressed: false, time: lastTime)))
                }
                // Its side buttons are the system's again: nothing is heard for it any more.
                effects.append(.send(old, .watching([])))
                effects.append(.send(old, .owner(false)))
            }
            held = []
            owner = newOwner
        }
        let state = computeWanted()
        let source = modeSource()
        let pressUndone = pressSource.map { $0 != source } ?? false
        if pressUndone { pressSource = nil }
        if state != wanted || pressUndone {
            wanted = state
            effects.append(.apply(state))
        }
        if ownerChanged, let owner {
            effects.append(.send(owner, .owner(true)))
            effects.append(.send(owner, .watching(watchingNow)))
        }
        let receiver = wheelEntries().0
        if receiver != wheelReceiver {
            wheelReceiver = receiver
            if let receiver {
                effects.append(.send(receiver, .wheel(highResolution: wheel.highResolution, mode: wheel.mode, byButton: false)))
            }
        }
        return effects
    }
}
