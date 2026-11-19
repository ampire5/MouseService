import AppKit
import MouseContract
import SettingsKit

/// The device settings that are the service's alone (core spec, "Device settings"): the haptic strength and the
/// haptic panel's force, in `UserDefaults`, with FrameScrub's spelling, defaults and ranges. `onChange` hands each new
/// value to the mouse.
@MainActor final class ServiceSettings: SettingsStore {
    static let hapticStrengthKey = "haptic-strength"
    static let panelForceKey = "mx-panel-force"
    static let wheelModeKey = "wheel-mode"
    static let gesturesKey = "gesturesOn"

    private let storage: UserDefaults
    init(defaults: UserDefaults = .standard) { storage = defaults }

    var gesturesEnabled: Bool {
        if let value = storage.object(forKey: Self.gesturesKey) as? Bool { return value }
        return storage.string(forKey: Self.gesturesKey) != "no"
    }

    var exportedValues: [String: String] {
        SettingsTransfer.preferenceDefaults.keys.reduce(into: [String: String]()) { values, key in
            values[key] = value(forKey: key) ?? defaultValue(forKey: key)
        }
    }

    func applyImportedValues(_ values: [String: String]) {
        for (key, value) in values { storage.set(value, forKey: key) }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self,
                                       userInfo: ["keys": Array(values.keys)])
        onChange?()
    }

    var onChange: (() -> Void)?
    private let defaults = SettingsTransfer.preferenceDefaults

    /// nil: keep the mouse's own strength.
    var hapticStrength: UInt8? {
        UInt8(value(forKey: Self.hapticStrengthKey) ?? defaultValue(forKey: Self.hapticStrengthKey))
    }

    var panelForce: PanelForce {
        PanelForce.parse(value(forKey: Self.panelForceKey) ?? defaultValue(forKey: Self.panelForceKey)) ?? .percent(0)
    }

    /// The wheel's mode where no app asks for another: the setting, or what the SmartShift button last chose.
    var wheelMode: WheelMode {
        (value(forKey: Self.wheelModeKey) ?? defaultValue(forKey: Self.wheelModeKey)) == "free-spin" ? .freeSpin : .ratchet
    }

    func value(forKey key: String) -> String? {
        if key == Self.gesturesKey { return gesturesEnabled ? "yes" : "no" }
        return storage.string(forKey: key)
    }
    func defaultValue(forKey key: String) -> String { defaults[key] ?? "" }

    func validate(_ value: String, forKey key: String) -> String? {
        SettingsTransfer.validate(value, key: key)
    }

    func setValue(_ value: String, forKey key: String) throws {
        storage.set(value.lowercased() == "keep" ? "keep" : value, forKey: key)
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": [key]])
        onChange?()
    }

    func removeValues(forKeys keys: [String]) throws {
        for key in keys { storage.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": keys])
        onChange?()
    }

    static let controlSections = [
        SettingsSection("Side Buttons", rows: [
            .toggle(gesturesKey, "Side-button gestures", symbol: "hand.draw",
                    description: "Click Back or Forward to swipe between pages. Hold Back and drag sideways to switch "
                        + "Spaces, up for Mission Control, or down for App Exposé. Requires Accessibility."),
        ]),
        SettingsSection("MX Master Wheel", rows: [
            .choice(wheelModeKey, "Default wheel mode", [("ratchet", "Ratchet"), ("free-spin", "Free spin")],
                    symbol: "dial.medium",
                    description: "SmartShift changes the default mode. Apps can override it over their own windows."),
        ]),
        SettingsSection("MX Master Haptics", rows: [
            .number(hapticStrengthKey, "Haptic strength", step: 5, symbol: "waveform",
                    description: "Vibration strength from 0 to 100. Enter “keep” to use the mouse’s own setting."),
            .number(panelForceKey, "Panel press force", step: 5, symbol: "hand.point.down",
                    description: "Force needed to press the haptic panel, from 0 (lightest) to 100 (firmest). "
                        + "Enter “default” for the factory value or “keep” to preserve the mouse’s setting."),
        ]),
    ]
}
