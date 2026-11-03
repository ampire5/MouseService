import AppKit
import SettingsKit
import SwiftUI

extension DeviceSettingsController {
    var pages: [SettingsPage] {
        [SettingsPage("devices", "Devices", symbol: "computermouse", sections: [
            SettingsSection("Device", rows: [
                .custom("Selected device", searchTexts: { ["device", "mouse", "trackpad"] }) {
                    DeviceChooser(controller: self).preferredColorScheme(.dark)
                        .foregroundStyle(Color(red: 0.95, green: 0.95, blue: 0.97))
                },
            ]),
            SettingsSection("Pointer", rows: [
                .custom("Pointer sensitivity", searchTexts: { ["speed", "acceleration", "sensitivity"] }) {
                    PointerControls(controller: self).preferredColorScheme(.dark)
                        .foregroundStyle(Color(red: 0.95, green: 0.95, blue: 0.97))
                },
            ]),
            SettingsSection("Scrolling", rows: [
                .custom("Scroll direction and modifiers", searchTexts: { ["scroll", "reverse", "invert", "modifier"] }) {
                    ScrollControls(controller: self).preferredColorScheme(.dark)
                        .foregroundStyle(Color(red: 0.95, green: 0.95, blue: 0.97))
                },
            ]),
        ])] + ServiceSettings.pages + [SettingsPage("transfer", "Import & Export", symbol: "arrow.up.arrow.down", sections: [
            SettingsSection("Portable settings", rows: [
                .button("Export settings", "Export…", symbol: "square.and.arrow.up",
                        description: "Save device rules, gestures and Logitech preferences in one file.") { self.showExportPanel() },
                .button("Import settings", "Import…", symbol: "square.and.arrow.down",
                        description: "Restore settings from another Mac. Your current configuration is backed up first.") { self.showImportPanel() },
                .custom("Transfer status", searchTexts: { [] }) { SettingsStatus(controller: self) },
            ]),
        ])]
    }
}

private struct DeviceChooser: View {
    let controller: DeviceSettingsController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.devices.isEmpty {
                Text("No pointing devices found. Connect a mouse or import settings.")
            } else {
                Picker("Device", selection: Binding(get: { controller.selectedID }, set: { id in
                    Task { await controller.select(id) }
                })) {
                    ForEach(controller.devices) { device in Text(device.title).tag(device.id) }
                }
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .disabled(controller.isSaving)
                if let device = controller.selectedDevice {
                    Text(String(format: "Device ID: %x:%x", device.vendorID, device.productID))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsStatus(controller: controller)
        }
        .padding(14)
    }
}

private struct SettingsStatus: View {
    let controller: DeviceSettingsController
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if controller.isSaving {
                Text("Saving…").foregroundStyle(.secondary)
            } else if let message = controller.message {
                Text(message).foregroundStyle(.secondary)
            }
            if !controller.accessibilityGranted {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } label: {
                    Text("Allow Accessibility…").foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1))
                }
                .buttonStyle(.plain)
                Text("Accessibility is required for gestures and scroll rules.").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

private struct PointerControls: View {
    let controller: DeviceSettingsController
    var body: some View {
        let selection = controller.selectedID
        VStack(spacing: 12) {
            SensitivityControl(title: "Speed", value: controller.speed, range: 0...1) {
                await controller.set("speed", value: $0, for: selection)
            }
            Divider()
            SensitivityControl(title: "Acceleration", value: controller.acceleration, range: 0...40) {
                await controller.set("acceleration", value: $0, for: selection)
            }
            Divider()
            Toggle("Disable acceleration", isOn: Binding(get: { controller.disableAcceleration }, set: { value in
                Task { await controller.set("disable-acceleration", value: value ? "yes" : "no") }
            }))
            .toggleStyle(.switch)
        }
        .padding(14)
        .id(selection)
        .disabled(!controller.ready || controller.selectedDevice == nil || controller.isSaving)
    }
}

/// Drafts commit on Return or focus loss; dragging commits once at release, not for every pointer event.
private struct SensitivityControl: View {
    let title: String
    let value: String
    let range: ClosedRange<Double>
    let commit: @MainActor (String) async -> Void
    @State private var draft = ""
    @State private var sliderValue = 0.0
    @State private var dragging = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TextField("System value", text: $draft)
                    .frame(width: 95).multilineTextAlignment(.trailing).focused($focused)
                    .onSubmit { saveDraft() }
                    .onChange(of: focused) { _, active in if !active { saveDraft() } }
            }
            Slider(value: $sliderValue, in: range) { editing in
                dragging = editing
                if !editing {
                    let text = SettingsRow.sliderText(sliderValue)
                    draft = text
                    Task { await commit(text) }
                }
            }
            .accessibilityLabel(title)
            HStack {
                Text(String(format: "%g", range.lowerBound))
                Spacer()
                Text(String(format: "%g", range.upperBound))
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { sync() }
        .onChange(of: value) { _, _ in if !focused && !dragging { sync() } }
    }

    private func sync() {
        draft = value
        sliderValue = min(max(Double(value) ?? range.lowerBound, range.lowerBound), range.upperBound)
    }

    private func saveDraft() {
        let text = SettingsModel.normalizedNumber(draft)
        guard text != value else { return }
        Task { await commit(text) }
    }
}

private struct ScrollControls: View {
    let controller: DeviceSettingsController
    private let modifiers = [("command", "⌘"), ("shift", "⇧"), ("option", "⌥"), ("control", "⌃")]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Reverse scrolling", selection: Binding(get: { controller.reverse }, set: { value in
                Task { await controller.set("reverse-scroll", value: value) }
            })) {
                Text("None").tag("none")
                Text("Vertical").tag("vertical")
                Text("Horizontal").tag("horizontal")
                Text("Both axes").tag("both")
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            Divider()
            modifierRow("Ignore vertical scroll with", field: "ignore-vertical-scroll-with", value: controller.dropVertical)
            Divider()
            modifierRow("Ignore horizontal scroll with", field: "ignore-horizontal-scroll-with", value: controller.dropHorizontal)
        }
        .padding(14)
        .disabled(!controller.ready || controller.selectedDevice == nil || controller.isSaving)
    }

    private func modifierRow(_ title: String, field: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            HStack(spacing: 16) {
                ForEach(modifiers, id: \.0) { word, symbol in
                    Toggle(symbol, isOn: Binding(get: {
                        value.split(separator: ",").map(String.init).contains(word)
                    }, set: { enabled in
                        var chosen = Set(value.split(separator: ",").map(String.init))
                        if enabled { chosen.insert(word) } else { chosen.remove(word) }
                        let text = modifiers.map(\.0).filter { chosen.contains($0) }.joined(separator: ",")
                        Task { await controller.set(field, value: text) }
                    }))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(word.capitalized)
                }
            }
        }
    }
}
