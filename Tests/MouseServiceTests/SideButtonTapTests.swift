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
