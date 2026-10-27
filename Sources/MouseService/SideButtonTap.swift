import AppKit
import CoreGraphics
import GestureCore
import os

/// Takes the side buttons (back: CG button 3, forward: 4) from the system and turns them into trackpad gestures
/// (`SideButtonGesture`, `TouchSynth`). Its own thread and run loop at `.userInteractive`: the tap is input, and a busy
/// main thread must not delay it or get it switched off by the system. Every other event passes untouched, and with
/// the tap off the buttons are the system's again.
final class SideButtonTap: @unchecked Sendable {
    private let synth: TouchSynth
    private var gesture = SideButtonGesture()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var pointerFrozen = false
    /// Repeats of a swipe's end (`TouchSynth`).
    private let repeats = DispatchQueue(label: "local.mouseservice.repeats", qos: .userInteractive)
    private static let log = Logger(subsystem: "local.mouseservice", category: "Tap")

    init(synth: TouchSynth) {
        self.synth = synth
    }

    /// Starts the tap on its thread; false without the Accessibility permission (the tap cannot be made).
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
            let me = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: { _, type, event, info in
                let tap = Unmanaged<SideButtonTap>.fromOpaque(info!).takeUnretainedValue()
                return tap.handle(type, event)
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
            apply(gesture.cancel())
            CFRunLoopStop(runLoop)
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        self.tap = nil
        self.runLoop = nil
    }

    // MARK: On the tap's thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switched the tap off (it was too slow once): a swipe must not stay half done.
            Self.log.notice("Tap disabled by the system (\(type.rawValue)); enabled again")
            apply(gesture.cancel())
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        let button: SideButtonGesture.Button
        switch event.getIntegerValueField(.mouseEventButtonNumber) {
        case 3: button = .back
        case 4: button = .forward
        default: return Unmanaged.passUnretained(event)
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .otherMouseDown:
            apply(gesture.press(button, at: now))
        case .otherMouseUp:
            apply(gesture.release(button, at: now))
        default:
            apply(gesture.drag(dx: event.getDoubleValueField(.mouseEventDeltaX),
                               dy: event.getDoubleValueField(.mouseEventDeltaY)))
        }
        return nil   // both buttons are ours: the system never sees their press without its release
    }

    private func apply(_ outputs: [SideButtonGesture.Output]) {
        for output in outputs {
            switch output {
            case let .pageSwipe(button):
                synth.postPageSwipe(button)
            case let .dockSwipe(swipe):
                if swipe.phase == .began {
                    updateScales()
                    announceSwipe()
                }
                synth.post(swipe, repeatOn: repeats)
            case let .freezePointer(frozen):
                guard frozen != pointerFrozen else { continue }
                pointerFrozen = frozen
                CGAssociateMouseAndMouseCursorPosition(frozen ? 0 : 1)
            }
        }
    }

    /// Tells the apps that hear the back button from the mouse itself (FrameScrub and Loupe over HID++, past this tap)
    /// that its press is a swipe now: they drop the press, else its release would be their click. Their own pointer
    /// watch does not see the drag once Mission Control or App Exposé takes the pointer. The core service's contract
    /// replaces this notification.
    static let swipeBegan = Notification.Name("local.mouseservice.swipeBegan")

    private func announceSwipe() {
        DistributedNotificationCenter.default().postNotificationName(Self.swipeBegan, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    /// Progress per point from the main display's size at the start of each swipe (Mac Mouse Fix's measure: one Space
    /// per screen width and the 63-point gap between Spaces; the whole Mission Control transition per screen height).
    private func updateScales() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard bounds.width > 0, bounds.height > 0 else { return }
        gesture.settings.horizontalScale = 1 / (bounds.width + 63)
        gesture.settings.verticalScale = 1 / bounds.height
    }
}
