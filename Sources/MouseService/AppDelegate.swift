import AppKit
import ApplicationServices
import MouseClient
import MouseContract
import MouseCore
import MouseServiceKit
import os
import Security
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
    private weak var mouseStatusItem: NSMenuItem?
    private let synth = TouchSynth()
    private let clickTargets = OSAllocatedUnfairLock(initialState: SideButtonTap.ClickTargets())
    private let gestureDiagnostics = GestureDiagnostics()
    private var tap: SideButtonTap?
    private let pointer = PointerDevices()
    private var scrollTap: ScrollTap?
    private var driver: LogiMouseDriver?
    private var service: Service?
    private let d100h = D100HDevice(firmware: D100HSettings())
    private var d100hDaemonStatus: SMAppService.Status?
    private var d100hStatusTask: Task<Void, Never>?
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    private var d100hWorkspaceState = D100HWorkspaceState()
    private var d100hUnlockTask: Task<Void, Never>?
    private var d100hWorkspaceObservers: [NSObjectProtocol] = []
    private var listener: Listener?
    private var pointerTracker: PointerTracker?
    private var frontmostTracker: FrontmostTracker?
    private let settings = ServiceSettings()
    private var settingsWindow: SettingsWindowController?
    private lazy var deviceSettings: DeviceSettingsController = {
        let controller = DeviceSettingsController(file: DevicePreferencesFile(url: PointerDevices.configURL),
                                                  preferences: settings, gestureDiagnostics: gestureDiagnostics)
        controller.gestureServiceStatus = { [weak self] testClient in
            let client = self?.service?.clients.first { peer in testClient.map { $0 == peer.pid } ?? peer.owner }
            return GestureServiceStatus(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                                            as? String ?? "Unknown version",
                                        activeClient: client?.bundleID, listening: self?.tap != nil)
        }
        controller.gestureTestChanged = { [weak self] in self?.updateTap() }
        controller.connectedDevices = { [weak self] in self?.pointer.connectedDevices ?? [] }
        controller.didSave = { [weak self] in
            Task { await self?.pointer.reloadFromDisk() }
        }
        return controller
    }()

    private var gesturesOn: Bool { settings.gesturesEnabled }

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
        pointer.onSettingsChange = { [weak self] in
            guard let self, self.settingsWindow?.window?.isVisible == true else { return }
            Task { await self.deviceSettings.refresh() }
        }
        pointer.start()
        updateTap()
        startService()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.d100hWorkspaceChanged(name) }
            }
            d100hWorkspaceObservers.append(observer)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(d100hScreenChanged(_:)),
                                                             name: Self.screenUnlocked, object: nil,
                                                             suspensionBehavior: .deliverImmediately)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard service != nil else { return .terminateNow }
        d100h.stop {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        d100hUnlockTask?.cancel()
        for observer in d100hWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        DistributedNotificationCenter.default().removeObserver(self)
        tap?.stop()
        scrollTap?.stop()
        pointer.stop()
        driver?.releaseAllSync()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if settingsWindow?.window?.isVisible == true { deviceSettings.refreshAccessibility() }
        refreshD100HDaemon()
    }

    @objc private func d100hScreenChanged(_ notification: Notification) {
        if let user = notification.object as? String, let uid = uid_t(user), uid != getuid() { return }
        d100hWorkspaceChanged(notification.name)
    }

    private func d100hWorkspaceChanged(_ name: Notification.Name) {
        let event: D100HWorkspaceState.Event
        switch name {
        case NSWorkspace.willSleepNotification: event = .sleep
        case NSWorkspace.didWakeNotification: event = .wake
        case NSWorkspace.sessionDidResignActiveNotification: event = .sessionInactive
        case NSWorkspace.sessionDidBecomeActiveNotification: event = .sessionActive
        case Self.screenUnlocked: event = .screenUnlocked
        default: return
        }
        d100hWorkspaceState.handle(event)
        if name == Self.screenUnlocked {
            d100hUnlockTask?.cancel()
            d100hUnlockTask = Task { [weak self] in
                // loginwindow announces unlock before finishing its UI teardown (250 ms in the sleep trace).
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                self?.d100hUnlockTask = nil
                self?.reconcileD100HWorkspace()
            }
        } else {
            if !d100hWorkspaceState.isActive {
                d100hUnlockTask?.cancel()
                d100hUnlockTask = nil
            }
            reconcileD100HWorkspace()
        }
    }

    private func reconcileD100HWorkspace() {
        let active = d100hWorkspaceState.isActive
        guard !active || d100hUnlockTask == nil else { return }
        if active {
            service?.frontmost(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            refreshD100HDaemon()
        }
        d100h.setSessionActive(active)
    }

    // MARK: Service

    private func startService() {
        let driver = LogiMouseDriver(hapticStrength: settings.hapticStrength, panelForce: settings.panelForce)
        driver.onBatteryChange = { [weak self] in self?.updateMouseStatus() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let service = Service(driver: driver, version: version, globalMode: settings.wheelMode, d100h: d100h)
        d100h.start()
        // A SmartShift press where no app asks for a mode is the user's choice: kept as the setting.
        service.onGlobalModeChange = { [weak self] mode in
            try? self?.settings.setValue(mode == .freeSpin ? "free-spin" : "ratchet", forKey: ServiceSettings.wheelModeKey)
        }
        let tracker = PointerTracker { [weak service] place in service?.pointer(place) }
        service.onFollowsPointerChange = { [weak tracker] on in tracker?.setActive(on) }
        service.onClientPIDsChange = { [clickTargets] pids in
            clickTargets.withLock { $0.clients = pids }
        }
        frontmostTracker = FrontmostTracker { [clickTargets, weak service, weak tracker, weak self] pid in
            clickTargets.withLock { $0.frontmost = pid }
            service?.frontmost(pid: pid)
            tracker?.invalidate()
            if self?.d100hDaemonStatus == .requiresApproval { self?.refreshD100HDaemon() }
        }
        settings.onChange = { [weak self, weak driver, weak service] in
            guard let self, let driver else { return }
            driver.setHapticStrength(settings.hapticStrength)
            driver.setPanelForce(settings.panelForce)
            service?.setGlobalMode(settings.wheelMode)
            self.updateTap()
        }
        listener = Listener(machService: MouseClient.serviceName, service: service)
        // Clients that lost a service wait for this rather than wake it themselves (a quit service stays quit).
        DistributedNotificationCenter.default().postNotificationName(MouseClient.serviceStarted, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        self.driver = driver
        self.service = service
        pointerTracker = tracker
        refreshD100HDaemon()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.updateTap()
            if self.settingsWindow != nil { self.deviceSettings.refreshAccessibility() }
        }
    }

    private func updateTap() {
        let wanted = (gesturesOn || gestureDiagnostics.isRunning) && synth != nil && AXIsProcessTrusted()
        let preferences = settings.sideButtons
        if wanted, tap == nil, let synth {
            let tap = SideButtonTap(synth: synth, clickTargets: clickTargets, preferences: preferences,
                                    diagnostics: gestureDiagnostics) { [weak self] phase, time, pid in
                DispatchQueue.main.async {
                    _ = self?.service?.swipe(phase, time: time, targetPID: pid)
                }
            }
            if tap.start() { self.tap = tap }
        } else if wanted {
            tap?.updatePreferences(preferences)
        } else if !wanted, let tap {
            tap.stop()
            self.tap = nil
        }
        // The scroll rules need only the permission; gestures off leaves them on.
        if scrollTap == nil, AXIsProcessTrusted(), let scroll = ScrollTap(rules: pointer.scrollRules), scroll.start() {
            scrollTap = scroll
        }
    }

    // MARK: Menu

    private func updateMouseStatus() {
        guard let mouseStatusItem else { return }
        guard let driver, driver.device.present else {
            mouseStatusItem.title = "MX Master disconnected"
            return
        }
        guard let battery = driver.battery else {
            mouseStatusItem.title = "MX Master connected"
            return
        }
        let charge = "MX Master · \(battery.percent)%"
        mouseStatusItem.title = battery.isCharging ? "\(charge) · Charging" : charge
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshD100HDaemon()
        menu.removeAllItems()
        let settingsItem = item("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let mouseStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(mouseStatus)
        mouseStatusItem = mouseStatus
        updateMouseStatus()
        driver?.refreshBattery()
        let gestures = item("Side-Button Gestures", #selector(toggleGestures))
        let controls = settings.sideButtons
        gestures.state = controls.pageSwipes && controls.dragButton != nil ? .on : (gesturesOn ? .mixed : .off)
        if synth == nil { gestures.action = nil }
        menu.addItem(gestures)
        if !AXIsProcessTrusted() {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        } else if synth == nil || (gesturesOn && tap == nil) {
            menu.addItem(NSMenuItem(title: "Side-button gestures unavailable", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Release All Mouse Buttons", #selector(releaseAll)))
        if let d100hDaemonStatus {
            let dialItem: NSMenuItem
            switch d100hDaemonStatus {
            case .enabled:
                dialItem = NSMenuItem(title: "D100H Auto-Start Enabled", action: nil, keyEquivalent: "")
            case .requiresApproval:
                dialItem = item("Approve D100H Auto-Start…", #selector(enableD100HDaemon))
            default:
                dialItem = item("Enable D100H Auto-Start…", #selector(enableD100HDaemon))
            }
            menu.addItem(dialItem)
        }
        menu.addItem(advancedMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MouseService", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func advancedMenuItem() -> NSMenuItem {
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: pointer.summary, action: nil, keyEquivalent: ""))
        menu.addItem(item("Edit Device Rules…", #selector(editDevicesConfig)))
        menu.addItem(item("Reload Device Rules", #selector(reloadDevicesConfig)))
        menu.addItem(.separator())

        let clients = service?.clients ?? []
        let clientsItem = NSMenuItem(title: clients.isEmpty ? "No connected apps" : "Connected Apps",
                                     action: nil, keyEquivalent: "")
        if !clients.isEmpty {
            let submenu = NSMenu()
            for client in clients {
                let row = NSMenuItem(title: "\(client.bundleID) (\(client.pid))", action: nil, keyEquivalent: "")
                row.state = client.owner ? .on : .off
                submenu.addItem(row)
            }
            clientsItem.submenu = submenu
        }
        menu.addItem(clientsItem)
        let held = (0..<32).filter { NSEvent.pressedMouseButtons & (1 << $0) != 0 }
        if !held.isEmpty {
            let numbers = held.map(String.init).joined(separator: ", ")
            menu.addItem(NSMenuItem(title: "Buttons held by macOS: \(numbers)", action: nil, keyEquivalent: ""))
        }
        advanced.submenu = menu
        return advanced
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem?.menu { mouseStatusItem = nil }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func releaseAll() { service?.releaseAll() }

    private func refreshD100HDaemon() {
        guard d100hStatusTask == nil else { return }
        d100hStatusTask = Task { [weak self] in
            let status = await Self.d100hRegistration()
            guard let self, !Task.isCancelled else { return }
            d100hStatusTask = nil
            d100hDaemonStatus = status
            d100h.allowDaemon(status == .enabled)
        }
    }

    @objc private func enableD100HDaemon() {
        d100hStatusTask?.cancel()
        d100hStatusTask = Task { [weak self] in
            let (status, error) = await Self.registerD100H()
            guard let self else { return }
            d100hStatusTask = nil
            d100hDaemonStatus = status
            d100h.allowDaemon(status == .enabled)
            if status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if let error {
                let alert = NSAlert()
                alert.messageText = "Could not enable D100H auto-start"
                alert.informativeText = error
                alert.runModal()
            }
        }
    }

    @concurrent private static func d100hRegistration() async -> SMAppService.Status? {
        var code: SecCode?
        var executable: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &executable) == errSecSuccess, let executable,
              SecCodeCopySigningInformation(executable, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else { return nil }
        return SMAppService.daemon(plistName: "local.mouseservice.d100h.plist").status
    }

    @concurrent private static func registerD100H() async -> (SMAppService.Status, String?) {
        let service = SMAppService.daemon(plistName: "local.mouseservice.d100h.plist")
        do {
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            return (service.status, nil)
        } catch {
            return (service.status, error.localizedDescription)
        }
    }

    @objc private func toggleGestures() {
        try? settings.setValue(gesturesOn ? "no" : "yes", forKey: ServiceSettings.gesturesKey)
    }

    @objc private func editDevicesConfig() {
        PointerDevices.ensureConfigFile()
        NSWorkspace.shared.open(PointerDevices.configURL)
    }

    @objc private func reloadDevicesConfig() {
        Task { await pointer.reloadFromDisk() }
    }

    @objc private func openAccessibility() {
        DeviceSettingsController.openAccessibilitySettings()
    }

    @objc private func openSettings() {
        let window = settingsWindow ?? deviceSettings.makeSettingsWindow()
        settingsWindow = window
        window.show(page: nil)
        // A status menu can open while another app is active.
        window.window?.orderFrontRegardless()
        NSApp.activate()
        Task { await deviceSettings.refresh() }
    }
}
