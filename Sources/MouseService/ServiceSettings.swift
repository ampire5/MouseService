import AppKit
import SettingsKit

/// The device settings that are the service's alone (core spec, "Device settings"): the haptic strength and the
/// haptic panel's force, in `UserDefaults`, with FrameScrub's spelling, defaults and ranges. `onChange` hands each new
/// value to the mouse.
@MainActor final class ServiceSettings: SettingsStore {
    static let hapticStrengthKey = "haptic-strength"
    static let panelForceKey = "mx-panel-force"

    var onChange: (() -> Void)?
    private let defaults: [String: String] = [hapticStrengthKey: "keep", panelForceKey: "0"]

    /// nil: keep the mouse's own strength.
    var hapticStrength: UInt8? {
        UInt8(value(forKey: Self.hapticStrengthKey) ?? defaultValue(forKey: Self.hapticStrengthKey))
    }

    var panelForce: PanelForce {
        PanelForce.parse(value(forKey: Self.panelForceKey) ?? defaultValue(forKey: Self.panelForceKey)) ?? .percent(0)
    }

    func value(forKey key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    func defaultValue(forKey key: String) -> String { defaults[key] ?? "" }

    func validate(_ value: String, forKey key: String) -> String? {
        switch key {
        case Self.hapticStrengthKey:
            value.lowercased() == "keep" || Int(value).map({ (0...100).contains($0) }) == true ? nil : "0–100 or keep"
        case Self.panelForceKey:
            PanelForce.parse(value) == nil ? "0–100, default or keep" : nil
        default:
            nil
        }
    }

    func setValue(_ value: String, forKey key: String) throws {
        UserDefaults.standard.set(value.lowercased() == "keep" ? "keep" : value, forKey: key)
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": [key]])
        onChange?()
    }

    func removeValues(forKeys keys: [String]) throws {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
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
        ]),
    ]
}
