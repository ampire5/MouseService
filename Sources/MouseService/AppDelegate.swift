import AppKit
import ApplicationServices
import ServiceManagement

/// The menu-bar item: gestures on or off, the Accessibility permission, launch at login, quit. The tap runs while
/// gestures are on and the permission is granted; nothing else runs at rest.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let synth = TouchSynth()
    private var tap: SideButtonTap?
    private static let gesturesKey = "gesturesOn"

    private var gesturesOn: Bool {
        get { UserDefaults.standard.object(forKey: Self.gesturesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.gesturesKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A crash in the middle of a swipe would leave the pointer frozen: it moves at every start.
        CGAssociateMouseAndMouseCursorPosition(1)
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "MouseService")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // The system says so when the Accessibility list changes: the tap starts as soon as the permission is given.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(accessibilityChanged),
                                                            name: NSNotification.Name("com.apple.accessibility.api"),
                                                            object: nil)
        if !AXIsProcessTrusted() {
            let prompt = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt, a global var Swift 6 refuses
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        updateTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap?.stop()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    @objc private func accessibilityChanged() {
        // The notification comes before the list is written: look a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.updateTap() }
    }

    private func updateTap() {
        let wanted = gesturesOn && synth != nil && AXIsProcessTrusted()
        if wanted, tap == nil, let synth {
            let tap = SideButtonTap(synth: synth)
            if tap.start() { self.tap = tap }
        } else if !wanted, let tap {
            tap.stop()
            self.tap = nil
        }
        statusItem.button?.appearsDisabled = tap == nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String = if synth == nil {
            "Gestures unavailable on this macOS"
        } else if !AXIsProcessTrusted() {
            "Waiting for Accessibility permission"
        } else if tap != nil {
            "Back + drag: Spaces, Mission Control"
        } else {
            "Gestures off"
        }
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let gestures = item("Gestures", #selector(toggleGestures))
        gestures.state = gesturesOn ? .on : .off
        gestures.isEnabled = synth != nil
        menu.addItem(gestures)
        if !AXIsProcessTrusted() {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MouseService", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleGestures() {
        gesturesOn.toggle()
        updateTap()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
