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
    /// nil: the mouse's own mode.
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

public enum Effect: Equatable, Sendable {
    case send(ClientID, ServiceMessage)
    /// The whole new state, emitted only when it changed.
    case apply(MouseState)
    case play(pattern: UInt8, strength: UInt8?)
}

/// Who owns the mouse and what it should be (core spec, "Arbitration and data flow"): pure, every input an event,
/// every output an `Effect`. The owner of buttons, haptics and the thumb wheel is the frontmost app if it is a client;
/// an owner change releases every control it holds before it is told, and the new owner is told after the mouse has
/// its wishes.
public struct Arbiter: Sendable {
    struct Client: Sendable {
        let pid: pid_t
        var want = Want.none
    }

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

    public init() {}

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

    /// The state from the owner's wish (and, below, the wheel's).
    func computeWanted() -> MouseState {
        var state = MouseState.released
        if let owner, let want = clients[owner]?.want {
            state.divert = want.divert
            state.watch = want.watch
            state.thumbWheel = want.thumbWheel
        }
        return state
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
                effects.append(.send(old, .owner(false)))
            }
            held = []
            owner = newOwner
        }
        let state = computeWanted()
        if state != wanted {
            wanted = state
            effects.append(.apply(state))
        }
        if ownerChanged, let owner {
            effects.append(.send(owner, .owner(true)))
            effects.append(.send(owner, .watching(watchingNow)))
        }
        return effects
    }
}
