import AppKit
import IOKit
import IOKit.hidsystem
import os
import PointerCore

/// The scroll rule of each device by its service's registry ID (the sender ID of its events): written on the main
/// thread when the rules, the devices or the frontmost app change, read by `ScrollTap` for every scroll event.
final class ScrollRules: Sendable {
    private let rules = OSAllocatedUnfairLock(initialState: [UInt64: ScrollRule]())

    func rule(for sender: UInt64) -> ScrollRule? { rules.withLock { $0[sender] } }
    func set(_ new: [UInt64: ScrollRule]) { rules.withLock { $0 = new } }
    var isEmpty: Bool { rules.withLock { $0.isEmpty } }
}

/// LinearMouse's part (pointer and wheel spec): the rules of `~/.config/mouseservice/config.yaml` applied to every
/// mouse and trackpad. Pointer speed and acceleration are the devices' own HID properties, written when a device
/// appears, the rules change or (with app rules) another app comes in front, and only when they differ from what was
/// written; the values a device had when first seen go back when no rule covers it any more and at quit. The scroll
/// rules go to `scrollRules` for the tap. Nothing runs at rest: IOKit says when a device comes or goes, the file
/// source when the config changes.
@MainActor final class PointerDevices {
    let scrollRules = ScrollRules()
    var onSettingsChange: (() -> Void)?
    var connectedDevices: [DeviceIdentity] { devices.values.map(\.identity).sorted {
        ($0.productName ?? "") < ($1.productName ?? "")
    } }
    /// For the menu: how many schemes and devices, or what is wrong with the file.
    var summary: String {
        if let rulesError { return "config.yaml: \(rulesError)" }
        let set = devices.values.filter { $0.applied != nil || scrollRules.rule(for: $0.id) != nil }.count
        return "Devices: \(rules.count) configured, \(set) of \(devices.count) set"
    }

    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mouseservice/config.yaml")
    /// What the config was before 2026-10-28: LinearMouse's schemes; migrated once into `config.yaml`.
    private static let legacyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mouseservice/devices.json")
    private static let linearMouseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/linearmouse/linearmouse.json")
    private static let log = Logger(subsystem: "local.mouseservice", category: "Pointer")

    private struct Device {
        let id: UInt64
        var service: any PointerDeviceService
        let identity: DeviceIdentity
        /// The property the acceleration goes to (`HIDPointerAccelerationType`).
        let accelerationKey: String
        /// The values before MouseService wrote any (nil: the device did not report one, nothing to give back).
        let original: (resolution: CFTypeRef?, acceleration: CFTypeRef?, linear: CFTypeRef?)
        /// What MouseService last wrote; nil: nothing, the device has its own values.
        var applied: PointerSettings?
        /// A failed write must be retried even when the requested settings have not changed.
        var needsApply = false
    }

    private let services: () -> [any PointerDeviceService]?
    private let rulesURL: URL
    private var devices: [UInt64: Device] = [:]
    /// Keep originals through the immediate and delayed wake scans, even if HID briefly lists no services.
    private var wakingDevices: [UInt64: Device] = [:]
    private var rules = DeviceRules.empty
    /// What is wrong with config.yaml; the rules read before stay in force.
    private var rulesError: String?
    private var loadGeneration = 0
    private var frontmost: String?
    private var appObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var fileSource: DispatchSourceFileSystemObject?
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var rescanLater: DispatchWorkItem?
    private var forceRescanLater = false

    init(configURL: URL = PointerDevices.configURL, services: (() -> [any PointerDeviceService]?)? = nil) {
        rulesURL = configURL
        if let services {
            self.services = services
            return
        }
        let client: IOHIDEventSystemClient?
        // The public simple client cannot read the pointer properties; the full one can (checked 2026-10-27).
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
        if let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
           let create = dlsym(iokit, "IOHIDEventSystemClientCreate") {
            client = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
        } else {
            client = nil
        }
        if client == nil { Self.log.error("IOHIDEventSystemClientCreate not found: pointer settings off") }
        self.services = {
            guard let client, let list = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else { return nil }
            return list.compactMap { SystemPointerDeviceService(unsafeDowncast($0, to: IOHIDServiceClient.self)) }
        }
    }

    func start() {
        if rulesURL == Self.configURL { migrateIfNeeded() }
        Self.ensureConfigFile(at: rulesURL)
        loadRules()
        watchConfig()
        watchDevices()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.activated(app) }
        }
        rescan()
    }

    func systemDidWake() {
        Self.log.notice("System woke: refreshing pointer services and settings")
        for (id, device) in devices where wakingDevices[id] == nil { wakingDevices[id] = device }
        deviceListChanged(force: true)
    }

    private func activated(_ app: String?) {
        guard app != frontmost else { return }
        frontmost = app
        if rules.dependsOnApp { reapply(force: false) }
    }

    /// Reads the file again and writes every device's settings anew (another program may have changed them).
    func reload() {
        loadGeneration += 1
        loadRules()
        reapply(force: true)
        onSettingsChange?()
    }

    /// The interactive/file-watcher path parses away from the main actor, then applies only the newest result.
    func reloadFromDisk() async {
        loadGeneration += 1
        let request = loadGeneration
        let url = rulesURL
        do {
            let parsed = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: url)
                return try DeviceRules(yaml: String(decoding: data, as: UTF8.self))
            }.value
            guard request == loadGeneration else { return }
            rules = parsed
            rulesError = nil
            reapply(force: true)
            onSettingsChange?()
        } catch {
            guard request == loadGeneration else { return }
            rulesError = error.localizedDescription
            onSettingsChange?()
        }
    }

    /// Gives every device the values it had before MouseService: at quit.
    func restoreAll() {
        for id in devices.keys { restore(id) }
    }

    // MARK: Rules

    /// The first start without `config.yaml`: the old `devices.json` (kept as `devices.json.bak`), else LinearMouse's own
    /// file, written as YAML (`DevicesMigration`).
    private func migrateIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.configURL.path) else { return }
        let (source, name): (URL, String) = fm.fileExists(atPath: Self.legacyURL.path)
            ? (Self.legacyURL, "devices.json") : (Self.linearMouseURL, "LinearMouse's configuration")
        guard let data = try? Data(contentsOf: source) else { return }
        do {
            let yaml = DevicesMigration.yaml(from: try LegacyDeviceRules(json: data), source: name)
            try fm.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try yaml.write(to: Self.configURL, atomically: true, encoding: .utf8)
            if source == Self.legacyURL {
                try fm.moveItem(at: source, to: source.appendingPathExtension("bak"))
            }
            Self.log.notice("Migrated \(name, privacy: .public) into config.yaml")
        } catch {
            Self.log.error("Migration to config.yaml failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The file `Edit Devices Config…` opens: made with a short example when there is none.
    static func ensureConfigFile(at configURL: URL = PointerDevices.configURL) {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.template.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static let template = """
    # MouseService: pointer and wheel per device. Saved changes are read at once.
    # A device is named once; its id is vendor:product in hex (the menu's device list or System Information shows them).
    #
    # devices:
    #   MX Master 4:
    #     id: 46d:c548
    #     speed: 0.125                  # 0…1
    #     acceleration: 0.225           # 0…40
    #     disable-acceleration: false
    #     reverse-scroll: vertical      # none | vertical | horizontal | both
    #     ignore-horizontal-scroll-with: [command, control]   # also ignore-vertical-scroll-with; shift, option
    #     apps:
    #       com.example.App: { speed: 0.066 }    # the frontmost app's bundle ID; the same fields
    #   Some trackpad:
    #     id: 4c:265
    #     serial: "AA:BB:CC:DD:EE:FF"    # optional: only that unit

    devices:

    """

    /// A broken file keeps the rules in force and says so in the menu.
    private func loadRules() {
        guard let data = try? Data(contentsOf: rulesURL) else {
            rules = .empty
            rulesError = "missing"
            return
        }
        do {
            rules = try DeviceRules(yaml: String(decoding: data, as: UTF8.self))
            if !rules.ignoredFields.isEmpty {
                Self.log.notice("config.yaml: ignored \(self.rules.ignoredFields.joined(separator: ", "), privacy: .public)")
            }
            rulesError = nil
        } catch {
            rulesError = "\(error)"
            Self.log.error("config.yaml: \(String(describing: error), privacy: .public)")
        }
    }

    /// The file is watched itself; an editor that saves by replacing it ends the watch, which is then set up anew.
    private func watchConfig() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(rulesURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            MainActor.assumeIsolated {
                guard let self else { return }
                if replaced { self.watchConfig() }
                Task { await self.reloadFromDisk() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    // MARK: Devices

    /// IOKit tells when a HID device comes or goes; the event system lists its services a moment later, so the list is
    /// read now and once more after a second.
    private func watchDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { info, iterator in
            while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
            let devices = Unmanaged<PointerDevices>.fromOpaque(info!).takeUnretainedValue()
            MainActor.assumeIsolated { devices.deviceListChanged() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOHIDDevice"), callback, me, &iterator)
            while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }   // arms it
            iterators.append(iterator)
        }
    }

    func deviceListChanged(force: Bool = false) {
        rescan(force: force)
        // Hotplug notifications during wake may reschedule the scan, but must not lose the forced reapply.
        forceRescanLater = forceRescanLater || force
        rescanLater?.cancel()
        let later = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let force = forceRescanLater
            forceRescanLater = false
            rescanLater = nil
            rescan(force: force)
            wakingDevices.removeAll()
        }
        rescanLater = later
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: later)
    }

    func rescan(force: Bool = false) {
        defer { onSettingsChange?() }
        guard let list = services() else { return }
        var seen = Set<UInt64>()
        for service in list {
            let id = service.id
            seen.insert(id)
            if var device = devices[id] ?? wakingDevices[id] {
                // A resumed service may have the same registry ID but a new client handle. Keep the original
                // properties: reading them again here could capture our own previously applied settings.
                device.service = service
                devices[id] = device
                continue
            }
            let identity = service.identity
            let accelerationKey = service.accelerationKey
            devices[id] = Device(id: id, service: service, identity: identity, accelerationKey: accelerationKey,
                                 original: (service.property("HIDPointerResolution"), service.property(accelerationKey),
                                            service.property("HIDUseLinearScalingMouseAcceleration")),
                                 applied: nil)
            Self.log.info("Device \(identity.productName ?? "?", privacy: .public) \(String(format: "%04x:%04x", identity.vendorID, identity.productID), privacy: .public) \(identity.category.rawValue, privacy: .public)")
        }
        for id in devices.keys where !seen.contains(id) { devices[id] = nil }
        reapply(force: force)
    }

    /// Every device's pointer settings and the scroll snapshot from the rules and the frontmost app.
    private func reapply(force: Bool) {
        var scroll: [UInt64: ScrollRule] = [:]
        for id in devices.keys {
            guard let device = devices[id] else { continue }
            let resolved = rules.resolve(device.identity, app: frontmost)
            if resolved.scroll != .none { scroll[id] = resolved.scroll }
            if resolved.pointer.isEmpty {
                if device.applied != nil { restore(id) }
            } else if force || device.needsApply || resolved.pointer != device.applied {
                write(resolved.pointer, to: id)
            }
        }
        scrollRules.set(scroll)
    }

    private func write(_ settings: PointerSettings, to id: UInt64) {
        guard var device = devices[id] else { return }
        let s = device.service
        var succeeded = true
        func set(_ key: String, _ value: CFTypeRef?) {
            guard let value else { return }
            if !s.setProperty(key, value) {
                succeeded = false
                Self.log.error("Could not set \(key, privacy: .public) on \(device.identity.productName ?? "?", privacy: .public)")
            }
        }
        // Truncated, as LinearMouse writes it: the same numbers in the device.
        func fixed(_ v: Double) -> CFTypeRef { NSNumber(value: Int32(clamping: Int(v * 65536))) }
        // Written whenever a rule covers the device, as LinearMouse does: the system's default is 1 (linear scaling),
        // and with it LinearMouse's accelerations make the pointer far slower (seen 2026-10-27).
        let linear = settings.disableAcceleration == true
        if device.original.linear != nil {
            set("HIDUseLinearScalingMouseAcceleration", NSNumber(value: linear ? 1 : 0))
        }
        if let speed = settings.speed {
            set("HIDPointerResolution", fixed(min(max(PointerMath.resolution(speed: speed), 10), 1995)))
        } else {
            set("HIDPointerResolution", device.original.resolution)
        }
        // The resolution takes effect once the acceleration is written after it (LinearMouse's PointerKit).
        if linear && device.original.linear == nil {
            set(device.accelerationKey, fixed(-1))
        } else if let acceleration = settings.acceleration {
            set(device.accelerationKey, fixed(acceleration))
        } else {
            set(device.accelerationKey, device.original.acceleration)
        }
        device.applied = settings
        device.needsApply = !succeeded
        devices[id] = device
        Self.log.info("\(device.identity.productName ?? "?", privacy: .public): speed \(settings.speed ?? -1) acceleration \(settings.acceleration ?? -1)")
    }

    private func restore(_ id: UInt64) {
        guard var device = devices[id], device.applied != nil else { return }
        let s = device.service
        if let v = device.original.linear { _ = s.setProperty("HIDUseLinearScalingMouseAcceleration", v) }
        if let v = device.original.resolution { _ = s.setProperty("HIDPointerResolution", v) }
        if let v = device.original.acceleration { _ = s.setProperty(device.accelerationKey, v) }
        device.applied = nil
        device.needsApply = false
        devices[id] = device
    }
}
