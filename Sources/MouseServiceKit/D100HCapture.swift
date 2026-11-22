import MouseContract

/// A capture lasts until the firmware has returned to its original assignments.
/// Capture sessions and configuration revisions discard replies from a previous owner.
struct D100HCapture {
    enum Action: Equatable {
        case capture(UInt64)
        case release(restored: Bool)
        case configure(Bool, revision: Int)
    }

    private var readerAvailable = false
    private var wanted: UInt64?
    private var commanded: UInt64?
    private var captured: UInt64?
    private var failed: UInt64?
    private var wantsMapping = false
    private var readySince: Double?
    private var pressed: Set<D100HButton> = []
    private var restoring = false
    private var restored = true
    private var revision = 0
    var hasCaptureCommand: Bool { commanded != nil }
    var restorationVerified: Bool { restored }
    var restorationInProgress: Bool { restoring }

    mutating func update(wanted: UInt64?, readerAvailable: Bool) -> [Action] {
        self.wanted = wanted
        self.readerAvailable = readerAvailable
        if !readerAvailable {
            commanded = nil
            captured = nil
        }
        return reconcile()
    }

    mutating func readerReported(session: UInt64, open: Bool) -> [Action] {
        guard session == commanded else { return [] }
        captured = open ? session : nil
        return reconcile()
    }

    mutating func configurationFinished(revision: Int, success: Bool, time: Double) -> [Action] {
        guard revision == self.revision else { return [] }
        if wantsMapping {
            readySince = success ? time : nil
            if !success { failed = wanted }
        } else {
            restoring = false
            restored = success
            if !success { failed = wanted }
        }
        return reconcile()
    }

    func accepts(_ session: UInt64) -> Bool {
        readySince != nil && wanted == session && captured == session
    }

    mutating func acceptsInput(_ input: D100HInput, session: UInt64, time: Double) -> Bool {
        // The helper stamps reports on the same host before sending them over XPC.
        guard accepts(session), let readySince, time >= readySince else { return false }
        switch input {
        case let .button(button, true): return pressed.insert(button).inserted
        case let .button(button, false): return pressed.remove(button) != nil
        case .cancelled: pressed.removeAll()
        case .turn: break
        }
        return true
    }

    private mutating func reconcile() -> [Action] {
        var actions: [Action] = []
        let demand = readerAvailable && wanted != failed ? wanted : nil
        let configure = !restoring && demand != nil && demand == captured
        if configure != wantsMapping {
            wantsMapping = configure
            readySince = nil
            pressed.removeAll()
            restoring = !configure
            if configure { restored = false }
            revision += 1
            actions.append(.configure(configure, revision: revision))
        }
        guard !restoring else { return actions }
        if let demand, demand != commanded {
            commanded = demand
            captured = nil
            actions.append(.capture(demand))
        } else if demand == nil, commanded != nil {
            commanded = nil
            captured = nil
            actions.append(.release(restored: restored))
        }
        return actions
    }
}
