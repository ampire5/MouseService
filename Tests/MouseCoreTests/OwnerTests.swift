import Foundation
import Testing
@testable import MouseContract
@testable import MouseCore

/// What the arbiter wants with nothing taken: the global mode alone.
let idle = MouseState(mode: .ratchet)

func id(_ n: Int) -> ClientID { ClientID(raw: n) }
func pid(_ n: Int) -> pid_t { pid_t(100 + n) }

/// An arbiter with clients `ns` connected, each with its `want`.
func arbiter(_ wants: [Int: Want]) -> Arbiter {
    var a = Arbiter()
    for (n, want) in wants.sorted(by: { $0.key < $1.key }) {
        _ = a.connect(id(n), pid: pid(n))
        _ = a.want(id(n), want)
    }
    return a
}

private let gesture: UInt16 = 0xC3
private let back: UInt16 = 0x53

@Test func frontmostClientOwns() {
    var a = arbiter([1: Want(divert: [gesture])])
    let effects = a.frontmost(pid: pid(1))
    #expect(effects.contains(.apply(MouseState(divert: [gesture], mode: .ratchet))))
    #expect(effects.contains(.send(id(1), .owner(true))))
    #expect(a.owner == id(1))
}

@Test func nonClientFrontmostMeansNoOwner() {
    var a = arbiter([1: Want(divert: [gesture])])
    _ = a.frontmost(pid: pid(1))
    _ = a.frontmost(pid: 999)
    #expect(a.owner == nil)
    #expect(a.wanted == idle)
}

@Test func buttonsGoToOwnerOnly() {
    var a = arbiter([1: Want(divert: [gesture]), 2: Want(divert: [gesture])])
    _ = a.frontmost(pid: pid(1))
    #expect(a.button(cid: gesture, pressed: true, time: 5) == [.send(id(1), .button(cid: gesture, pressed: true, time: 5))])
}

@Test func ownerChangeReleasesHeld() {
    var a = arbiter([1: Want(divert: [gesture, back]), 2: Want(divert: [gesture])])
    _ = a.frontmost(pid: pid(1))
    _ = a.button(cid: gesture, pressed: true, time: 5)
    _ = a.button(cid: back, pressed: true, time: 6)
    #expect(a.frontmost(pid: pid(2)) == [
        .send(id(1), .button(cid: back, pressed: false, time: 6)),
        .send(id(1), .button(cid: gesture, pressed: false, time: 6)),
        .send(id(1), .watching([])),
        .send(id(1), .owner(false)),
        .apply(MouseState(divert: [gesture], mode: .ratchet)),
        .send(id(2), .owner(true)),
        .send(id(2), .watching([])),
    ])
}

@Test func disconnectWhileHolding() {
    var a = arbiter([1: Want(divert: [gesture])])
    _ = a.frontmost(pid: pid(1))
    _ = a.button(cid: gesture, pressed: true, time: 5)
    #expect(a.disconnect(id(1)) == [.apply(idle)])
    #expect(a.owner == nil)
    #expect(a.button(cid: gesture, pressed: false, time: 6) == [])
}

@Test func tenSwitches() {
    let want1 = Want(divert: [gesture]), want2 = Want(divert: [back], thumbWheel: true)
    var a = arbiter([1: want1, 2: want2])
    var all: [Effect] = []
    for i in 0..<10 { all += a.frontmost(pid: pid(i % 2 == 0 ? 1 : 2)) }
    #expect(a.wanted == MouseState(divert: [back], thumbWheel: true, mode: .ratchet))
    #expect(a.owner == id(2))
    var owner: ClientID?
    for case let .send(to, .owner(on)) in all {
        if on {
            #expect(owner == nil)   // the previous owner was told first
            owner = to
        } else {
            #expect(owner == to)
            owner = nil
        }
    }
    #expect(owner == id(2))
}

@Test func wantFromNonOwnerDoesNotApply() {
    var a = arbiter([1: Want(divert: [gesture]), 2: .none])
    _ = a.frontmost(pid: pid(1))
    #expect(!a.want(id(2), Want(divert: [back])).contains { if case .apply = $0 { true } else { false } })
}

@Test func repeatWantIsSilent() {
    var a = arbiter([1: Want(divert: [gesture])])
    _ = a.frontmost(pid: pid(1))
    #expect(a.want(id(1), Want(divert: [gesture])) == [])
}

@Test func playOnlyForOwner() {
    var a = arbiter([1: .none, 2: .none])
    _ = a.frontmost(pid: pid(1))
    #expect(a.play(id(1), pattern: 5, strength: nil) == [.play(pattern: 5, strength: nil)])
    #expect(a.play(id(2), pattern: 5, strength: nil) == [])
}

@Test func releaseAllUntilNextActivation() {
    var a = arbiter([1: Want(divert: [gesture])])
    _ = a.frontmost(pid: pid(1))
    _ = a.button(cid: gesture, pressed: true, time: 5)
    #expect(a.releaseAll() == [
        .send(id(1), .button(cid: gesture, pressed: false, time: 5)),
        .send(id(1), .watching([])),
        .send(id(1), .owner(false)),
        .apply(idle),
    ])
    #expect(a.owner == nil)
    _ = a.frontmost(pid: pid(1))
    #expect(a.owner == id(1))
    #expect(a.wanted == MouseState(divert: [gesture], mode: .ratchet))
}

@Test func connectAfterActivation() {
    var a = Arbiter()
    _ = a.frontmost(pid: pid(1))
    let effects = a.connect(id(1), pid: pid(1))
    #expect(effects.contains(.send(id(1), .owner(true))))
    #expect(a.want(id(1), Want(divert: [gesture])) == [.apply(MouseState(divert: [gesture], mode: .ratchet))])
}

@Test func watchingGoesToOwnerAndIsRemembered() {
    var a = arbiter([1: .none, 2: .none])
    _ = a.frontmost(pid: pid(1))
    #expect(a.watching([back]) == [.send(id(1), .watching([back]))])
    #expect(a.frontmost(pid: pid(2)).last == .send(id(2), .watching([back])))
}

@Test func thumbWheelGoesToOwnerOnly() {
    var a = arbiter([1: .none])
    #expect(a.thumbWheel(delta: 1, touching: true, phase: .began, time: 1) == [])
    _ = a.frontmost(pid: pid(1))
    #expect(a.thumbWheel(delta: 1, touching: true, phase: .began, time: 1)
        == [.send(id(1), .thumbWheel(delta: 1, touching: true, phase: .began, time: 1))])
}

@Test func formerOwnerHearsNothingIsWatched() {
    // Its side buttons come from the system again: a filter that still believed them heard would drop them.
    var a = arbiter([1: Want(watch: [back]), 2: .none])
    _ = a.frontmost(pid: pid(1))
    _ = a.watching([back])
    let effects = a.frontmost(pid: pid(2))
    #expect(effects.firstIndex(of: .send(id(1), .watching([]))).map { $0 < effects.firstIndex(of: .send(id(1), .owner(false)))! } == true)
}
