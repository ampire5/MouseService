import AppKit
import MouseCore

/// The window under the pointer, for the clients' wheel areas (core spec, "Window under the pointer"). Active only
/// while some client declared areas; then a global and a local monitor (listen only) see each move and scroll. While
/// the point stays in the cached window frame only the point is reported; leaving it asks the window server which
/// window is there now. Inactive, there are no monitors and nothing runs.
@MainActor final class PointerTracker {
    private let onChange: (PointerPlace?) -> Void
    private var monitors: [Any] = []
    /// The window under the pointer: its number, owner and frame in AppKit screen coordinates.
    private var cached: (window: Int, pid: pid_t, frame: CGRect)?
    private var reported: PointerPlace?

    init(onChange: @escaping (PointerPlace?) -> Void) {
        self.onChange = onChange
    }

    func setActive(_ on: Bool) {
        guard on == monitors.isEmpty else { return }
        guard on else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            cached = nil
            reported = nil
            return
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .scrollWheel]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.check() }
            return event
        }
        monitors = [global, local].compactMap { $0 }
        check()
    }

    /// Another app came in front: its window may now be under a pointer that did not move.
    func invalidate() {
        cached = nil
        if !monitors.isEmpty { check() }
    }

    private func check() {
        let point = NSEvent.mouseLocation
        if cached.map({ !$0.frame.contains(point) }) ?? true { cached = Self.window(at: point) }
        let place = cached.map {
            PointerPlace(window: $0.window, pid: $0.pid,
                         point: CGPoint(x: point.x - $0.frame.minX, y: point.y - $0.frame.minY))
        }
        guard place != reported else { return }
        reported = place
        onChange(place)
    }

    private static func window(at point: CGPoint) -> (window: Int, pid: pid_t, frame: CGRect)? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = info[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
              let primary = NSScreen.screens.first else { return nil }
        // The window server's frame has its origin at the top-left of the primary screen; AppKit's at its bottom-left.
        let frame = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        return (number, pid, frame)
    }
}

/// The frontmost app's pid, from the workspace's activation notifications.
@MainActor final class FrontmostTracker {
    private var observer: NSObjectProtocol?

    init(onChange: @escaping @MainActor (pid_t?) -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { onChange(pid) }
        }
        onChange(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
}
