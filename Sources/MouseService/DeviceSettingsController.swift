import AppKit
import ApplicationServices
import Observation
import PointerCore

struct SettingsDevice: Identifiable, Sendable {
    let identity: DeviceIdentity
    let connected: Bool
    var id: String { Self.key(identity) }
    var title: String {
        let name = identity.productName ?? (identity.category == .trackpad ? "Trackpad" : "Mouse")
        return name + (connected ? "" : " (not connected)")
    }
    static func key(_ device: DeviceIdentity) -> String {
        String(format: "%x:%x", device.vendorID, device.productID) + "/" + (device.serialNumber ?? "")
    }
}

/// The device pane's state. No disk reads, writes or import parsing run on the main actor.
@MainActor @Observable final class DeviceSettingsController {
    var devices: [SettingsDevice] = []
    private(set) var selectedID = ""
    private(set) var speed = ""
    private(set) var acceleration = ""
    private(set) var disableAcceleration = false
    private(set) var reverse = "none"
    private(set) var dropVertical = ""
    private(set) var dropHorizontal = ""
    private(set) var isSaving = false
    private(set) var ready = false
    var error: String?
    var message: String?
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    @ObservationIgnored private let file: DevicePreferencesFile
    @ObservationIgnored private let preferences: ServiceSettings
    @ObservationIgnored var connectedDevices: () -> [DeviceIdentity] = { [] }
    @ObservationIgnored var didSave: (() -> Void)?
    @ObservationIgnored private var generation = 0

    init(file: DevicePreferencesFile, preferences: ServiceSettings) {
        self.file = file
        self.preferences = preferences
    }

    var selectedDevice: DeviceIdentity? { devices.first { $0.id == selectedID }?.identity }

    func refresh() async {
        guard !isSaving else { return }
        ready = false
        generation += 1
        let request = generation
        accessibilityGranted = AXIsProcessTrusted()
        let connected = connectedDevices()
        do {
            let saved = try await file.devices()
            guard request == generation else { return }
            var choices = connected.map { SettingsDevice(identity: $0, connected: true) }
            for device in saved where !choices.contains(where: {
                $0.identity.vendorID == device.vendorID && $0.identity.productID == device.productID
                    && (device.serialNumber == nil || $0.identity.serialNumber == device.serialNumber)
            }) {
                choices.append(SettingsDevice(identity: device, connected: false))
            }
            var seen: Set<String> = []
            devices = choices.filter { seen.insert($0.id).inserted }
            if !devices.contains(where: { $0.id == selectedID }) {
                selectedID = devices.first(where: { $0.identity.category == .mouse })?.id ?? devices.first?.id ?? ""
            }
            try await readSelection(request: request)
            if request == generation { ready = true; error = nil }
        } catch {
            if request == generation { self.error = error.localizedDescription; ready = false }
        }
    }

    func select(_ id: String) async {
        guard !isSaving else { return }
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

    func set(_ field: String, value: String, for deviceID: String? = nil) async {
        guard deviceID == nil || deviceID == selectedID else { return }
        guard ready, !isSaving, let device = selectedDevice else { return }
        isSaving = true
        generation += 1
        let request = generation
        defer { isSaving = false }
        do {
            _ = try await file.edit(field, value: value, device: device)
            try await readSelection(request: request)
            error = nil
            message = "Saved. Changes apply immediately."
            didSave?()
        } catch { self.error = error.localizedDescription }
    }

    func export(to url: URL) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await file.export(to: url, preferences: preferences.exportedValues)
            error = nil
            message = "Settings exported."
        } catch { self.error = error.localizedDescription }
    }

    func importSettings(from url: URL) async {
        guard !isSaving else { return }
        isSaving = true
        do {
            let bundle = try await file.importBundle(from: url, currentPreferences: preferences.exportedValues)
            preferences.applyImportedValues(bundle.preferences)
            error = nil
            message = "Settings imported. The previous configuration was backed up."
            didSave?()
        } catch { self.error = error.localizedDescription }
        isSaving = false
        if error == nil { await refresh() }
    }

    func showExportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MouseService-settings.json"
        panel.title = "Export MouseService Settings"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.export(to: url) }
        }
    }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import MouseService Settings"
        panel.message = "Replaces device rules and the preferences in this file. The previous configuration is backed up."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.importSettings(from: url) }
        }
    }

    private func readSelection(request: Int) async throws {
        guard let device = selectedDevice else { return }
        let values = try await file.values(for: device)
        guard request == generation else { return }
        speed = values.speed
        acceleration = values.acceleration
        disableAcceleration = values.disableAcceleration
        reverse = values.reverse
        dropVertical = values.dropVertical
        dropHorizontal = values.dropHorizontal
    }
}
