import Foundation
import Yams

/// Edits device defaults while retaining application rules and unrecognized YAML values.
public enum DeviceConfigDocument {
    public enum DocumentError: Error, CustomStringConvertible, LocalizedError {
        case invalid(String)
        public var errorDescription: String? { description }
        public var description: String {
            switch self { case let .invalid(message): message }
        }
    }

    private static let fields = ["speed", "acceleration", "disable-acceleration", "reverse-scroll",
                                 "ignore-vertical-scroll-with", "ignore-horizontal-scroll-with"]

    public static func devices(in yaml: String) throws -> [DeviceIdentity] {
        let (root, rules) = try parse(yaml)
        let names = root["devices"]?.mapping.map { Array($0).map { $0.key.string ?? "Device" } } ?? []
        return zip(names, rules.entries).map { name, entry in
            DeviceIdentity(vendorID: entry.vendorID, productID: entry.productID, productName: name,
                           serialNumber: entry.serialNumber,
                           category: name.localizedCaseInsensitiveContains("trackpad") ? .trackpad : .mouse)
        }
    }

    /// Returns the effective default, including the standard mouse baseline; app overrides are excluded.
    public static func setting(_ field: String, for device: DeviceIdentity, in yaml: String) throws -> String? {
        try validateField(field)
        let (_, rules) = try parse(yaml)
        return string(field, in: rules.resolve(device, app: nil))
    }

    public static func setting(_ field: String, to value: String, for device: DeviceIdentity,
                               in yaml: String) throws -> String {
        let replacement = try valueNode(field, value)
        var (root, rules) = try parse(yaml)
        var entries = root["devices"]?.mapping ?? Node.Mapping([])
        let matching = rules.entries.indices.filter { rules.entries[$0].matches(device) }
        let exact = matching.last { rules.entries[$0].serialNumber == device.serialNumber }
        let last = matching.last
        // A later generic entry can shadow an earlier serial entry. A minimal trailing entry avoids moving
        // any original rule, which would also change application precedence and other devices' settings.
        let needsTrailing = exact == nil || (exact != last && matching.contains { index in
            index > (exact ?? -1) && entries[index].value[field] != nil
        })
        if let exact {
            var body = entries[exact].value
            body[field] = replacement
            entries[exact] = (entries[exact].key, body)
        }
        if needsTrailing {
            var body = Node([(Node("id"), Node(String(format: "%x:%x", device.vendorID, device.productID)))])
            if let serial = device.serialNumber { body["serial"] = Node(serial) }
            body[field] = replacement
            // Preserve explicit app values even when an app's old value happened to equal the old default.
            var appNames: Set<String> = []
            for index in matching {
                if let apps = root["devices"]?.mapping?[index].value["apps"]?.mapping {
                    for (name, block) in apps where block[field] != nil {
                        if let name = name.string { appNames.insert(name) }
                    }
                }
            }
            var apps = Node.Mapping([])
            for app in appNames.sorted() {
                if let oldValue = string(field, in: rules.resolve(device, app: app)) {
                    apps[app] = Node([(Node(field), try valueNode(field, oldValue))])
                }
            }
            if !apps.isEmpty { body["apps"] = .mapping(apps) }
            let baseName = device.productName.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(format: "%x:%x", device.vendorID, device.productID)
            var name = baseName
            var suffix = 2
            while entries.keys.contains(where: { $0.string == name }) {
                name = "\(baseName) (\(suffix))"
                suffix += 1
            }
            entries[name] = body
        }
        root["devices"] = .mapping(entries)
        let edited = try Yams.serialize(node: root)
        _ = try parse(edited)
        return edited
    }

    private static func parse(_ yaml: String) throws -> (Node, DeviceRules) {
        let rules = try DeviceRules(yaml: yaml)
        let documents = Array(try Yams.compose_all(yaml: yaml))
        guard documents.count <= 1 else { throw DocumentError.invalid("Expected one YAML document.") }
        let node = documents.first
        if node == nil || node?.scalar?.string.isEmpty == true { return (Node([(Node, Node)]()), rules) }
        guard let node, node.mapping != nil else { throw DocumentError.invalid("Expected a YAML mapping.") }
        return (node, rules)
    }

    private static func validateField(_ field: String) throws {
        guard fields.contains(field) else { throw DocumentError.invalid("Unknown setting: \(field)") }
    }

    private static func valueNode(_ field: String, _ value: String) throws -> Node {
        try validateField(field)
        switch field {
        case "speed", "acceleration":
            let range: ClosedRange<Double> = field == "speed" ? 0...1 : 0...40
            guard let number = Double(value), number.isFinite, range.contains(number) else {
                throw DocumentError.invalid("\(field) must be a finite number in \(range).")
            }
            return Node(String(number))
        case "disable-acceleration":
            guard value == "yes" || value == "no" else { throw DocumentError.invalid("Use yes or no.") }
            return Node(value == "yes" ? "true" : "false")
        case "reverse-scroll":
            guard ["none", "vertical", "horizontal", "both"].contains(value) else {
                throw DocumentError.invalid("Choose none, vertical, horizontal or both.")
            }
            return Node(value)
        default:
            let names = value.isEmpty ? [] : value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard names.allSatisfy({ name in ModifierSet.byName.contains { $0.0 == name } }) else {
                throw DocumentError.invalid("Choose command, shift, option or control.")
            }
            return Node(ModifierSet.byName.filter { names.contains($0.0) }.map { Node($0.0) })
        }
    }

    private static func string(_ field: String, in resolved: ResolvedRules) -> String? {
        switch field {
        case "speed": return resolved.pointer.speed.map { String($0) }
        case "acceleration": return resolved.pointer.acceleration.map { String($0) }
        case "disable-acceleration": return resolved.pointer.disableAcceleration.map { $0 ? "yes" : "no" }
        case "reverse-scroll":
            switch (resolved.scroll.reverseVertical, resolved.scroll.reverseHorizontal) {
            case (true, true): return "both"
            case (true, false): return "vertical"
            case (false, true): return "horizontal"
            default: return "none"
            }
        default:
            let modifiers = field == "ignore-vertical-scroll-with" ? resolved.scroll.dropVertical : resolved.scroll.dropHorizontal
            return ModifierSet.byName.filter { modifiers.contains($0.1) }.map(\.0).joined(separator: ",")
        }
    }
}
