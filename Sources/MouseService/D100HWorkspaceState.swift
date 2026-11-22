struct D100HWorkspaceState {
    enum Event {
        case sleep, wake, sessionInactive, sessionActive, screenUnlocked
    }

    private var awake = true
    private var consoleActive = true
    var isActive: Bool { awake && consoleActive }

    mutating func handle(_ event: Event) {
        switch event {
        case .sleep: awake = false
        case .wake: awake = true
        case .sessionInactive: consoleActive = false
        case .sessionActive: consoleActive = true
        case .screenUnlocked:
            // Interactive unlock can arrive before NSWorkspace reports wake.
            awake = true
        }
    }
}
