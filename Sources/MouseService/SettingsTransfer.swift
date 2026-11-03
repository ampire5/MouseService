import Foundation
import PointerCore

/// One portable file: device rules and the service's own preferences, never window positions or paths.
struct SettingsTransfer: Codable, Sendable {
    let version: Int
    let config: String
    let preferences: [String: String]

    static let preferenceDefaults = [
        "haptic-strength": "keep", "mx-panel-force": "0", "wheel-mode": "ratchet", "gesturesOn": "yes",
    ]

    enum Invalid: LocalizedError {
        case content(String)
        var errorDescription: String? {
            switch self { case let .content(message): message }
        }
    }

    static func validate(_ value: String, key: String) -> String? {
        switch key {
        case "haptic-strength":
            return value.lowercased() == "keep" || Int(value).map { (0...100).contains($0) } == true
                ? nil : "Use 0–100 or keep."
        case "mx-panel-force": return PanelForce.parse(value) == nil ? "Use 0–100, default or keep." : nil
        case "wheel-mode": return ["ratchet", "free-spin"].contains(value) ? nil : "Choose a wheel mode."
        case "gesturesOn": return ["yes", "no"].contains(value) ? nil : "Use yes or no."
        default: return "Unknown preference: \(key)."
        }
    }

    static func encode(config: String, preferences: [String: String]) throws -> Data {
        let bundle = Self(version: 1, config: config, preferences: preferences)
        try bundle.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw Invalid.content("Settings file is larger than 4 MB.") }
        let bundle = try JSONDecoder().decode(Self.self, from: data)
        try bundle.validate()
        return bundle
    }

    private func validate() throws {
        guard version == 1 else { throw Invalid.content("This settings file version is not supported.") }
        _ = try DeviceConfigDocument.devices(in: config)
        for (key, value) in preferences {
            if let error = Self.validate(value, key: key) { throw Invalid.content(error) }
        }
    }
}
