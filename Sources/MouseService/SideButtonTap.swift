import AppKit
import CoreGraphics
import GestureCore
import MouseContract
import os

/// Recognizes trackpad gestures on the side buttons (back: CG button 3, forward: 4), and preserves short mouse clicks
/// for connected apps. Its own thread and run loop at `.userInteractive`: the tap is input, and a busy
/// main thread must not delay it or get it switched off by the system. Ordinary movement passes through until a
/// swipe begins, and with the tap off the buttons are the system's again.
final class SideButtonTap: @unchecked Sendable {
    private let synth: TouchSynth
    private let clickTargets: OSAllocatedUnfairLock<ClickTargets>
    private let preferences: OSAllocatedUnfairLock<Preferences>
    private let diagnostics: GestureDiagnostics
    private let swipeLifecycle: @Sendable (SwipePhase, Double, pid_t?) -> Void
    private let input = Input()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var pointerFrozen = false
    /// Repeats of a swipe's end (`TouchSynth`).
    private let repeats = DispatchQueue(label: "local.mouseservice.repeats", qos: .userInteractive)
    private static let log = Logger(subsystem: "local.mouseservice", category: "Tap")
    static let eventMask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
        | CGEventMask(1 << CGEventType.mouseMoved.rawValue)

    struct Preferences: Sendable {
        var pageSwipes = true
        var dragButton: SideButtonGesture.Button? = .back
        var threshold = 6.0
    }

    struct ClickTargets: Sendable {
        var frontmost: pid_t?
        var clients: Set<pid_t> = []

        func target(eventPID: pid_t) -> pid_t? {
            eventPID > 0 ? eventPID : frontmost
        }

        func clientTarget(eventPID: pid_t) -> pid_t? {
            guard let pid = target(eventPID: eventPID), clients.contains(pid) else { return nil }
            return pid
        }
    }

    final class Input {
        enum Action {
            case gesture([SideButtonGesture.Output])
            case nativeClick(CGEvent)
        }

        var gesture = SideButtonGesture()
        private var down: (event: CGEvent, pid: pid_t?)?
        private var pageSwipes = true
        private var intercepted: Set<SideButtonGesture.Button> = []

        func receive(_ type: CGEventType, _ event: CGEvent, at now: @autoclosure () -> Double,
                     preferences: () -> Preferences = { Preferences() }, eventTarget: () -> pid_t? = { nil },
                     clientTarget: () -> pid_t?) -> Action? {
            switch type {
            case .otherMouseDown:
                guard let button = SideButtonTap.button(for: event) else { return nil }
                let config = preferences()
                guard config.pageSwipes || config.dragButton == button else { return nil }
                gesture.settings.dragButton = config.dragButton
                gesture.settings.threshold = config.threshold
                gesture.settings.clickDuration = config.pageSwipes ? 0.3 : .infinity
                pageSwipes = config.pageSwipes
                intercepted.insert(button)
                let pid = pageSwipes ? clientTarget() : eventTarget()
                down = nil
                if (!pageSwipes || pid != nil), let copy = event.copy() {
                    down = (copy, pid)
                }
            case .otherMouseUp:
                guard let button = SideButtonTap.button(for: event), intercepted.remove(button) != nil else { return nil }
            case .otherMouseDragged:
                guard let button = SideButtonTap.button(for: event), intercepted.contains(button) else { return nil }
            default:
                break
            }
            guard let outputs = SideButtonTap.route(type, event, at: now(), gesture: &gesture) else { return nil }
            if type == .otherMouseUp, let down, SideButtonTap.button(for: down.event) == SideButtonTap.button(for: event) {
                self.down = nil
                if case .pageSwipe? = outputs.first, (pageSwipes ? clientTarget() : eventTarget()) == down.pid {
                    return .nativeClick(down.event)
                }
            }
            if !pageSwipes, case .pageSwipe? = outputs.first { return .gesture([]) }
            return .gesture(outputs)
        }

        func cancel() -> [SideButtonGesture.Output] {
            down = nil
            intercepted.removeAll()
            return gesture.cancel()
        }
    }

    init(synth: TouchSynth, clickTargets: OSAllocatedUnfairLock<ClickTargets>, preferences: Preferences,
         diagnostics: GestureDiagnostics, swipeLifecycle: @escaping @Sendable (SwipePhase, Double, pid_t?) -> Void) {
        self.synth = synth
        self.clickTargets = clickTargets
        self.preferences = OSAllocatedUnfairLock(initialState: preferences)
        self.diagnostics = diagnostics
        self.swipeLifecycle = swipeLifecycle
    }

    func updatePreferences(_ preferences: Preferences) {
        self.preferences.withLock { $0 = preferences }
    }

    /// Starts the tap on its thread; false without the Accessibility permission (the tap cannot be made).
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let me = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: Self.eventMask, callback: { proxy, type, event, info in
                let tap = Unmanaged<SideButtonTap>.fromOpaque(info!).takeUnretainedValue()
                return tap.handle(type, event, proxy: proxy)
            }, userInfo: me) else {
                ready.signal()
                return
            }
            self.tap = tap
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "SideButtonTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()   // the thread has set `tap`, or failed to make it, before the signal
        return tap != nil
    }

    /// Stops the tap: a swipe under way is cancelled and the pointer moves again. Waits until it is done.
    func stop() {
        guard let runLoop, let tap else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            CGEvent.tapEnable(tap: tap, enable: false)
            apply(input.cancel())
            CFRunLoopStop(runLoop)
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        self.tap = nil
        self.runLoop = nil
    }

    // MARK: On the tap's thread

    private func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system switched the tap off (it was too slow once): a swipe must not stay half done.
            Self.log.notice("Tap disabled by the system (\(type.rawValue)); enabled again")
            apply(input.cancel())
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        defer {
            if type == .otherMouseDown, diagnostics.isRunning, let button = Self.button(for: event) {
                diagnostics.press(button, clientPID: clientTarget(for: event))
            }
        }
        if type == .otherMouseUp, let button = Self.button(for: event) { diagnostics.release(button) }
        let action = input.receive(type, event, at: ProcessInfo.processInfo.systemUptime, preferences: {
            preferences.withLock { $0 }
        }, eventTarget: {
            let pid = Self.eventPID(event)
            return clickTargets.withLock { $0.target(eventPID: pid) }
        }) {
            clientTarget(for: event)
        }
        switch action {
        case nil:
            if type == .otherMouseUp, Self.button(for: event) != nil { diagnostics.click(delivered: true) }
            return Unmanaged.passUnretained(event)
        case let .gesture(outputs):
            apply(outputs)
            return nil
        case let .nativeClick(down):
            // The proxy posts the original press downstream of this tap, just before the returned release.
            down.tapPostEvent(proxy)
            diagnostics.click(delivered: true)
            return Unmanaged.passUnretained(event)
        }
    }

    private func clientTarget(for event: CGEvent) -> pid_t? {
        let pid = Self.eventPID(event)
        return clickTargets.withLock { $0.clientTarget(eventPID: pid) }
    }

    private static func eventPID(_ event: CGEvent) -> pid_t {
        pid_t(exactly: event.getIntegerValueField(.eventTargetUnixProcessID)) ?? 0
    }

    /// Nil passes the event through. An empty list consumes it without posting a gesture.
    static func route(_ type: CGEventType, _ event: CGEvent, at now: @autoclosure () -> Double,
                      gesture: inout SideButtonGesture) -> [SideButtonGesture.Output]? {
        switch type {
        case .mouseMoved:
            // Some mice deliver motion without a button number even while Back is held.
            guard gesture.isTrackingMovement else { return nil }
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            guard let button = Self.button(for: event) else { return nil }
            if type == .otherMouseDown { return gesture.press(button, at: now()) }
            if type == .otherMouseUp { return gesture.release(button, at: now()) }
        default:
            return nil
        }

        let outputs = gesture.drag(dx: event.getDoubleValueField(.mouseEventDeltaX),
                                   dy: event.getDoubleValueField(.mouseEventDeltaY))
        return type == .mouseMoved && !gesture.isSwiping ? nil : outputs
    }

    private static func button(for event: CGEvent) -> SideButtonGesture.Button? {
        switch event.getIntegerValueField(.mouseEventButtonNumber) {
        case 3: .back
        case 4: .forward
        default: nil
        }
    }

    private func apply(_ outputs: [SideButtonGesture.Output]) {
        for output in outputs {
            switch output {
            case let .pageSwipe(button):
                if synth.postPageSwipe(button) { diagnostics.click(delivered: false) }
            case let .dockSwipe(swipe):
                if swipe.phase == .began {
                    updateScales()
                }
                notifyClients(of: swipe.phase)
                let sent = synth.post(swipe, repeatOn: repeats)
                diagnostics.dock(phase: swipe.phase, sent: sent)
            case let .freezePointer(frozen):
                guard frozen != pointerFrozen else { continue }
                pointerFrozen = frozen
                CGAssociateMouseAndMouseCursorPosition(frozen ? 0 : 1)
            }
        }
    }

    /// Compatibility with older clients that hear the button directly over HID++.
    static let swipeBegan = Notification.Name("local.mouseservice.swipeBegan")

    private func notifyClients(of phase: SideButtonGesture.Phase) {
        guard phase != .changed else { return }
        let time = ProcessInfo.processInfo.systemUptime
        switch phase {
        case .began:
            let pid = clickTargets.withLock { $0.frontmost }
            swipeLifecycle(.began, time, pid)
            DistributedNotificationCenter.default().postNotificationName(Self.swipeBegan, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
        case .ended: swipeLifecycle(.ended, time, nil)
        case .cancelled: swipeLifecycle(.cancelled, time, nil)
        case .changed: break
        }
    }

    /// Progress per point from the main display's size at the start of each swipe (Mac Mouse Fix's measure: one Space
    /// per screen width and the 63-point gap between Spaces; the whole Mission Control transition per screen height).
    private func updateScales() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard bounds.width > 0, bounds.height > 0 else { return }
        input.gesture.settings.horizontalScale = 1 / (bounds.width + 63)
        input.gesture.settings.verticalScale = 1 / bounds.height
    }
}
