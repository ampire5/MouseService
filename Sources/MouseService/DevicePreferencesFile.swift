import Foundation
import PointerCore

/// Disk work is serialized away from the main actor. Each edit starts with the latest file, not a UI snapshot.
actor DevicePreferencesFile {
    let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "devices:\n" }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw SettingsTransfer.Invalid.content("Configuration must be UTF-8 and smaller than 4 MB.")
        }
        _ = try DeviceRules(yaml: text)
        return text
    }

    func edit(_ field: String, value: String, device: DeviceIdentity) throws -> String {
        let edited = try DeviceConfigDocument.setting(field, to: value, for: device, in: load())
        try replace(with: edited)
        return edited
    }

    func replace(with text: String) throws {
        _ = try DeviceRules(yaml: text)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("before-ui")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func export(to destination: URL, preferences: [String: String]) throws {
        try SettingsTransfer.encode(config: load(), preferences: preferences).write(to: destination, options: .atomic)
    }

    func importBundle(from source: URL, currentPreferences: [String: String]) throws -> SettingsTransfer {
        let bundle = try SettingsTransfer.decode(Data(contentsOf: source))
        let backup = try SettingsTransfer.encode(config: load(), preferences: currentPreferences)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = url.appendingPathExtension("before-import-\(UUID().uuidString).json")
        try backup.write(to: destination, options: .atomic)
        try replace(with: bundle.config)
        return bundle
    }

    func devices() throws -> [DeviceIdentity] { try DeviceConfigDocument.devices(in: load()) }

    func values(for device: DeviceIdentity) throws -> DeviceSettingsValues {
        let text = try load()
        func value(_ field: String, _ fallback: String) throws -> String {
            try DeviceConfigDocument.setting(field, for: device, in: text) ?? fallback
        }
        return try DeviceSettingsValues(speed: value("speed", ""), acceleration: value("acceleration", ""),
                                        disableAcceleration: value("disable-acceleration", "no") == "yes",
                                        reverse: value("reverse-scroll", "none"),
                                        dropVertical: value("ignore-vertical-scroll-with", ""),
                                        dropHorizontal: value("ignore-horizontal-scroll-with", ""))
    }
}

struct DeviceSettingsValues: Sendable {
    var speed: String
    var acceleration: String
    var disableAcceleration: Bool
    var reverse: String
    var dropVertical: String
    var dropHorizontal: String
}
