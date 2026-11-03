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

    static let pages = [
        SettingsPage("mouse", "Mouse", symbol: "computermouse", sections: [
            SettingsSection("MX Master", rows: [
                .number(hapticStrengthKey, "Haptic strength", step: 5, symbol: "waveform",
                        description: "The mouse's normal vibration strength. 0–100, or keep (default): the mouse's "
                            + "own setting stays. Apps ask for a stronger one-off vibration themselves."),
                .number(panelForceKey, "Panel force", step: 5, symbol: "hand.point.down",
                        description: "How hard the haptic panel must be pressed: 0 the lightest the mouse takes, 100 "
                            + "the stiffest; default writes the factory value, keep leaves it alone. Default 0."),
            ]),
            SettingsSection("Gestures", rows: [
                .toggle(gesturesKey, "Side-button gestures", symbol: "hand.draw",
                        description: "Click Back or Forward to swipe a page. Hold Back and drag sideways to switch "
                            + "Spaces, up for Mission Control, or down for App Exposé. Requires Accessibility."),
            ]),
            SettingsSection("Wheel", rows: [
                .choice(wheelModeKey, "Wheel mode", [("ratchet", "Ratchet"), ("free-spin", "Free spin")],
                        symbol: "dial.medium",
                        description: "The wheel's mode everywhere, unless an app asks for another over its own "
                            + "window. The SmartShift button changes it where no app does. Default ratchet."),
            ]),
        ]),
    ]
}
