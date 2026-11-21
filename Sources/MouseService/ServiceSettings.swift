import AppKit
import GestureCore
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
    static let pageSwipesKey = "side-button-page-swipes"
    static let dragKey = "side-button-drag"
    static let dragButtonKey = "side-button-drag-button"
    static let dragThresholdKey = "side-button-drag-threshold"

    private let storage: UserDefaults
    init(defaults: UserDefaults = .standard) { storage = defaults }

    var gesturesEnabled: Bool {
        sideButtons.pageSwipes || sideButtons.dragButton != nil
    }

    private var legacyGesturesEnabled: Bool {
        if let value = storage.object(forKey: Self.gesturesKey) as? Bool { return value }
        return storage.string(forKey: Self.gesturesKey) != "no"
    }

    var sideButtons: SideButtonTap.Preferences {
        let button = storage.string(forKey: Self.dragButtonKey).flatMap(SideButtonGesture.Button.init(rawValue:)) ?? .back
        let threshold = storage.string(forKey: Self.dragThresholdKey).flatMap(Int.init) ?? 6
        return .init(pageSwipes: enabled(Self.pageSwipesKey), dragButton: enabled(Self.dragKey) ? button : nil,
                     threshold: Double(min(30, max(1, threshold))))
    }

    private func enabled(_ key: String) -> Bool {
        storage.string(forKey: key).map { $0 == "yes" } ?? legacyGesturesEnabled
    }

    var exportedValues: [String: String] {
        SettingsTransfer.preferenceDefaults.keys.reduce(into: [String: String]()) { values, key in
            values[key] = value(forKey: key) ?? defaultValue(forKey: key)
        }
    }

    func applyImportedValues(_ values: [String: String]) {
        if values[Self.gesturesKey] != nil {
            for key in [Self.pageSwipesKey, Self.dragKey] where values[key] == nil {
                storage.removeObject(forKey: key)
            }
        }
        for (key, value) in values { storage.set(value, forKey: key) }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self,
                                       userInfo: ["keys": Array(values.keys) + [Self.pageSwipesKey, Self.dragKey]])
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
        if key == Self.pageSwipesKey || key == Self.dragKey { return enabled(key) ? "yes" : "no" }
        return storage.string(forKey: key)
    }
    func defaultValue(forKey key: String) -> String { defaults[key] ?? "" }

    func validate(_ value: String, forKey key: String) -> String? {
        SettingsTransfer.validate(value, key: key)
    }

    func setValue(_ value: String, forKey key: String) throws {
        storage.set(value.lowercased() == "keep" ? "keep" : value, forKey: key)
        var keys = [key]
        if key == Self.gesturesKey {
            for separate in [Self.pageSwipesKey, Self.dragKey] { storage.set(value, forKey: separate) }
            keys += [Self.pageSwipesKey, Self.dragKey]
        }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": keys])
        onChange?()
    }

    func removeValues(forKeys keys: [String]) throws {
        for key in keys { storage.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": keys])
        onChange?()
    }

    static let sideButtonSection = SettingsSection("Side Buttons", rows: [
            .toggle(pageSwipesKey, "Page swipes on click", symbol: "arrow.left.arrow.right",
                    description: "Use Back and Forward to navigate page history. Connected apps keep their button bindings."),
            .toggle(dragKey, "System gestures on drag", symbol: "hand.draw",
                    description: "Drag sideways to switch Spaces, up for Mission Control, or down for App Exposé."),
            .choice(dragButtonKey, "Gesture button", [("back", "Back"), ("forward", "Forward")],
                    symbol: "button.programmable"),
            .number(dragThresholdKey, "Gesture threshold", step: 1, symbol: "ruler",
                    description: "Pointer travel in points before a drag becomes a gesture. Use 1–30."),
        ])

    static let wheelAndHapticSections = [
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
