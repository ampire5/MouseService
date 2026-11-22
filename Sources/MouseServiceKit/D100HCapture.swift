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
    private var ready = false
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

    mutating func configurationFinished(revision: Int, success: Bool) -> [Action] {
        guard revision == self.revision else { return [] }
        if wantsMapping {
            ready = success
            if !success { failed = wanted }
        } else {
            restoring = false
            restored = success
            if !success { failed = wanted }
        }
        return reconcile()
    }

    func accepts(_ session: UInt64) -> Bool {
        ready && wanted == session && captured == session
    }

    private mutating func reconcile() -> [Action] {
        var actions: [Action] = []
        let demand = readerAvailable && wanted != failed ? wanted : nil
        let configure = !restoring && demand != nil && demand == captured
        if configure != wantsMapping {
            wantsMapping = configure
            ready = false
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
