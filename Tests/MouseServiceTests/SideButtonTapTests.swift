import CoreGraphics
import GestureCore
import Testing
@testable import MouseService

private func mouseEvent(_ type: CGEventType, button: Int64 = 0, dy: Int64 = 0) throws -> CGEvent {
    let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                                     mouseButton: .center))
    event.setIntegerValueField(.mouseEventButtonNumber, value: button)
    event.setIntegerValueField(.mouseEventDeltaY, value: dy)
    return event
}

@Test(arguments: [CGEventType.mouseMoved, .otherMouseDragged])
func sideButtonSwipeTracksPointerMovement(kind: CGEventType) throws {
    var gesture = SideButtonGesture()
    let movement = try mouseEvent(kind, button: kind == .mouseMoved ? 0 : 3, dy: -4)
    let down = try mouseEvent(.otherMouseDown, button: 3)
    let up = try mouseEvent(.otherMouseUp, button: 3)

    #expect(SideButtonTap.eventMask & (1 << kind.rawValue) != 0)
    #expect(SideButtonTap.route(.otherMouseDown, down, at: 0, gesture: &gesture) == [])
    let firstMove = SideButtonTap.route(kind, movement, at: 0.1, gesture: &gesture)
    #expect(firstMove == (kind == .mouseMoved ? nil : []))
    let outputs = SideButtonTap.route(kind, movement, at: 0.2, gesture: &gesture)
    #expect(outputs?.first == .freezePointer(true))
    guard let outputs, case let .dockSwipe(began)? = outputs.last else {
        Issue.record("Holding Back while moving did not begin a swipe")
        return
    }
    #expect(began.axis == .vertical)
    #expect(began.phase == .began)
    #expect(began.progress > 0)
    #expect(SideButtonTap.route(.otherMouseUp, up, at: 0.25, gesture: &gesture)?.last == .freezePointer(false))
    let ordinaryMovement = try mouseEvent(.mouseMoved, dy: -40)
    #expect(SideButtonTap.route(.mouseMoved, ordinaryMovement, at: 0.4, gesture: &gesture) == nil)
}

@Test func ordinaryMovementPassesThroughBeforeAndAfterAForwardClick() throws {
    var gesture = SideButtonGesture()
    let movement = try mouseEvent(.mouseMoved, dy: -40)
    let down = try mouseEvent(.otherMouseDown, button: 4)
    let up = try mouseEvent(.otherMouseUp, button: 4)

    #expect(SideButtonTap.route(.mouseMoved, movement, at: 0, gesture: &gesture) == nil)
    #expect(SideButtonTap.route(.otherMouseDown, down, at: 0.1, gesture: &gesture) == [])
    #expect(SideButtonTap.route(.mouseMoved, movement, at: 0.15, gesture: &gesture) == nil)
    #expect(SideButtonTap.route(.otherMouseUp, up, at: 0.2, gesture: &gesture) == [.pageSwipe(.forward)])
}

@Test(arguments: [Int64(3), 4])
func clientGetsOriginalMouseClick(button: Int64) throws {
    let input = SideButtonTap.Input()
    let down = try mouseEvent(.otherMouseDown, button: button)
    let up = try mouseEvent(.otherMouseUp, button: button)
    down.flags = .maskShift
    down.setIntegerValueField(.mouseEventClickState, value: 2)
    _ = input.receive(.otherMouseDown, down, at: 0) { 42 }
    guard case let .nativeClick(replayedDown)? = input.receive(.otherMouseUp, up, at: 0.1, clientTarget: { 42 }) else {
        Issue.record("Client click was converted to a trackpad swipe")
        return
    }
    #expect(replayedDown.type == .otherMouseDown)
    #expect(replayedDown.getIntegerValueField(.mouseEventButtonNumber) == button)
    #expect(replayedDown.getIntegerValueField(.mouseEventClickState) == 2)
    #expect(replayedDown.flags.contains(.maskShift))
}

@Test func sideClickUsesTheActualTargetWhenPresent() {
    var targets = SideButtonTap.ClickTargets(frontmost: 42, clients: [42, 43])
    #expect(targets.clientTarget(eventPID: 0) == 42)
    #expect(targets.clientTarget(eventPID: 43) == 43)
    targets.clients.remove(43)
    #expect(targets.clientTarget(eventPID: 43) == nil)
}

@Test func nativeClickDoesNotReplayAPressIntoAnotherApp() throws {
    let input = SideButtonTap.Input()
    let down = try mouseEvent(.otherMouseDown, button: 3)
    let up = try mouseEvent(.otherMouseUp, button: 3)
    _ = input.receive(.otherMouseDown, down, at: 0) { 42 }
    guard case let .gesture(outputs)? = input.receive(.otherMouseUp, up, at: 0.1, clientTarget: { 43 }) else {
        Issue.record("The mouse press should stay with its original app")
        return
    }
    #expect(outputs == [.pageSwipe(.back)])
}

@Test func clientDragEndsWithoutSendingAClick() throws {
    let input = SideButtonTap.Input()
    let down = try mouseEvent(.otherMouseDown, button: 3)
    let movement = try mouseEvent(.mouseMoved, dy: -40)
    let up = try mouseEvent(.otherMouseUp, button: 3)
    _ = input.receive(.otherMouseDown, down, at: 0) { 42 }
    guard case let .gesture(began)? = input.receive(.mouseMoved, movement, at: 0.1, clientTarget: { 42 }),
          case let .gesture(ended)? = input.receive(.otherMouseUp, up, at: 0.2, clientTarget: { 42 }) else {
        Issue.record("Holding Back and moving should produce a gesture instead of a click")
        return
    }
    #expect(began.first == .freezePointer(true))
    #expect(ended.last == .freezePointer(false))
    #expect(!ended.contains(.pageSwipe(.back)))
}

@Test func dragOnlyLeavesOtherButtonNativeAndReplaysTheGestureButtonClick() throws {
    let input = SideButtonTap.Input()
    let config = SideButtonTap.Preferences(pageSwipes: false, dragButton: .forward, threshold: 10)
    let back = try mouseEvent(.otherMouseDown, button: 3)
    let forward = try mouseEvent(.otherMouseDown, button: 4)
    let release = try mouseEvent(.otherMouseUp, button: 4)
    let move = try mouseEvent(.mouseMoved, dy: -7)
    #expect(input.receive(.otherMouseDown, back, at: 0, preferences: { config }) { nil } == nil)
    _ = input.receive(.otherMouseDown, forward, at: 1, preferences: { config }) { nil }
    #expect(input.receive(.mouseMoved, move, at: 1.1, preferences: { config }) { nil } == nil)
    guard case .nativeClick? = input.receive(.otherMouseUp, release, at: 1.5, preferences: { config }, clientTarget: { nil }) else {
        Issue.record("The gesture button should deliver a mouse click when page-swipe conversion is off")
        return
    }
    _ = input.receive(.otherMouseDown, forward, at: 2, preferences: { config }) { nil }
    #expect(input.receive(.mouseMoved, move, at: 2.1, preferences: { config }) { nil } == nil)
    guard case let .gesture(began)? = input.receive(.mouseMoved, move, at: 2.2, preferences: { config }, clientTarget: { nil }),
          case let .gesture(ended)? = input.receive(.otherMouseUp, release, at: 2.3, preferences: { config }, clientTarget: { nil }) else {
        Issue.record("Dragging with Forward should start and finish a swipe")
        return
    }
    #expect(began.first == .freezePointer(true))
    #expect(ended.last == .freezePointer(false))
}

@Test func pageSwipesStillWorkWithDragDisabled() throws {
    let input = SideButtonTap.Input()
    let config = SideButtonTap.Preferences(pageSwipes: true, dragButton: nil)
    let down = try mouseEvent(.otherMouseDown, button: 3)
    let movement = try mouseEvent(.mouseMoved, dy: -40)
    let up = try mouseEvent(.otherMouseUp, button: 3)
    _ = input.receive(.otherMouseDown, down, at: 0, preferences: { config }) { nil }
    #expect(input.receive(.mouseMoved, movement, at: 0.1, preferences: { config }) { nil } == nil)
    guard case let .gesture(outputs)? = input.receive(.otherMouseUp, up, at: 0.2, preferences: { config }, clientTarget: { nil }) else {
        Issue.record("A click should still produce a page swipe")
        return
    }
    #expect(outputs == [.pageSwipe(.back)])
}

@Test func dragOnlyDoesNotReplayAClickAfterTheTargetChanges() throws {
    let input = SideButtonTap.Input()
    let config = SideButtonTap.Preferences(pageSwipes: false)
    let down = try mouseEvent(.otherMouseDown, button: 3)
    let up = try mouseEvent(.otherMouseUp, button: 3)
    _ = input.receive(.otherMouseDown, down, at: 0, preferences: { config }, eventTarget: { 42 }) { nil }
    guard case let .gesture(outputs)? = input.receive(.otherMouseUp, up, at: 1, preferences: { config },
                                                       eventTarget: { 43 }, clientTarget: { nil }) else {
        Issue.record("A native click should not be posted across apps")
        return
    }
    #expect(outputs.isEmpty)
}

@Test func gestureDiagnosticsSeparatesRecognitionFromPosting() throws {
    let diagnostics = GestureDiagnostics()
    diagnostics.press(.back)
    #expect(diagnostics.snapshot == nil)
    diagnostics.start()
    diagnostics.press(.forward)
    diagnostics.dock(phase: .began, sent: false)
    let recognized = try #require(diagnostics.snapshot)
    #expect(recognized.button == .forward)
    #expect(recognized.dockSwipeRecognized)
    #expect(!recognized.dockEventSent)
    diagnostics.release(.forward)
    diagnostics.dock(phase: .ended, sent: true)
    let ended = try #require(diagnostics.snapshot)
    #expect(ended.released)
    #expect(ended.dockEventSent)
    diagnostics.stop()
    #expect(diagnostics.snapshot == nil)
}
