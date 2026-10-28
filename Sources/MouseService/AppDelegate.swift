import AppKit
import ApplicationServices
import MouseClient
import MouseContract
import MouseCore
import MouseServiceKit
import ServiceManagement
import SettingsKit

/// MouseService runs as a launchd agent (`~/Library/LaunchAgents/local.mouseservice.plist`): launchd starts it at login,
/// restarts it after a crash and starts it on demand when a client connects to its Mach service. Opened by hand, the
/// app only registers that agent (or wakes it) and quits.
///
/// The agent owns the mouse (`Service` over `LogiMouseDriver`), the gestures, and the pointer and scroll rules. Its
/// menu-bar item shows the mouse, the clients, buttons stuck in the system, the gestures and the device rules.
/// Nothing runs at rest: the taps and monitors wait for input, the menu is built when it opens.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let label = "local.mouseservice"
    static let agentPlist = "local.mouseservice.plist"

    private var statusItem: NSStatusItem?
    private let synth = TouchSynth()
    private var tap: SideButtonTap?
    private let pointer = PointerDevices()
    private var scrollTap: ScrollTap?
    private var driver: LogiMouseDriver?
    private var service: Service?
    private var listener: Listener?
    private var pointerTracker: PointerTracker?
    private var frontmostTracker: FrontmostTracker?
    private let settings = ServiceSettings()
    private var settingsWindow: SettingsWindowController?
    private static let gesturesKey = "gesturesOn"

    private var gesturesOn: Bool {
        get { UserDefaults.standard.object(forKey: Self.gesturesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.gesturesKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Self.label else {
            registerAgentAndQuit()
            return
        }
        // A crash in the middle of a swipe would leave the pointer frozen: it moves at every start.
        CGAssociateMouseAndMouseCursorPosition(1)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "MouseService")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        // The system says so when the Accessibility list changes: the tap starts as soon as the permission is given.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(accessibilityChanged),
                                                            name: NSNotification.Name("com.apple.accessibility.api"),
                                                            object: nil)
        if !AXIsProcessTrusted() {
            let prompt = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt, a global var Swift 6 refuses
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        pointer.start()
        updateTap()
        startService()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap?.stop()
        scrollTap?.stop()
        pointer.restoreAll()
        driver?.releaseAllSync()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Service

    private func startService() {
        let driver = LogiMouseDriver(hapticStrength: settings.hapticStrength, panelForce: settings.panelForce)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let service = Service(driver: driver, version: version, globalMode: settings.wheelMode)
        // A SmartShift press where no app asks for a mode is the user's choice: kept as the setting.
        service.onGlobalModeChange = { [weak self] mode in
            try? self?.settings.setValue(mode == .freeSpin ? "free-spin" : "ratchet", forKey: ServiceSettings.wheelModeKey)
        }
        let tracker = PointerTracker { [weak service] place in service?.pointer(place) }
        service.onFollowsPointerChange = { [weak tracker] on in tracker?.setActive(on) }
        frontmostTracker = FrontmostTracker { [weak service, weak tracker] pid in
            service?.frontmost(pid: pid)
            tracker?.invalidate()
        }
        settings.onChange = { [weak self, weak driver, weak service] in
            guard let self, let driver else { return }
            driver.setHapticStrength(settings.hapticStrength)
            driver.setPanelForce(settings.panelForce)
            service?.setGlobalMode(settings.wheelMode)
        }
        listener = Listener(machService: MouseClient.serviceName, service: service)
        // Clients that lost a service wait for this rather than wake it themselves (a quit service stays quit).
        DistributedNotificationCenter.default().postNotificationName(MouseClient.serviceStarted, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        self.driver = driver
        self.service = service
        pointerTracker = tracker
    }

    /// Opened by hand: the agent is the app that runs. This copy writes the agent's plist into
    /// `~/Library/LaunchAgents` (this app's binary, the Mach service, run at load, kept alive after a crash), loads it
    /// anew and quits. A plain LaunchAgent and not `SMAppService.agent`: without a Team ID a registration pins the
    /// binary's cdhash, and launchd refuses every rebuilt binary (EX_CONFIG, OS_REASON_CODESIGNING, seen 2026-10-27).
    /// 0.1's login item and an earlier SMAppService registration go first: the label must be one job's.
    private func registerAgentAndQuit() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        let registered = SMAppService.agent(plistName: Self.agentPlist)
        if registered.status != .notRegistered { try? registered.unregister() }
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [Bundle.main.executablePath ?? ""],
            "MachServices": [MouseClient.serviceName: true],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.agentPlist)")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            let domain = "gui/\(getuid())"
            Self.launchctl(["bootout", "\(domain)/\(Self.label)"])   // a running agent or an old plist: fails quietly
            let status = Self.launchctl(["bootstrap", domain, url.path])
            if status != 0 { throw NSError(domain: "launchctl bootstrap", code: Int(status)) }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: Taps

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
        // The scroll rules need only the permission; gestures off leaves them on.
        if scrollTap == nil, AXIsProcessTrusted(), let scroll = ScrollTap(rules: pointer.scrollRules), scroll.start() {
            scrollTap = scroll
        }
        statusItem?.button?.appearsDisabled = tap == nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: driver?.device.present == true ? "MX Master: connected" : "No Logitech mouse",
                                action: nil, keyEquivalent: ""))
        let clients = service?.clients ?? []
        let clientsItem = NSMenuItem(title: clients.isEmpty ? "No clients" : "Clients", action: nil, keyEquivalent: "")
        if !clients.isEmpty {
            let submenu = NSMenu()
            for client in clients {
                let item = NSMenuItem(title: "\(client.bundleID) (\(client.pid))", action: nil, keyEquivalent: "")
                item.state = client.owner ? .on : .off
                submenu.addItem(item)
            }
            clientsItem.submenu = submenu
        }
        menu.addItem(clientsItem)
        let held = (0..<32).filter { NSEvent.pressedMouseButtons & (1 << $0) != 0 }
        if !held.isEmpty {
            let numbers = held.map(String.init).joined(separator: ", ")
            menu.addItem(NSMenuItem(title: "Buttons held by the system: \(numbers) — a stuck button, reconnect the mouse",
                                    action: nil, keyEquivalent: ""))
        }
        menu.addItem(item("Release All", #selector(releaseAll)))
        menu.addItem(.separator())
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
        let gestures = item("Gestures", #selector(toggleGestures))
        gestures.state = gesturesOn ? .on : .off
        gestures.isEnabled = synth != nil
        menu.addItem(gestures)
        if !AXIsProcessTrusted() {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: pointer.summary, action: nil, keyEquivalent: ""))
        menu.addItem(item("Edit Devices Config…", #selector(editDevicesConfig)))
        menu.addItem(item("Reload Devices Config", #selector(reloadDevicesConfig)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(NSMenuItem(title: "Quit MouseService", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func releaseAll() { service?.releaseAll() }

    @objc private func toggleGestures() {
        gesturesOn.toggle()
        updateTap()
    }

    @objc private func editDevicesConfig() {
        PointerDevices.ensureConfigFile()
        NSWorkspace.shared.open(PointerDevices.configURL)
    }

    @objc private func reloadDevicesConfig() {
        pointer.reload()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() {
        let window = settingsWindow ?? SettingsWindowController(pages: ServiceSettings.pages,
                                                                model: SettingsModel(store: settings),
                                                                autosaveName: "MouseServiceSettings",
                                                                lastPageDefaultsKey: "SettingsLastPage")
        settingsWindow = window
        NSApp.activate()
        window.show(page: nil)
    }
}
