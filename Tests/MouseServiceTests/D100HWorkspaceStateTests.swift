import Testing
@testable import MouseService

@Test func d100hResumesWhenUnlockArrivesBeforeWorkspaceWake() {
    var state = D100HWorkspaceState()
    state.handle(.sleep)
    #expect(!state.isActive)

    state.handle(.screenUnlocked)
    #expect(state.isActive)

    state.handle(.wake)
    #expect(state.isActive)
}

@Test func d100hUnlockDoesNotResumeAnInactiveConsoleSession() {
    var state = D100HWorkspaceState()
    state.handle(.sessionInactive)
    state.handle(.sleep)
    state.handle(.screenUnlocked)
    #expect(!state.isActive)

    state.handle(.sessionActive)
    #expect(state.isActive)
}

@Test func d100hWakeStillResumesIfUnlockNotificationIsMissing() {
    var state = D100HWorkspaceState()
    state.handle(.sleep)
    #expect(!state.isActive)

    state.handle(.wake)
    #expect(state.isActive)
}
