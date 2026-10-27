import CoreGraphics
import Foundation
import os
import PointerCore

/// Applies each device's scroll rule (`ScrollRules`) to its scroll events: reversed axes, scrolls dropped while a
/// modifier is held. The device is the sender of the IOHIDEvent attached to the CGEvent, as LinearMouse finds it; an
/// event without one (posted by a program) passes untouched. Its own thread and run loop at `.userInteractive`, as
/// `SideButtonTap`: scrolling is input.
final class ScrollTap: @unchecked Sendable {
    private let rules: ScrollRules
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private static let log = Logger(subsystem: "local.mouseservice", category: "Scroll")

    // Private: the IOHIDEvent behind a CGEvent and its fields (IOHIDEventTypes.h: scroll is type 6, X and Y its fields
    // 0 and 1). The event comes back retained.
    private typealias HIDEvent = AnyObject
    private let copyHIDEvent: @convention(c) (CGEvent) -> Unmanaged<HIDEvent>?
    private let senderID: @convention(c) (HIDEvent) -> UInt64
    private let getFloat: @convention(c) (HIDEvent, UInt32) -> Double
    private let setFloat: @convention(c) (HIDEvent, UInt32, Double) -> Void
    private static let scrollX: UInt32 = 6 << 16 | 0
    private static let scrollY: UInt32 = 6 << 16 | 1

    /// Nil when a private function is missing (another macOS): scroll rules are then off.
    init?(rules: ScrollRules) {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let copy = dlsym(cg, "CGEventCopyIOHIDEvent"),
              let sender = dlsym(iokit, "IOHIDEventGetSenderID"),
              let getFloat = dlsym(iokit, "IOHIDEventGetFloatValue"),
              let setFloat = dlsym(iokit, "IOHIDEventSetFloatValue") else {
            Self.log.error("Private scroll functions not found: scroll rules off")
            return nil
        }
        self.rules = rules
        copyHIDEvent = unsafeBitCast(copy, to: (@convention(c) (CGEvent) -> Unmanaged<HIDEvent>?).self)
        senderID = unsafeBitCast(sender, to: (@convention(c) (HIDEvent) -> UInt64).self)
        self.getFloat = unsafeBitCast(getFloat, to: (@convention(c) (HIDEvent, UInt32) -> Double).self)
        self.setFloat = unsafeBitCast(setFloat, to: (@convention(c) (HIDEvent, UInt32, Double) -> Void).self)
    }

    /// Starts the tap on its thread; false without the Accessibility permission (the tap cannot be made).
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let me = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                              callback: { _, type, event, info in
                let tap = Unmanaged<ScrollTap>.fromOpaque(info!).takeUnretainedValue()
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
        thread.name = "ScrollTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()   // the thread has set `tap`, or failed to make it, before the signal
        return tap != nil
    }

    /// Stops the tap and waits until it is done.
    func stop() {
        guard let runLoop, let tap else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CGEvent.tapEnable(tap: tap, enable: false)
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
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Self.log.notice("Tap disabled by the system (\(type.rawValue)); enabled again")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .scrollWheel:
            break
        default:
            return pass
        }
        guard let hid = copyHIDEvent(event)?.takeRetainedValue() else { return pass }
        let sender = senderID(hid)
        guard sender != 0, let rule = rules.rule(for: sender) else { return pass }
        let dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        switch rule.decide(deltaX: dx, deltaY: dy, flags: Self.modifiers(event.flags)) {
        case .pass:
            return pass
        case .drop:
            return nil
        case let .negate(x, y):
            // Every form of each delta, as LinearMouse turns them: apps read different ones.
            if x { negate(event, hid, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2,
                          .scrollWheelEventPointDeltaAxis2, Self.scrollX) }
            if y { negate(event, hid, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1,
                          .scrollWheelEventPointDeltaAxis1, Self.scrollY) }
            return pass
        }
    }

    private func negate(_ event: CGEvent, _ hid: HIDEvent, _ delta: CGEventField, _ fixed: CGEventField,
                        _ point: CGEventField, _ hidField: UInt32) {
        event.setIntegerValueField(delta, value: -event.getIntegerValueField(delta))
        event.setDoubleValueField(fixed, value: -event.getDoubleValueField(fixed))
        event.setDoubleValueField(point, value: -event.getDoubleValueField(point))
        setFloat(hid, hidField, -getFloat(hid, hidField))
    }

    private static func modifiers(_ flags: CGEventFlags) -> ModifierSet {
        var set: ModifierSet = []
        if flags.contains(.maskCommand) { set.insert(.command) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskControl) { set.insert(.control) }
        return set
    }
}
