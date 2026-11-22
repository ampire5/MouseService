import MouseContract
import Testing
@testable import d100h_hid

@Test func allThreeTopButtonsHavePressAndRelease() {
    var decoder = ReportDecoder()
    for (usage, button): (UInt16, D100HButton) in [(0xb6, .topLeft), (0xcd, .topMiddle), (0xb5, .topRight)] {
        #expect(decoder.consumer(usage) == .button(button, pressed: true))
        #expect(decoder.consumer(usage) == nil)
        #expect(decoder.consumer(0) == .button(button, pressed: false))
        #expect(decoder.consumer(0) == nil)
    }
}

@Test func dialNotchesPreserveAHeldButton() {
    var decoder = ReportDecoder()
    #expect(decoder.consumer(0xcd) == .button(.topMiddle, pressed: true))
    #expect(decoder.consumer(0xe9) == .turn(.right, knobPressed: false))
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0xea) == .turn(.left, knobPressed: false))
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0) == .button(.topMiddle, pressed: false))
}

@Test func lowerButtonReleaseFollowsTheKeyAcrossCommandRelease() {
    var decoder = ReportDecoder()
    #expect(decoder.keyboard(modifiers: 0x08, keys: [0]) == [])
    #expect(decoder.keyboard(modifiers: 0x08, keys: [0x06]) == [.button(.bottomLeft, pressed: true)])
    #expect(decoder.keyboard(modifiers: 0, keys: [0x06]) == [])
    #expect(decoder.keyboard(modifiers: 0, keys: [0]) == [.button(.bottomLeft, pressed: false)])
    #expect(decoder.keyboard(modifiers: 0x08, keys: [0x1d]) == [.button(.bottomRight, pressed: true)])
    #expect(decoder.keyboard(modifiers: 0, keys: [0]) == [.button(.bottomRight, pressed: false)])
}

@Test func upperSideButtonsAreDistinctFromTheUpperRowAndLowerModifiers() {
    var decoder = ReportDecoder()
    #expect(decoder.keyboard(modifiers: 0x08, keys: [0x19]) == [.button(.sideUpperLeft, pressed: true)])
    #expect(decoder.keyboard(modifiers: 0, keys: [0]) == [.button(.sideUpperLeft, pressed: false)])
    #expect(decoder.keyboard(modifiers: 0x0a, keys: [0x1d]) == [.button(.sideUpperRight, pressed: true)])
    #expect(decoder.keyboard(modifiers: 0x08, keys: [0x1d]) == [])
    #expect(decoder.keyboard(modifiers: 0, keys: [0]) == [.button(.sideUpperRight, pressed: false)])
}

@Test func measuredFourTurnMappingPreservesTheTopMiddleButton() {
    var decoder = ReportDecoder(fourTurnTest: true)
    #expect(decoder.consumer(0xea) == .turn(.left, knobPressed: false))
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0xe9) == .turn(.right, knobPressed: false))
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0x226) == .turn(.left, knobPressed: true))
    #expect(decoder.consumer(0x226) == nil)
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0x226) == .turn(.left, knobPressed: true))
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0x2a0) == .turn(.right, knobPressed: true))
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0xcd) == .button(.topMiddle, pressed: true))
    #expect(decoder.consumer(0xe9) == .turn(.right, knobPressed: false))
    #expect(decoder.consumer(0) == nil)
    #expect(decoder.consumer(0) == .button(.topMiddle, pressed: false))
}
