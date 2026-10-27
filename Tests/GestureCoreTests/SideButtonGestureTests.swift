import Testing
@testable import GestureCore

typealias G = SideButtonGesture

func swipes(_ out: [G.Output]) -> [G.DockSwipe] {
    out.compactMap { if case let .dockSwipe(s) = $0 { s } else { nil } }
}

@Suite struct SideButtonGestureTests {
    var settings: G.Settings {
        var s = G.Settings()
        s.threshold = 6
        s.clickDuration = 0.3
        s.horizontalScale = 0.01
        s.verticalScale = 0.01
        return s
    }

    @Test func shortClickIsAPageSwipe() {
        var g = G(settings: settings)
        #expect(g.press(.back, at: 0) == [])
        #expect(g.release(.back, at: 0.1) == [.pageSwipe(.back)])
        _ = g.press(.forward, at: 1)
        #expect(g.release(.forward, at: 1.2) == [.pageSwipe(.forward)])
    }

    @Test func longPressWithoutDragIsNothing() {
        var g = G(settings: settings)
        _ = g.press(.back, at: 0)
        #expect(g.release(.back, at: 0.5) == [])
    }

    @Test func dragUnderThresholdStaysAClick() {
        var g = G(settings: settings)
        _ = g.press(.back, at: 0)
        #expect(g.drag(dx: 2, dy: 2) == [])
        #expect(g.release(.back, at: 0.1) == [.pageSwipe(.back)])
    }

    @Test func dragUpBeginsWithProgressAndFreezesThePointer() {
        var g = G(settings: settings)
        _ = g.press(.back, at: 0)
        let out = g.drag(dx: 1, dy: -8)
        #expect(out.first == .freezePointer(true))
        let began = swipes(out)
        #expect(began.count == 1)
        #expect(began[0].axis == .vertical)
        #expect(began[0].phase == .began)
        #expect(began[0].progress > 0)   // never zero: the Dock ignores such a swipe
        #expect(g.isSwiping)
    }

    @Test func swipeFollowsAndEndsWithOppositeVelocity() {
        var g = G(settings: settings)
        _ = g.press(.back, at: 0)
        _ = g.drag(dx: 0, dy: -10)
        let changed = swipes(g.drag(dx: 0, dy: -5))
        #expect(changed.map(\.phase) == [.changed])
        #expect(abs(changed[0].progress - 0.15) < 1e-9)
        #expect(g.drag(dx: 7, dy: 0) == [])   // across the axis: no step
        let out = g.release(.back, at: 1)
        let end = swipes(out)
        #expect(end.count == 1)
        #expect(end[0].phase == .ended)
        #expect(end[0].velocity < 0)
        #expect(out.last == .freezePointer(false))
        #expect(!g.isSwiping)
    }

    @Test func swipeTurnedBackIsCancelled() {
        var g = G(settings: settings)
        _ = g.press(.back, at: 0)
        _ = g.drag(dx: 20, dy: 0)
        _ = g.drag(dx: -3, dy: 0)
        let end = swipes(g.release(.back, at: 1))
        #expect(end.map(\.phase) == [.cancelled])
        #expect(end[0].axis == .horizontal)
    }

    @Test func forwardDragDoesNotSwipe() {
        var g = G(settings: settings)
        _ = g.press(.forward, at: 0)
        #expect(g.drag(dx: 50, dy: 0) == [])
        #expect(g.release(.forward, at: 0.1) == [.pageSwipe(.forward)])
    }

    @Test func cancelEndsASwipeAndUnfreezes() {
        var g = G(settings: settings)
        _ = g.press(.back, at: 0)
        _ = g.drag(dx: 0, dy: 20)
        let out = g.cancel()
        #expect(swipes(out).map(\.phase) == [.cancelled])
        #expect(out.last == .freezePointer(false))
        #expect(g.release(.back, at: 1) == [])   // the rest of the press is ignored
        #expect(g.cancel() == [])
    }

    @Test func anotherPressCancelsTheSwipe() {
        var g = G(settings: settings)
        _ = g.press(.back, at: 0)
        _ = g.drag(dx: 0, dy: -20)
        let out = g.press(.forward, at: 0.5)
        #expect(swipes(out).map(\.phase) == [.cancelled])
        #expect(g.release(.forward, at: 0.6) == [.pageSwipe(.forward)])
    }
}
