import AppKit
import MouseCore

/// The window under the pointer, for the clients' wheel areas (core spec, "Window under the pointer"). Active only
/// while some client declared areas; then a global and a local monitor (listen only) see each move and scroll. While
/// the point stays in the cached window frame only the point is reported; leaving it asks the window server which
/// window is there now; inside it, the topmost window's number is asked at most every `probeInterval` (a window above
/// the cached one, that the pointer moved onto inside its frame, would never be seen otherwise), and so do the end of a drag (the window may have moved with the pointer, or resized), a Space
/// change and another app in front. Inactive, there are no monitors and nothing runs.
@MainActor final class PointerTracker {
    private let onChange: (PointerPlace?) -> Void
    private var monitors: [Any] = []
    /// The window under the pointer: its number, owner and frame in AppKit screen coordinates.
    private var cached: (window: Int, pid: pid_t, frame: CGRect)?
    private var reported: PointerPlace?
    private var spaceObserver: NSObjectProtocol?
    /// How often the number of the window at the pointer is asked while the pointer stays inside the cached frame. Its
    /// cost, measured 2026-10-28 on the M4 Max (macOS 27): 7 µs CPU and 25 µs wall per call, which is 0.1 % of a core
    /// at the 125 calls a second this allows; at every move of a 1 kHz mouse it would be 0.7 % and 2.5 % blocked.
    private static let probeInterval = 0.008
    private var lastProbe = 0.0
    /// The one check owed after moves that came inside the interval: a window that came above the cached one during the
    /// last moves is still found once the pointer stops. It fires once and is gone: nothing runs at rest.
    private var trailing: DispatchWorkItem?

    init(onChange: @escaping (PointerPlace?) -> Void) {
        self.onChange = onChange
    }

    func setActive(_ on: Bool) {
        guard on == monitors.isEmpty else { return }
        guard on else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
            spaceObserver = nil
            cached = nil
            reported = nil
            trailing?.cancel()
            trailing = nil
            return
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .scrollWheel, .leftMouseUp]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let ended = event.type == .leftMouseUp
            MainActor.assumeIsolated { ended ? self?.invalidate() : self?.check() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let ended = event.type == .leftMouseUp
            MainActor.assumeIsolated { ended ? self?.invalidate() : self?.check() }
            return event
        }
        monitors = [global, local].compactMap { $0 }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
        check()
    }

    /// Another app came in front, a drag ended or the Space changed: another window, or this one moved, may now be
    /// under a pointer that did not leave the cached frame.
    func invalidate() {
        cached = nil
        if !monitors.isEmpty { check() }
    }

    private func check() {
        let point = NSEvent.mouseLocation
        if let current = cached, current.frame.contains(point) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProbe >= Self.probeInterval {
                lastProbe = now
                trailing?.cancel()
                trailing = nil
                if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) != current.window {
                    cached = Self.window(at: point)
                }
            } else if trailing == nil {
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.trailing = nil
                        self?.check()
                    }
                }
                trailing = item
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeInterval, execute: item)
            }
        } else {
            cached = Self.window(at: point)
        }
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
