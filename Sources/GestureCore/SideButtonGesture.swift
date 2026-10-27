/// The side buttons as a trackpad (Mac Mouse Fix's set-up that this replaces): a click of back or forward is a page
/// swipe; back held and dragged is a three-finger swipe that follows the hand — sideways between Spaces, up to Mission
/// Control, down to App Exposé. Pure: events in, what to post out. The caller swallows every event of both buttons.
public struct SideButtonGesture: Sendable {
    public enum Button: Sendable { case back, forward }

    public enum Axis: Sendable, Equatable { case horizontal, vertical }

    public enum Phase: Sendable, Equatable { case began, changed, ended, cancelled }

    /// One dock swipe event: `progress` is the whole offset from the start (the Dock's unit: about 1 per Space or per
    /// the full Mission Control transition); `velocity` matters only on `.ended` / `.cancelled`.
    public struct DockSwipe: Sendable, Equatable {
        public var axis: Axis
        public var phase: Phase
        public var progress: Double
        public var velocity: Double
    }

    public enum Output: Sendable, Equatable {
        /// A click: the page swipe back (`.back`) or forward.
        case pageSwipe(Button)
        case dockSwipe(DockSwipe)
        /// The pointer stays where it is during a swipe (true) and moves again after it.
        case freezePointer(Bool)
    }

    public struct Settings: Sendable, Equatable {
        /// How far (points) the back button must be dragged before it is a swipe and not a click.
        public var threshold: Double = 6
        /// A press held longer than this and released without a drag is nothing: a long press belongs to the apps
        /// that hear the button themselves (FrameScrub's and Loupe's own long presses).
        public var clickDuration: Double = 0.3
        /// Progress per point of drag. Vertical: the Dock's full transition per screen height. Horizontal: one Space per
        /// screen width and the gap between Spaces. Set by the caller from the screen.
        public var horizontalScale: Double = 1.0 / 1500
        public var verticalScale: Double = 1.0 / 900
        public init() {}
    }

    public var settings: Settings

    private enum State {
        case idle
        /// A button is down; `moved` is the drag so far (back only), not yet past the threshold.
        case pressed(Button, at: Double, moved: (x: Double, y: Double))
        case swiping(Axis, progress: Double, lastStep: Double)
    }

    private var state = State.idle

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Whether a swipe is under way (the caller re-sends its end and keeps the pointer frozen).
    public var isSwiping: Bool {
        if case .swiping = state { true } else { false }
    }

    public mutating func press(_ button: Button, at time: Double) -> [Output] {
        // A second button while one is down: the first one's gesture ends, the new one starts afresh.
        let ended = cancel()
        state = .pressed(button, at: time, moved: (0, 0))
        return ended
    }

    /// A drag of `dx`, `dy` points (y down, as CGEvent deltas) while a button is down.
    public mutating func drag(dx: Double, dy: Double) -> [Output] {
        switch state {
        case let .pressed(.back, at, moved):
            let x = moved.x + dx, y = moved.y + dy
            guard (x * x + y * y).squareRoot() >= settings.threshold else {
                state = .pressed(.back, at: at, moved: (x, y))
                return []
            }
            let axis: Axis = abs(x) >= abs(y) ? .horizontal : .vertical
            // The Dock ignores a swipe whose first event has no progress (macOS 27.0.1): it begins with the drag so far.
            let step = self.step(axis, dx: x, dy: y)
            state = .swiping(axis, progress: step, lastStep: step)
            return [.freezePointer(true), .dockSwipe(DockSwipe(axis: axis, phase: .began, progress: step, velocity: 0))]
        case let .swiping(axis, progress, _):
            let step = self.step(axis, dx: dx, dy: dy)
            guard step != 0 else { return [] }
            state = .swiping(axis, progress: progress + step, lastStep: step)
            return [.dockSwipe(DockSwipe(axis: axis, phase: .changed, progress: progress + step, velocity: 0))]
        default:
            return []
        }
    }

    public mutating func release(_ button: Button, at time: Double) -> [Output] {
        switch state {
        case let .pressed(pressed, at, _) where pressed == button:
            state = .idle
            return time - at <= settings.clickDuration ? [.pageSwipe(button)] : []
        case .swiping where button == .back:
            let out = finish()
            state = .idle
            return out
        default:
            return []
        }
    }

    /// Everything stops now (the tap was switched off, the service quits, gestures were turned off): a swipe under way
    /// is cancelled and the pointer moves again. Safe to call at any time.
    public mutating func cancel() -> [Output] {
        guard case let .swiping(axis, progress, _) = state else {
            state = .idle
            return []
        }
        state = .idle
        return [.dockSwipe(DockSwipe(axis: axis, phase: .cancelled, progress: progress, velocity: 0)),
                .freezePointer(false)]
    }

    /// The end of a swipe: it goes on (`.ended`) if the last step went the way of the whole swipe, else it goes back
    /// (`.cancelled`). The velocity has the opposite sign of the progress, as the Dock reads it (Mac Mouse Fix's events
    /// on macOS 27.0.1: progress 0.128, velocity −0.81).
    private func finish() -> [Output] {
        guard case let .swiping(axis, progress, lastStep) = state else { return [] }
        let phase: Phase = (lastStep >= 0) == (progress >= 0) ? .ended : .cancelled
        return [.dockSwipe(DockSwipe(axis: axis, phase: phase, progress: progress, velocity: -lastStep * 100)),
                .freezePointer(false)]
    }

    /// Progress of a drag along `axis`: up (negative y) opens Mission Control (positive progress); sideways follows
    /// the hand as on a trackpad with natural scrolling.
    private func step(_ axis: Axis, dx: Double, dy: Double) -> Double {
        switch axis {
        case .horizontal: dx * settings.horizontalScale
        case .vertical: -dy * settings.verticalScale
        }
    }
}
