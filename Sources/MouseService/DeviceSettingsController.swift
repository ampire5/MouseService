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
    private(set) var pointerProfile: PointerProfile = .macOS
    private(set) var speed = ""
    private(set) var acceleration = ""
    private(set) var disableAcceleration = false
    private(set) var reverse = "none"
    private(set) var dropVertical = ""
    private(set) var dropHorizontal = ""
    private(set) var isSaving = false
    private(set) var ready = false
    private(set) var error: String?
    private(set) var transferError: String?
    private(set) var transferMessage: String?
    private(set) var transferInProgress: String?
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    @ObservationIgnored private let file: DevicePreferencesFile
    @ObservationIgnored private let preferences: ServiceSettings
    @ObservationIgnored var connectedDevices: () -> [DeviceIdentity] = { [] }
    @ObservationIgnored var didSave: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seenNonMouseModels: Set<String> = []

    init(file: DevicePreferencesFile, preferences: ServiceSettings) {
        self.file = file
        self.preferences = preferences
    }

    func makeSettingsWindow(autosaveName: String = "MouseServiceSettings",
                            lastPageDefaultsKey: String = "SettingsLastPage") -> SettingsWindowController {
        SettingsWindowController(pages: pages, model: SettingsModel(store: preferences),
                                 autosaveName: autosaveName, lastPageDefaultsKey: lastPageDefaultsKey, style: .plain)
    }

    var selection: SettingsDevice? { devices.first { $0.id == selectedID } }
    var selectedDevice: DeviceIdentity? { selection?.identity }

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
            }
            try await readSelection(request: request)
            if request == generation { ready = true; error = nil }
        } catch {
            if request == generation { self.error = error.localizedDescription; ready = false }
        }
    }

    func select(_ id: String) async {
        guard !isSaving, devices.contains(where: { $0.id == id }) else { return }
        selectedID = id
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
    func set(_ field: String, value: String, for deviceID: String? = nil) async -> Bool {
        guard deviceID == nil || deviceID == selectedID else { return false }
        guard ready, !isSaving, let device = selectedDevice else { return false }
        isSaving = true
        generation += 1
        let request = generation
        defer { isSaving = false }
        do {
            _ = try await file.edit(field, value: value, device: device)
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
        guard let device = selectedDevice else { return }
        let values = try await file.values(for: device)
        guard request == generation else { return }
        pointerProfile = values.pointerProfile
        speed = values.speed
        acceleration = values.acceleration
        disableAcceleration = values.disableAcceleration
        reverse = values.reverse
        dropVertical = values.dropVertical
        dropHorizontal = values.dropHorizontal
    }
}
