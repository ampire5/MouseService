import CoreGraphics
import GestureCore
import Testing
@testable import MouseService

@Test func macOS26EncodesDockSwipeInCoreGraphicsFields() throws {
    let synth = try #require(TouchSynth(operatingSystemMajorVersion: 26))
    var gesture = SideButtonGesture()
    _ = gesture.press(.back, at: 0)
    let began = try dockSwipe(in: gesture.drag(dx: 0, dy: -9))
    let ended = try dockSwipe(in: gesture.release(.back, at: 1))

    let beginEvents = synth.dockSwipeEvents(began)
    #expect(beginEvents.map(\.type.rawValue) == [30, 29])
    let begin = try #require(beginEvents.first)
    #expect(begin.getIntegerValueField(CGEventField(rawValue: 110)!) == 23)
    #expect(begin.getIntegerValueField(CGEventField(rawValue: 123)!) == 2)
    #expect(begin.getIntegerValueField(CGEventField(rawValue: 132)!) == 1)
    #expect(abs(begin.getDoubleValueField(CGEventField(rawValue: 124)!) - (-0.01)) < 1e-7)
    #expect(begin.getIntegerValueField(CGEventField(rawValue: 135)!) == Int64(Float(-0.01).bitPattern))

    let endEvents = synth.dockSwipeEvents(ended)
    #expect(endEvents.map(\.type.rawValue) == [30, 29])
    let end = try #require(endEvents.first)
    #expect(end.getIntegerValueField(CGEventField(rawValue: 132)!) == 4)
    #expect(abs(end.getDoubleValueField(CGEventField(rawValue: 129)!) - (-1)) < 1e-7)
}

@Test func macOS27EmitsOneDockSwipeEvent() throws {
    let synth = try #require(TouchSynth(operatingSystemMajorVersion: 27))
    var gesture = SideButtonGesture()
    _ = gesture.press(.back, at: 0)
    let began = try dockSwipe(in: gesture.drag(dx: 10, dy: 0))

    #expect(synth.dockSwipeEvents(began).map(\.type.rawValue) == [30])
}

private func dockSwipe(in outputs: [SideButtonGesture.Output]) throws -> SideButtonGesture.DockSwipe {
    let swipes = outputs.compactMap { output -> SideButtonGesture.DockSwipe? in
        guard case let .dockSwipe(swipe) = output else { return nil }
        return swipe
    }
    return try #require(swipes.first)
}
