import Accessibility
import AppKit
import PointerCore
import SettingsKit
import SwiftUI

extension DeviceSettingsController {
    var pages: [SettingsPage] {
        [SettingsPage("devices", "Pointer & Scrolling", symbol: "computermouse", sections: [
            SettingsSection("Mouse", rows: [
                .custom("Selected mouse", searchTexts: { ["device", "mouse", "connected", "offline"] }) {
                    DeviceChooser(controller: self)
                },
            ]),
            SettingsSection("Pointer", rows: [
                .custom("Pointer controls", searchTexts: { ["speed", "acceleration", "profile", "windows", "libinput", "linear"] }) {
                    if self.selectedDevice != nil {
                        PointerControls(controller: self).id(self.selectedID)
                    } else {
                        UnavailableMouseSetting("Select a mouse to adjust its tracking.")
                    }
                },
            ]),
            SettingsSection("Scrolling", rows: [
                .custom("Scroll direction and modifiers", searchTexts: {
                    ["scroll", "reverse", "invert", "modifier", "vertical", "horizontal", "accessibility"]
                }) {
                    if self.selectedDevice != nil {
                        ScrollControls(controller: self)
                    } else {
                        UnavailableMouseSetting("Select a mouse to adjust its scrolling.")
                    }
                },
            ]),
        ]), SettingsPage("mouse", "Buttons & Wheel", symbol: "hand.point.up.left", sections:
            ServiceSettings.controlSections + [
                SettingsSection("Accessibility", rows: [
                    .custom("Gesture permission", searchTexts: { ["permission", "accessibility", "gestures"] }) {
                        AccessibilitySetting(controller: self)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    },
                ]),
            ]
        ), SettingsPage("transfer", "Import & Export", symbol: "arrow.up.arrow.down", sections: [
            SettingsSection("Back Up or Move Settings", rows: [
                .custom("Import and export settings", searchTexts: { ["backup", "export", "import", "restore", "json"] }) {
                    TransferControls(controller: self)
                },
            ]),
        ])]
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct DeviceChooser: View {
    let controller: DeviceSettingsController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let device = controller.selection {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "computermouse")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Mouse", selection: Binding(get: { controller.selectedID }, set: { id in
                            Task { await controller.select(id) }
                        })) {
                            ForEach(controller.devices) { mouse in Text(mouse.title).tag(mouse.id) }
                        }
                        .labelsHidden()
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(controller.isSaving)
                        .accessibilityLabel("Selected mouse")

                        Text(device.connected ? "Connected" : "Offline · Changes apply when reconnected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .help("Device ID \(SettingsDevice.modelKey(device.identity))")
                Text("Changes save automatically. App-specific rules take precedence.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if controller.ready {
                Label("No mice found", systemImage: "computermouse")
                    .font(.headline)
                Text("Connect a mouse to configure it, or use Import & Export to restore saved settings.")
                    .foregroundStyle(.secondary)
            }
            if let error = controller.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(controller.ready ? "Couldn’t save mouse settings" : "Couldn’t load mouse settings",
                          systemImage: "exclamationmark.triangle")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(error).foregroundStyle(.secondary)
                    if !controller.ready {
                        Button("Try Again") { Task { await controller.refresh() } }
                    }
                }
            } else if !controller.ready {
                ProgressView("Loading mouse settings…").controlSize(.small)
            } else if controller.isSaving, controller.transferInProgress == nil {
                Text("Saving changes…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .onChange(of: controller.error) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }
}

private struct UnavailableMouseSetting: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

private struct AccessibilitySetting: View {
    let controller: DeviceSettingsController
    var showsGranted = true

    var body: some View {
        if controller.accessibilityGranted {
            if showsGranted {
                Label("Accessibility access granted", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Accessibility access required", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Allow MouseService in System Settings to use scroll rules and side-button gestures.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings…", action: DeviceSettingsController.openAccessibilitySettings)
            }
        }
    }
}

private struct PointerControls: View {
    let controller: DeviceSettingsController

    var body: some View {
        let selection = controller.selectedID
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tracking profile").accessibilityHidden(true)
                Spacer()
                Picker("Tracking profile", selection: Binding(get: { controller.pointerProfile }, set: { profile in
                    Task { await controller.set("pointer-profile", value: profile.rawValue, for: selection) }
                })) {
                    ForEach(PointerProfile.allCases, id: \.self) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Tracking profile")
            }
            Text(controller.pointerProfile.hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            SensitivityControl(title: "Tracking speed", value: controller.speed, range: 0...1) {
                await controller.set("speed", value: $0, for: selection)
            }
            if controller.pointerProfile == .macOS {
                Divider()
                HStack {
                    Text("Pointer acceleration").accessibilityHidden(true)
                    Spacer()
                    Toggle("Pointer acceleration", isOn: Binding(get: { !controller.disableAcceleration }, set: { enabled in
                        Task { await controller.set("disable-acceleration", value: enabled ? "no" : "yes", for: selection) }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Pointer acceleration")
                }
                if !controller.disableAcceleration {
                    SensitivityControl(title: "Acceleration", value: controller.acceleration, range: 0...40) {
                        await controller.set("acceleration", value: $0, for: selection)
                    }
                }
            }
        }
        .padding(14)
        .disabled(!controller.ready || controller.isSaving)
    }
}

private extension PointerProfile {
    var title: String {
        switch self {
        case .macOS: "macOS"
        case .linear: "Linear"
        case .windowsEPP: "Windows EPP–style"
        case .libinputAdaptive: "libinput Adaptive–style"
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .macOS: "Use the macOS tracking curve with optional acceleration."
        case .linear: "The pointer travels the same distance for the same mouse movement at any speed."
        case .windowsEPP: "Modeled on Windows Enhance Pointer Precision. Move slowly for fine adjustments and quickly to cross the screen."
        case .libinputAdaptive: "Modeled on Linux tracking. Small movements are slower than with Windows EPP, and speed builds more gradually."
        }
    }
}

private struct SensitivityControl: View {
    let title: LocalizedStringKey
    let value: String
    let range: ClosedRange<Double>
    let commit: @MainActor (String) async -> Bool
    @State private var draft = ""
    @State private var sliderValue = 0.0
    @State private var dragging = false
    @State private var committing = false
    @State private var invalid = false
    @State private var writeFailed = false
    @State private var keyboardCommit: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, text: $draft, prompt: Text("System"))
                    .labelsHidden()
                    .frame(width: 88)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focused)
                    .onSubmit { saveDraft() }
                    .onChange(of: focused) { _, active in if !active { saveDraft() } }
                    .accessibilityHint("Enter a value from \(lowerBound) to \(upperBound).")
            }
            Slider(value: Binding(get: { sliderValue }, set: updateSlider), in: range) { editing in
                dragging = editing
                keyboardCommit?.cancel()
                if !editing { saveDraft() }
            }
            .accessibilityLabel(Text(title))
            HStack {
                Text(lowerBound)
                Spacer()
                Text(upperBound)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            if invalid || writeFailed {
                Label(invalid ? invalidHint
                              : "Couldn’t save this value. Press Return to try again.",
                      systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { sync(value) }
        .onChange(of: value) { _, latest in
            if !focused && !dragging && !committing { sync(latest) }
        }
        .onDisappear { keyboardCommit?.cancel() }
    }

    private var lowerBound: String { String(format: "%g", range.lowerBound) }
    private var upperBound: String { String(format: "%g", range.upperBound) }
    private var invalidHint: String { "Enter a number from \(lowerBound) to \(upperBound)." }

    private func sync(_ stored: String) {
        draft = stored
        sliderValue = min(max(Double(stored) ?? range.lowerBound, range.lowerBound), range.upperBound)
        invalid = false
        writeFailed = false
    }

    private func updateSlider(_ number: Double) {
        sliderValue = number
        draft = SettingsRow.sliderText(number)
        invalid = false
        writeFailed = false
        guard !dragging else { return }
        // Keyboard and VoiceOver adjustments can change the binding without a drag.
        keyboardCommit?.cancel()
        keyboardCommit = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            saveDraft()
        }
    }

    private func saveDraft() {
        guard !committing else { return }
        let text = SettingsModel.normalizedNumber(draft)
        guard text != value else { sync(value); return }
        guard let number = Double(text), range.contains(number) else {
            invalid = true
            AccessibilityNotification.Announcement(invalidHint).post()
            return
        }
        if number == Double(value) {
            sync(value)
            return
        }
        invalid = false
        writeFailed = false
        committing = true
        Task {
            if await commit(text) {
                sync(String(number))
            } else {
                writeFailed = true
            }
            committing = false
        }
    }
}

private struct ScrollControls: View {
    let controller: DeviceSettingsController
    private let modifiers = [("command", "Command"), ("shift", "Shift"), ("option", "Option"), ("control", "Control")]

    var body: some View {
        let selection = controller.selectedID
        VStack(alignment: .leading, spacing: 12) {
            if !controller.accessibilityGranted {
                AccessibilitySetting(controller: controller, showsGranted: false)
                Divider()
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Reverse direction").accessibilityHidden(true)
                    Spacer()
                    Picker("Reverse direction", selection: Binding(get: { controller.reverse }, set: { value in
                        Task { await controller.set("reverse-scroll", value: value, for: selection) }
                    })) {
                        Text("Off").tag("none")
                        Text("Vertical").tag("vertical")
                        Text("Horizontal").tag("horizontal")
                        Text("Both axes").tag("both")
                    }
                    .labelsHidden()
                    .accessibilityLabel("Reverse direction")
                }
                Divider()
                Text("Ignore scrolling while holding any selected key.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                modifierRow("Vertical", field: "ignore-vertical-scroll-with", value: controller.dropVertical)
                modifierRow("Horizontal", field: "ignore-horizontal-scroll-with", value: controller.dropHorizontal)
            }
            .disabled(!controller.ready || controller.isSaving)
        }
        .padding(14)
    }

    private func modifierRow(_ axis: String, field: String, value: String) -> some View {
        let selection = controller.selectedID
        let chosen = Set(value.split(separator: ",").map(String.init))
        return VStack(alignment: .leading, spacing: 6) {
            Text(axis).font(.subheadline.weight(.medium)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), alignment: .leading)], spacing: 8) {
                ForEach(modifiers, id: \.0) { key, title in
                    Toggle(title, isOn: Binding(get: { chosen.contains(key) }, set: { enabled in
                        var updated = chosen
                        if enabled { updated.insert(key) } else { updated.remove(key) }
                        let text = modifiers.map(\.0).filter { updated.contains($0) }.joined(separator: ",")
                        Task { await controller.set(field, value: text, for: selection) }
                    }))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(axis) scrolling, \(title)")
                }
            }
        }
    }
}

private struct TransferControls: View {
    let controller: DeviceSettingsController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 12) {
                transferRow("Export settings", button: "Export…", symbol: "square.and.arrow.up",
                            detail: "Save device rules, gestures, and Logitech preferences to a JSON file.",
                            action: controller.showExportPanel)
                Divider()
                transferRow("Import settings", button: "Import…", symbol: "square.and.arrow.down",
                            detail: "Replace your settings from a MouseService backup. A backup of your current settings is saved first.",
                            action: controller.showImportPanel)
            }
            .disabled(controller.isSaving)
            if let progress = controller.transferInProgress {
                Divider()
                ProgressView(progress).controlSize(.small)
            } else if let error = controller.transferError {
                Divider()
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn’t transfer settings").font(.headline)
                        Text(error).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else if let message = controller.transferMessage {
                Divider()
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .onChange(of: controller.transferError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        .onChange(of: controller.transferMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func transferRow(_ title: LocalizedStringKey, button: LocalizedStringKey, symbol: String,
                             detail: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action)
        }
    }
}
