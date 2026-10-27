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
    #expect(a.wanted.mode == nil)
}

@Test func areaBorder() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, rects: [area], mode: .ratchet)])])
    _ = a.pointer(place(1, window: 7, 0, 0))
    #expect(a.wanted.mode == .ratchet)
    _ = a.pointer(place(1, window: 7, 100, 10))
    #expect(a.wanted.mode == nil)
    _ = a.pointer(place(1, window: 7, 99.9, 49.9))
    #expect(a.wanted.mode == .ratchet)
    _ = a.pointer(place(1, window: 7, 10, 50))
    #expect(a.wanted.mode == nil)
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
    #expect(a.wanted.mode == nil)
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
    #expect(a.wheelState(highResolution: false, mode: .freeSpin, byButton: true) == [])
}

@Test func clientGoneGivesModeBack() {
    var a = arbiter([1: Want(wheel: [WheelWish(window: 7, rects: [area], highResolution: true, mode: .freeSpin)])])
    _ = a.pointer(place(1, window: 7))
    #expect(a.wanted == MouseState(highResolution: true, mode: .freeSpin))
    #expect(a.disconnect(id(1)) == [.apply(.released)])
}

@Test func newWishUnderPointerApplies() {
    var a = arbiter([1: .none])
    _ = a.pointer(place(1, window: 7))
    #expect(a.want(id(1), Want(wheel: [WheelWish(window: 7, mode: .ratchet)])).contains(.apply(MouseState(mode: .ratchet))))
}
