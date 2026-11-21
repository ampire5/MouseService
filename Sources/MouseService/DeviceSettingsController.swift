import AppKit
import ApplicationServices
import Observation
import PointerCore
import SettingsKit
import UniformTypeIdentifiers

struct SettingsDevice: Identifiable, Sendable {
    let identity: DeviceIdentity
    let connected: Bool
    var id: String { Self.key(identity) }
    private var name: String { identity.productName.flatMap { $0.isEmpty ? nil : $0 } ?? "Mouse" }
    var title: String { connected ? name : "\(name) (offline)" }
    static func key(_ device: DeviceIdentity) -> String {
        modelKey(device) + "/" + (device.serialNumber ?? "")
    }
    static func modelKey(_ device: DeviceIdentity) -> String { String(format: "%x:%x", device.vendorID, device.productID) }
}

/// The device pane's state. No disk reads, writes or import parsing run on the main actor.
@MainActor @Observable final class DeviceSettingsController {
    var devices: [SettingsDevice] = []
    private(set) var selectedID = ""
    private(set) var selectedApplicationID: String?
    private(set) var applicationIDs: [String] = []
    private var fields: [String: DeviceConfigDocument.Setting] = [:]
    private var applicationNames: [String: String] = [:]
    private(set) var isSaving = false
    private(set) var ready = false
    private(set) var error: String?
    private(set) var transferError: String?
    private(set) var transferMessage: String?
    private(set) var transferInProgress: String?
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    @ObservationIgnored private let file: DevicePreferencesFile
    @ObservationIgnored private let preferences: ServiceSettings
    @ObservationIgnored let gestureDiagnostics: GestureDiagnostics
    @ObservationIgnored var gestureServiceStatus: (pid_t?) -> GestureServiceStatus? = { _ in nil }
    @ObservationIgnored var gestureTestChanged: (() -> Void)?
    @ObservationIgnored var connectedDevices: () -> [DeviceIdentity] = { [] }
    @ObservationIgnored var didSave: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seenNonMouseModels: Set<String> = []

    init(file: DevicePreferencesFile, preferences: ServiceSettings,
         gestureDiagnostics: GestureDiagnostics = GestureDiagnostics()) {
        self.file = file
        self.preferences = preferences
        self.gestureDiagnostics = gestureDiagnostics
    }

    func makeSettingsWindow(autosaveName: String = "MouseServiceSettings",
                            lastPageDefaultsKey: String = "SettingsLastPage") -> SettingsWindowController {
        SettingsWindowController(pages: pages, model: SettingsModel(store: preferences),
                                 autosaveName: autosaveName, lastPageDefaultsKey: lastPageDefaultsKey, style: .plain)
    }

    var selection: SettingsDevice? { devices.first { $0.id == selectedID } }
    var selectedDevice: DeviceIdentity? { selection?.identity }
    var appFields: [String: DeviceConfigDocument.Setting] { selectedApplicationID == nil ? [:] : fields }
    var pointerProfile: PointerProfile {
        PointerProfile(rawValue: fields["pointer-profile"]?.value ?? "") ?? .macOS
    }
    var speed: String { fields["speed"]?.value ?? "" }
    var acceleration: String { fields["acceleration"]?.value ?? "" }
    var disableAcceleration: Bool { fields["disable-acceleration"]?.value == "yes" }
    var reverse: String { fields["reverse-scroll"]?.value ?? "none" }
    var dropVertical: String { fields["ignore-vertical-scroll-with"]?.value ?? "" }
    var dropHorizontal: String { fields["ignore-horizontal-scroll-with"]?.value ?? "" }

    var applicationChoices: [String] {
        var ids = Set(applicationIDs)
        if let selectedApplicationID { ids.insert(selectedApplicationID) }
        return ids.sorted {
            let order = applicationTitle($0).localizedStandardCompare(applicationTitle($1))
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }

    func applicationTitle(_ id: String) -> String { applicationNames[id] ?? id }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func refresh() async {
        guard !isSaving else { return }
        ready = false
        generation += 1
        let request = generation
        refreshAccessibility()
        let connected = connectedDevices()
        seenNonMouseModels.formUnion(connected.filter { $0.category == .other }.map(SettingsDevice.modelKey))
        seenNonMouseModels.subtract(connected.filter { $0.category == .mouse }.map(SettingsDevice.modelKey))
        do {
            let saved = try await file.mice()
            guard request == generation else { return }
            var choices = connected.map { SettingsDevice(identity: $0, connected: true) }
            for device in saved where !seenNonMouseModels.contains(SettingsDevice.modelKey(device)) && !choices.contains(where: {
                $0.identity.vendorID == device.vendorID && $0.identity.productID == device.productID
                    && (device.serialNumber == nil || $0.identity.serialNumber == device.serialNumber)
            }) {
                choices.append(SettingsDevice(identity: device, connected: false))
            }
            var seen: Set<String> = []
            devices = choices.filter { $0.identity.category == .mouse && seen.insert($0.id).inserted }
            if !devices.contains(where: { $0.id == selectedID }) {
                selectedID = devices.first?.id ?? ""
                selectedApplicationID = nil
            }
            try await readSelection(request: request)
            if request == generation { ready = true; error = nil }
        } catch {
            if request == generation { self.error = error.localizedDescription; ready = false }
        }
    }

    func select(_ id: String) async {
        guard !isSaving, devices.contains(where: { $0.id == id }) else { return }
        if id != selectedID { selectedApplicationID = nil }
        selectedID = id
        await loadSelection()
    }

    func selectApplication(_ id: String?) async {
        guard !isSaving, selectedDevice != nil, id != selectedApplicationID else { return }
        selectedApplicationID = id
        await loadSelection()
    }

    private func loadSelection() async {
        ready = false
        generation += 1
        let request = generation
        do {
            try await readSelection(request: request)
            if request == generation { ready = true; error = nil }
        } catch {
            if request == generation { self.error = error.localizedDescription }
        }
    }

    @discardableResult
    func set(_ field: String, value: String?, for deviceID: String? = nil, app: String? = nil) async -> Bool {
        guard (deviceID == nil || deviceID == selectedID), app == selectedApplicationID else { return false }
        guard ready, !isSaving, let device = selectedDevice else { return false }
        isSaving = true
        generation += 1
        let request = generation
        defer { isSaving = false }
        do {
            if let app {
                try await file.editApplication(app, field: field, value: value, device: device)
            } else if let value {
                _ = try await file.edit(field, value: value, device: device)
            } else {
                return false
            }
            try await readSelection(request: request)
            error = nil
            didSave?()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func export(to url: URL) async {
        guard !isSaving else { return }
        isSaving = true
        transferInProgress = "Exporting settings…"
        transferError = nil
        transferMessage = nil
        defer {
            isSaving = false
            transferInProgress = nil
        }
        do {
            try await file.export(to: url, preferences: preferences.exportedValues)
            transferMessage = "Exported to \(url.lastPathComponent)."
        } catch { transferError = error.localizedDescription }
    }

    func importSettings(from url: URL) async {
        guard !isSaving else { return }
        isSaving = true
        transferInProgress = "Importing settings…"
        transferError = nil
        transferMessage = nil
        do {
            let bundle = try await file.importBundle(from: url, currentPreferences: preferences.exportedValues)
            preferences.applyImportedValues(bundle.preferences)
            transferMessage = "Settings imported. A backup was saved beside config.yaml."
            didSave?()
        } catch { transferError = error.localizedDescription }
        isSaving = false
        transferInProgress = nil
        if transferError == nil { await refresh() }
    }

    func showExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MouseService-settings.json"
        panel.title = "Export MouseService Settings"
        present(panel) { [weak self] url in
            await self?.export(to: url)
        }
    }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import MouseService Settings"
        panel.message = "Replaces device rules and the preferences in this file. The previous configuration is backed up."
        panel.prompt = "Import"
        present(panel) { [weak self] url in
            await self?.importSettings(from: url)
        }
    }

    func showApplicationPanel() {
        guard ready, let deviceID = selection?.id else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.title = "Choose an Application"
        panel.prompt = "Choose"
        present(panel) { [weak self] url in
            let chosen = await Task.detached(priority: .userInitiated) { () -> (id: String, name: String)? in
                guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else { return nil }
                return (id, Self.applicationName(at: url))
            }.value
            guard let self, self.selectedID == deviceID, !self.isSaving else { return }
            guard let chosen else {
                self.error = "The selected application has no bundle identifier."
                return
            }
            self.applicationNames[chosen.id] = chosen.name
            await self.selectApplication(chosen.id)
        }
    }

    private nonisolated static func applicationName(at url: URL) -> String {
        let displayName = FileManager.default.displayName(atPath: url.path)
        return displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
    }

    private func present(_ panel: NSSavePanel, action: @escaping @MainActor (URL) async -> Void) {
        guard !isSaving else { return }
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await action(url) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func readSelection(request: Int) async throws {
        guard let device = selectedDevice else {
            fields = [:]
            applicationIDs = []
            return
        }
        let values = try await file.values(for: device, app: selectedApplicationID)
        guard request == generation else { return }
        fields = values.fields
        applicationIDs = values.applicationIDs
        let missingNames = applicationIDs.filter { applicationNames[$0] == nil }
        guard !missingNames.isEmpty else { return }
        let names = await Task.detached(priority: .userInitiated) {
            missingNames.reduce(into: [String: String]()) { names, id in
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    names[id] = Self.applicationName(at: url)
                }
            }
        }.value
        if request == generation {
            applicationNames.merge(names) { old, _ in old }
        }
    }
}
