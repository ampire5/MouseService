import CoreGraphics
import Foundation
import GestureCore
import os

/// Posts trackpad gestures the system would get from a trackpad: the Dock's swipe (Spaces, Mission Control, App
/// Exposé) and the page swipe (back / forward). Private interfaces, found at run time; none of them writes into
/// memory it does not own.
///
/// macOS 27 reads a dock swipe from the IOHIDEvent attached to the CGEvent, not from the CGEvent's fields (Mac Mouse
/// Fix's notes). The event is made with IOKit's `IOHIDEventCreate` and attached with SkyLight's `SLEventSetIOHIDEvent`,
/// the system's own function. Checked on 27.0.1 (2026-10-27): a replay of Mac Mouse Fix's events opened Mission Control
/// with both this function and Mac Mouse Fix's direct write into the CGEvent; a swipe whose first event has zero
/// progress is ignored by the Dock.
final class TouchSynth: @unchecked Sendable {
    private typealias HIDEvent = OpaquePointer
    private let create: @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> HIDEvent?
    private let setInteger: @convention(c) (HIDEvent, UInt32, Int) -> Void
    private let setFloat: @convention(c) (HIDEvent, UInt32, Double) -> Void
    private let append: @convention(c) (HIDEvent, HIDEvent, UInt32) -> Void
    private let attach: @convention(c) (CGEvent, HIDEvent) -> Void
    private static let log = Logger(subsystem: "local.mouseservice", category: "Touch")

    // IOHIDEventTypes.h: event types, fields (type << 16 | n), phases (option bits from bit 24).
    private static let dockSwipeType: UInt32 = 23
    private static let velocityType: UInt32 = 9
    private static let dockPrimaryFlavor = 3
    private static func field(_ type: UInt32, _ n: UInt32) -> UInt32 { type << 16 | n }

    /// The end of a swipe, posted again 0.2 s and 0.5 s later: under load the Dock may miss it and leave the transition
    /// stuck halfway (Mac Mouse Fix's experience; the repeat of an end is harmless).
    private var endRepeats: [DispatchWorkItem] = []

    /// Nil when one of the private functions is missing (another macOS): gestures are then off, said in the menu.
    init?() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let create = dlsym(iokit, "IOHIDEventCreate"),
              let setInteger = dlsym(iokit, "IOHIDEventSetIntegerValue"),
              let setFloat = dlsym(iokit, "IOHIDEventSetFloatValue"),
              let append = dlsym(iokit, "IOHIDEventAppendEvent"),
              let attach = dlsym(skyLight, "SLEventSetIOHIDEvent") else {
            Self.log.error("Private gesture functions not found: gestures off")
            return nil
        }
        self.create = unsafeBitCast(create, to: (@convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> HIDEvent?).self)
        self.setInteger = unsafeBitCast(setInteger, to: (@convention(c) (HIDEvent, UInt32, Int) -> Void).self)
        self.setFloat = unsafeBitCast(setFloat, to: (@convention(c) (HIDEvent, UInt32, Double) -> Void).self)
        self.append = unsafeBitCast(append, to: (@convention(c) (HIDEvent, HIDEvent, UInt32) -> Void).self)
        self.attach = unsafeBitCast(attach, to: (@convention(c) (CGEvent, HIDEvent) -> Void).self)
    }

    /// Called on the tap's thread, as every other method here.
    func post(_ swipe: SideButtonGesture.DockSwipe, repeatOn queue: DispatchQueue) {
        let phase: UInt32 = switch swipe.phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
        if swipe.phase == .began { cancelEndRepeats() }
        guard let hid = create(kCFAllocatorDefault, Self.dockSwipeType, 0, phase << 24) else { return }
        defer { release(hid) }
        setInteger(hid, Self.field(Self.dockSwipeType, 1), swipe.axis == .horizontal ? 1 : 2)   // motion
        setInteger(hid, Self.field(Self.dockSwipeType, 5), Self.dockPrimaryFlavor)
        setFloat(hid, Self.field(Self.dockSwipeType, 2), swipe.progress)
        let ends = swipe.phase == .ended || swipe.phase == .cancelled
        if ends, let velocity = create(kCFAllocatorDefault, Self.velocityType, 0, 0) {
            setFloat(velocity, Self.field(Self.velocityType, 0), swipe.velocity)
            setFloat(velocity, Self.field(Self.velocityType, 1), swipe.velocity)
            append(hid, velocity, 0)
            release(velocity)
        }
        guard let event = CGEvent(source: nil), let type = CGEventType(rawValue: 30) else { return }
        event.type = type
        attach(event, hid)
        event.post(tap: .cgSessionEventTap)
        if ends { repeatEnd(event, on: queue) }
    }

    /// A page swipe (Safari's and Finder's back / forward): a gesture event with the CGEvent fields, unchanged on 27.
    func postPageSwipe(_ button: SideButtonGesture.Button) {
        guard let event = CGEvent(source: nil) else { return }
        let f = { (n: UInt32) in CGEventField(rawValue: n)! }
        event.setIntegerValueField(f(55), value: 29)   // NSEventTypeGesture
        event.setIntegerValueField(f(110), value: 16)  // kIOHIDEventTypeNavigationSwipe
        event.setIntegerValueField(f(132), value: 1)   // began
        event.setIntegerValueField(f(115), value: button == .back ? 4 : 8)   // kIOHIDSwipeLeft / Right
        event.post(tap: .cghidEventTap)
        event.setIntegerValueField(f(115), value: 0)
        event.setIntegerValueField(f(132), value: 4)   // ended
        event.post(tap: .cghidEventTap)
    }

    private func repeatEnd(_ event: CGEvent, on queue: DispatchQueue) {
        cancelEndRepeats()
        endRepeats = [0.2, 0.5].map { delay in
            let work = DispatchWorkItem { event.post(tap: .cgSessionEventTap) }
            queue.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func cancelEndRepeats() {
        endRepeats.forEach { $0.cancel() }
        endRepeats = []
    }

    private func release(_ hid: HIDEvent) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(hid)).release()
    }
}
