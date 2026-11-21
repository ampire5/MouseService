import CoreGraphics
import Foundation
import GestureCore
import os

/// Posts trackpad gestures the system would get from a trackpad: the Dock's swipe (Spaces, Mission Control, App
/// Exposé) and the page swipe (back / forward). Private interfaces, found at run time; none of them writes into
/// memory it does not own.
///
/// macOS 26 reads Dock swipe data from CGEvent fields. macOS 27 reads an attached IOHIDEvent (Mac Mouse Fix).
/// The event is made with IOKit's `IOHIDEventCreate` and attached with SkyLight's `SLEventSetIOHIDEvent`.
/// Checked on 27.0.1 (2026-10-27): a replay of Mac Mouse Fix's events opened Mission Control
/// with both this function and Mac Mouse Fix's direct write into the CGEvent; a swipe whose first event has zero
/// progress is ignored by the Dock.
final class TouchSynth: @unchecked Sendable {
    private let hidEncoder: HIDSwipeEncoder?
    private static let log = Logger(subsystem: "local.mouseservice", category: "Touch")
    private static let dockSwipeType: UInt32 = 23

    /// The end of a swipe, posted again 0.2 s and 0.5 s later: under load the Dock may miss it and leave the transition
    /// stuck halfway (Mac Mouse Fix's experience; the repeat of an end is harmless).
    private var endRepeats: [DispatchWorkItem] = []

    /// macOS 26 needs only CoreGraphics. Later versions require the HID event functions.
    init?(operatingSystemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        if operatingSystemMajorVersion < 27 {
            hidEncoder = nil
        } else {
            guard let encoder = HIDSwipeEncoder() else {
                Self.log.error("Private gesture functions not found: gestures off")
                return nil
            }
            hidEncoder = encoder
        }
    }

    /// Called on the tap's thread, as every other method here.
    @discardableResult
    func post(_ swipe: SideButtonGesture.DockSwipe, repeatOn queue: DispatchQueue) -> Bool {
        if swipe.phase == .began { cancelEndRepeats() }
        let events = dockSwipeEvents(swipe)
        for event in events { event.post(tap: .cgSessionEventTap) }
        if !events.isEmpty && (swipe.phase == .ended || swipe.phase == .cancelled) {
            repeatEnd(events, on: queue)
        }
        return !events.isEmpty
    }

    func dockSwipeEvents(_ swipe: SideButtonGesture.DockSwipe) -> [CGEvent] {
        let phase: UInt32 = switch swipe.phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
        let motion = swipe.axis == .horizontal ? 1 : 2
        if let hidEncoder {
            return hidEncoder.event(swipe, motion: motion, phase: phase).map { [$0] } ?? []
        }
        return Self.legacyDockSwipeEvents(swipe, motion: motion, phase: phase)
    }

    /// The pre-27 Dock needs the magnify event and its companion gesture event.
    /// Field layout and signs follow Mac Mouse Fix 3.1.0's TouchSimulator.
    private static func legacyDockSwipeEvents(_ swipe: SideButtonGesture.DockSwipe, motion: Int,
                                              phase: UInt32) -> [CGEvent] {
        guard let event = CGEvent(source: nil), let companion = CGEvent(source: nil) else { return [] }
        let field = { (number: UInt32) in CGEventField(rawValue: number)! }
        let progress = -swipe.progress
        let packedMotion = Double(Float(bitPattern: UInt32(motion)))

        companion.setDoubleValueField(field(55), value: 29)
        companion.setDoubleValueField(field(41), value: 33231)

        event.setDoubleValueField(field(55), value: 30)
        event.setDoubleValueField(field(41), value: 33231)
        event.setDoubleValueField(field(110), value: Double(dockSwipeType))
        event.setDoubleValueField(field(119), value: packedMotion)
        event.setDoubleValueField(field(123), value: Double(motion))
        event.setDoubleValueField(field(124), value: progress)
        event.setDoubleValueField(field(132), value: Double(phase))
        event.setDoubleValueField(field(134), value: Double(phase))
        event.setIntegerValueField(field(135), value: Int64(Float(progress).bitPattern))
        event.setIntegerValueField(field(136), value: 1)  // Natural swipe direction.
        event.setDoubleValueField(field(139), value: packedMotion)
        event.setDoubleValueField(field(165), value: Double(motion))
        if swipe.phase == .ended || swipe.phase == .cancelled {
            event.setDoubleValueField(field(129), value: swipe.velocity)
            event.setDoubleValueField(field(130), value: swipe.velocity)
        }
        return [event, companion]
    }

    /// A page swipe (Safari's and Finder's back / forward): a gesture event with the CGEvent fields, unchanged on 27.
    @discardableResult
    func postPageSwipe(_ button: SideButtonGesture.Button) -> Bool {
        guard let event = CGEvent(source: nil) else { return false }
        let f = { (n: UInt32) in CGEventField(rawValue: n)! }
        event.setIntegerValueField(f(55), value: 29)   // NSEventTypeGesture
        event.setIntegerValueField(f(110), value: 16)  // kIOHIDEventTypeNavigationSwipe
        event.setIntegerValueField(f(132), value: 1)   // began
        event.setIntegerValueField(f(115), value: button == .back ? 4 : 8)   // kIOHIDSwipeLeft / Right
        event.post(tap: .cghidEventTap)
        event.setIntegerValueField(f(115), value: 0)
        event.setIntegerValueField(f(132), value: 4)   // ended
        event.post(tap: .cghidEventTap)
        return true
    }

    private func repeatEnd(_ events: [CGEvent], on queue: DispatchQueue) {
        cancelEndRepeats()
        endRepeats = [0.2, 0.5].map { delay in
            let work = DispatchWorkItem {
                for event in events { event.post(tap: .cgSessionEventTap) }
            }
            queue.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func cancelEndRepeats() {
        endRepeats.forEach { $0.cancel() }
        endRepeats = []
    }

    /// The macOS 27 Dock reads the attached IOHIDEvent, including a velocity child on exit.
    private struct HIDSwipeEncoder {
        private typealias HIDEvent = OpaquePointer
        private let create: @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> HIDEvent?
        private let setInteger: @convention(c) (HIDEvent, UInt32, Int) -> Void
        private let setFloat: @convention(c) (HIDEvent, UInt32, Double) -> Void
        private let append: @convention(c) (HIDEvent, HIDEvent, UInt32) -> Void
        private let attach: @convention(c) (CGEvent, HIDEvent) -> Void

        private static let velocityType: UInt32 = 9
        private static let dockPrimaryFlavor = 3
        private static func field(_ type: UInt32, _ n: UInt32) -> UInt32 { type << 16 | n }

        init?() {
            guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
                  let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
                  let create = dlsym(iokit, "IOHIDEventCreate"),
                  let setInteger = dlsym(iokit, "IOHIDEventSetIntegerValue"),
                  let setFloat = dlsym(iokit, "IOHIDEventSetFloatValue"),
                  let append = dlsym(iokit, "IOHIDEventAppendEvent"),
                  let attach = dlsym(skyLight, "SLEventSetIOHIDEvent") else {
                return nil
            }
            self.create = unsafeBitCast(create, to: (@convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> HIDEvent?).self)
            self.setInteger = unsafeBitCast(setInteger, to: (@convention(c) (HIDEvent, UInt32, Int) -> Void).self)
            self.setFloat = unsafeBitCast(setFloat, to: (@convention(c) (HIDEvent, UInt32, Double) -> Void).self)
            self.append = unsafeBitCast(append, to: (@convention(c) (HIDEvent, HIDEvent, UInt32) -> Void).self)
            self.attach = unsafeBitCast(attach, to: (@convention(c) (CGEvent, HIDEvent) -> Void).self)
        }

        func event(_ swipe: SideButtonGesture.DockSwipe, motion: Int, phase: UInt32) -> CGEvent? {
            guard let hid = create(kCFAllocatorDefault, TouchSynth.dockSwipeType, 0, phase << 24) else { return nil }
            defer { release(hid) }
            setInteger(hid, Self.field(TouchSynth.dockSwipeType, 1), motion)   // motion
            setInteger(hid, Self.field(TouchSynth.dockSwipeType, 5), Self.dockPrimaryFlavor)
            setFloat(hid, Self.field(TouchSynth.dockSwipeType, 2), swipe.progress)
            let ends = swipe.phase == .ended || swipe.phase == .cancelled
            if ends, let velocity = create(kCFAllocatorDefault, Self.velocityType, 0, 0) {
                setFloat(velocity, Self.field(Self.velocityType, 0), swipe.velocity)
                setFloat(velocity, Self.field(Self.velocityType, 1), swipe.velocity)
                append(hid, velocity, 0)
                release(velocity)
            }
            guard let event = CGEvent(source: nil), let type = CGEventType(rawValue: 30) else { return nil }
            event.type = type
            attach(event, hid)
            return event
        }

        private func release(_ hid: HIDEvent) {
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(hid)).release()
        }
    }
}
