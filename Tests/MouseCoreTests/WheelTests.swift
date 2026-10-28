import CoreGraphics
import Foundation
import Testing
@testable import MouseContract
@testable import MouseCore

private func place(_ n: Int, window: Int, _ x: Double = 10, _ y: Double = 10) -> PointerPlace {
    PointerPlace(window: window, pid: pid(n), point: CGPoint(x: x, y: y))
}

private let area = CGRect(x: 0, y: 0, width: 100, height: 50)

@Test func modeOverWholeWindow() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .freeSpin)])])
    #expect(a.pointer(place(1, window: 7)).contains(.apply(MouseState(mode: .freeSpin))))
    _ = a.pointer(place(1, window: 8))
    #expect(a.wanted.mode == .ratchet)
}

@Test func areaBorder() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, rects: [area], mode: .freeSpin)])])
    _ = a.pointer(place(1, window: 7, 0, 0))
    #expect(a.wanted.mode == .freeSpin)
    _ = a.pointer(place(1, window: 7, 100, 10))
    #expect(a.wanted.mode == .ratchet)
    _ = a.pointer(place(1, window: 7, 99.9, 49.9))
    #expect(a.wanted.mode == .freeSpin)
    _ = a.pointer(place(1, window: 7, 10, 50))
    #expect(a.wanted.mode == .ratchet)
}

@Test func fieldPrecedence() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .freeSpin),
                                     WheelWish(window: 7, rects: [area], highResolution: true)])])
    _ = a.pointer(place(1, window: 7, 10, 10))
    #expect(a.wanted == MouseState(highResolution: true, mode: .freeSpin))
    _ = a.pointer(place(1, window: 7, 10, 60))
    #expect(a.wanted == MouseState(highResolution: false, mode: .freeSpin))
}

@Test func otherPidSameWindowNumberIgnored() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .freeSpin)])])
    _ = a.pointer(PointerPlace(window: 7, pid: 999, point: .zero))
    #expect(a.wanted.mode == .ratchet)
}

@Test func followsPointerOnlyWithWishes() {
    var a = arbiter([1: .none])
    #expect(!a.followsPointer)
    _ = a.want(id(1), Want(wheel: [WheelWish(window: 7, mode: .ratchet)]))
    #expect(a.followsPointer)
    _ = a.disconnect(id(1))
    #expect(!a.followsPointer)
}

@Test func wheelWishAppliesWithoutOwnership() {
    var a = arbiter([1: .none, 2: Want(wheel: [WheelWish(window: 9, mode: .ratchet)])])
    _ = a.frontmost(pid: pid(1))
    _ = a.pointer(place(2, window: 9))
    #expect(a.wanted.mode == .ratchet)
    #expect(a.owner == id(1))
}

@Test func receiverGetsStateOnEntry() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .freeSpin)])])
    _ = a.wheelState(highResolution: true, mode: .ratchet, byButton: false)   // nobody under the pointer yet
    let effects = a.pointer(place(1, window: 7))
    #expect(effects.contains(.send(id(1), .wheel(highResolution: true, mode: .ratchet, byButton: false))))
    #expect(!a.pointer(place(1, window: 7, 20, 20)).contains { if case .send = $0 { true } else { false } })
}

@Test func byButtonGoesToReceiver() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .freeSpin)]),
                     2: Want(wheel: [WheelWish(window: 8, mode: .freeSpin)])])
    _ = a.frontmost(pid: pid(2))
    _ = a.pointer(place(1, window: 7))
    #expect(a.wheelState(highResolution: false, mode: .ratchet, byButton: true)
        == [.send(id(1), .wheel(highResolution: false, mode: .ratchet, byButton: true))])
    _ = a.pointer(nil)
    // Nobody's wish under the pointer: the press is the user's choice of the global mode, and no client hears it.
    #expect(a.wheelState(highResolution: false, mode: .freeSpin, byButton: true)
        == [.globalMode(.freeSpin), .apply(MouseState(mode: .freeSpin))])
}

@Test func clientGoneGivesModeBack() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, rects: [area], highResolution: true, mode: .freeSpin)])])
    _ = a.pointer(place(1, window: 7))
    #expect(a.wanted == MouseState(highResolution: true, mode: .freeSpin))
    #expect(a.disconnect(id(1)) == [.apply(idle)])
}

@Test func newWishUnderPointerApplies() {
    var a = arbiter([1: .none])
    _ = a.pointer(place(1, window: 7))
    #expect(a.want(id(1), Want(wheel: [WheelWish(window: 7, mode: .freeSpin)])).contains(.apply(MouseState(mode: .freeSpin))))
}

@Test func smartShiftFollowsTheOwnersWheelWindow() {
    // A client with wheel areas takes SmartShift to set the wheel itself: over its own window only, so elsewhere the
    // button switches the mouse's own mode as usual.
    let smartShift: UInt16 = 0xC4, gesture: UInt16 = 0xC3
    var a = arbiter([1: Want(divert: [smartShift, gesture], wheel: [WheelWish(window: 7, mode: .freeSpin)]),
                     2: .none])
    _ = a.frontmost(pid: pid(1))
    _ = a.pointer(place(1, window: 7))
    #expect(a.wanted.divert == [smartShift, gesture])
    _ = a.pointer(place(2, window: 9))
    #expect(a.wanted.divert == [gesture])
    _ = a.pointer(nil)
    #expect(a.wanted.divert == [gesture])
}

@Test func smartShiftWithoutWheelAreasIsAPlainButton() {
    let smartShift: UInt16 = 0xC4
    var a = arbiter([1: Want(divert: [smartShift])])
    _ = a.frontmost(pid: pid(1))
    #expect(a.wanted.divert == [smartShift])
}

// MARK: Global mode (docs/superpowers/specs/2026-10-28-global-wheel-mode-design.md)

private func applies(_ effects: [Effect]) -> [MouseState] {
    effects.compactMap { if case let .apply(state) = $0 { state } else { nil } }
}

@Test func ratchetIsTheDefaultFromTheStart() {
    var a = Arbiter()
    #expect(a.globalMode == .ratchet)
    #expect(a.start() == [.apply(MouseState(mode: .ratchet))])
}

@Test func globalModeHoldsWhereNoWishReaches() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, rects: [area], mode: .freeSpin)])])
    _ = a.setGlobalMode(.freeSpin)
    _ = a.pointer(place(1, window: 7, 10, 10))
    #expect(a.wanted.mode == .freeSpin)
    _ = a.setGlobalMode(.ratchet)
    #expect(a.wanted.mode == .freeSpin)   // the wish wins over its area
    #expect(applies(a.pointer(place(1, window: 7, 10, 60))).last?.mode == .ratchet)
}

@Test func settingTheGlobalModeAppliesAtOnceElsewhere() {
    var a = arbiter([1: .none])
    #expect(a.setGlobalMode(.freeSpin) == [.apply(MouseState(mode: .freeSpin))])
    #expect(a.setGlobalMode(.freeSpin) == [])
}

@Test func pressWithoutAClientAdoptsTheGlobalMode() {
    var a = arbiter([1: .none])
    _ = a.start()
    let effects = a.wheelState(highResolution: false, mode: .freeSpin, byButton: true)
    #expect(effects.contains(.globalMode(.freeSpin)))
    #expect(a.globalMode == .freeSpin)
    #expect(a.wanted.mode == .freeSpin)
    // The same press again changes nothing to save.
    #expect(!a.wheelState(highResolution: false, mode: .freeSpin, byButton: true).contains(.globalMode(.freeSpin)))
}

@Test func readNotByButtonIsNotAdopted() {
    var a = arbiter([1: .none])
    _ = a.wheelState(highResolution: false, mode: .freeSpin, byButton: false)
    #expect(a.globalMode == .ratchet)
}

@Test func pressOverAHiResOnlyAreaSetsTheGlobalModeAndTheClientHearsIt() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, highResolution: true)])])
    _ = a.pointer(place(1, window: 7))
    let effects = a.wheelState(highResolution: true, mode: .freeSpin, byButton: true)
    #expect(effects.contains(.globalMode(.freeSpin)))
    #expect(effects.contains(.send(id(1), .wheel(highResolution: true, mode: .freeSpin, byButton: true))))
}

@Test func pressOverAModeWishLeavesTheGlobalModeAlone() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .freeSpin)])])
    _ = a.pointer(place(1, window: 7))
    let effects = a.wheelState(highResolution: false, mode: .ratchet, byButton: true)
    #expect(effects == [.send(id(1), .wheel(highResolution: false, mode: .ratchet, byButton: true))])
    #expect(a.globalMode == .ratchet)
}

@Test func movesInsideTheAreaDoNotUndoThePress() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .freeSpin)])])
    _ = a.pointer(place(1, window: 7))
    _ = a.wheelState(highResolution: false, mode: .ratchet, byButton: true)
    #expect(applies(a.pointer(place(1, window: 7, 20, 20))) == [])
    #expect(applies(a.pointer(place(1, window: 7, 30, 20))) == [])
}

@Test func leavingTheAreaAppliesTheGlobalModeEvenWhenItEqualsTheWish() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, rects: [area], mode: .ratchet)])])
    _ = a.pointer(place(1, window: 7))
    #expect(a.wanted.mode == .ratchet)   // the wish equals the global mode
    _ = a.wheelState(highResolution: false, mode: .freeSpin, byButton: true)   // the user freed the wheel
    #expect(applies(a.pointer(place(1, window: 7, 10, 20))) == [])
    #expect(applies(a.pointer(place(1, window: 7, 10, 60))) == [MouseState(mode: .ratchet)])
}

@Test func theClientGoingAppliesTheGlobalModeAfterAPress() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, mode: .ratchet)])])
    _ = a.pointer(place(1, window: 7))
    _ = a.wheelState(highResolution: false, mode: .freeSpin, byButton: true)
    #expect(applies(a.disconnect(id(1))) == [MouseState(mode: .ratchet)])
}

@Test func theGlobalModeSetDuringAWishApplicationWaitsForTheExit() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, rects: [area], mode: .freeSpin)])])
    _ = a.pointer(place(1, window: 7))
    #expect(a.setGlobalMode(.freeSpin) == [])
    #expect(applies(a.pointer(place(1, window: 7, 10, 60))) == [])   // already freeSpin: nothing to write
    #expect(a.wanted.mode == .freeSpin)
}

@Test func tenChangesGiveTenApplies() {
    var a = arbiter([1: .none])
    var count = 0
    for i in 0..<10 { count += applies(a.setGlobalMode(i.isMultiple(of: 2) ? .freeSpin : .ratchet)).count }
    #expect(count == 10)
}
