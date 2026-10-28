import Foundation

/// The one-time move from LinearMouse's schemes (`devices.json`, or LinearMouse's own file) to `config.yaml`.
///
/// Each device the old rules name by vendor and product gets an entry whose fields are what the old rules resolve to
/// for it, and each app named anywhere an `apps` entry with the fields that differ from the device's: exact by
/// construction (the order of schemes and per-axis merges are folded in), not by translating schemes one by one.
/// What the new format cannot say (a rule for every device, a condition MouseService cannot check) is listed in a
/// comment at the top.
public enum DevicesMigration {
    public static func yaml(from legacy: LegacyDeviceRules, source: String = "the old devices config") -> String {
        let apps = legacy.apps
        var entries: [String] = []
        var names = Set<String>()
        for device in legacy.identities {
            let base = fields(legacy.resolve(device, app: nil), changedFrom: nil)
            var name = device.productName ?? String(format: "%x:%x", device.vendorID, device.productID)
            if !names.insert(name).inserted {
                name += String(format: " (%x:%x%@)", device.vendorID, device.productID, device.serialNumber.map { " " + $0 } ?? "")
                names.insert(name)
            }
            var lines = ["  \(key(name)):", String(format: "    id: %x:%x", device.vendorID, device.productID)]
            if let serial = device.serialNumber { lines.append("    serial: \(quoted(serial))") }
            let baseRules = legacy.resolve(device, app: nil)
            lines += base.map { "    " + $0 }
            var appLines: [String] = []
            for app in apps {
                let changed = fields(legacy.resolve(device, app: app), changedFrom: baseRules)
                if changed.isEmpty { continue }
                appLines.append("      \(key(app)): { \(changed.joined(separator: ", ")) }")
            }
            if !appLines.isEmpty { lines += ["    apps:"] + appLines }
            entries.append(lines.joined(separator: "\n"))
        }
        var notes: [String] = []
        for (index, scheme) in legacy.schemes.enumerated() {
            let cannot = scheme.conditions.isEmpty
                || scheme.conditions.contains { $0.unsupported || $0.vendorID == nil || $0.productID == nil }
            guard cannot else { continue }
            let why = scheme.conditions.isEmpty ? "no condition: every device"
                : scheme.conditions.map { condition in
                    if condition.unsupported {
                        let fields = legacy.ignoredFields.filter { $0.hasPrefix("schemes[\(index)].if") }
                        return "a condition MouseService cannot check (\(fields.joined(separator: ", ")))"
                    }
                    return condition.app.map { "app \($0) on any device" } ?? "a device without vendor and product"
                }.joined(separator: "; ")
            notes.append("#   scheme \(index): \(why)")
        }
        var out = "# Migrated from \(source). Rules for a device are written once, its apps nested; `apps:` rules replace\n"
        out += "# the device's fields for that app only.\n"
        if !notes.isEmpty {
            out += "# Carried only for the devices below (the format names a device), so not for others:\n"
            out += notes.joined(separator: "\n") + "\n"
        }
        out += "\ndevices:\n"
        out += entries.isEmpty ? "" : entries.joined(separator: "\n") + "\n"
        return out
    }

    /// The YAML fields of `rules`; with `base`, only those that differ from it.
    private static func fields(_ rules: ResolvedRules, changedFrom base: ResolvedRules?) -> [String] {
        var out: [String] = []
        let b = base ?? ResolvedRules()
        if let v = rules.pointer.speed, v != b.pointer.speed { out.append("speed: \(v)") }
        if let v = rules.pointer.acceleration, v != b.pointer.acceleration { out.append("acceleration: \(v)") }
        if let v = rules.pointer.disableAcceleration, v != b.pointer.disableAcceleration {
            out.append("disable-acceleration: \(v)")
        }
        let s = rules.scroll, o = b.scroll
        if (s.reverseVertical, s.reverseHorizontal) != (o.reverseVertical, o.reverseHorizontal)
            || (base == nil && (s.reverseVertical || s.reverseHorizontal)) {
            let word = switch (s.reverseVertical, s.reverseHorizontal) {
            case (false, false): "none"
            case (true, false): "vertical"
            case (false, true): "horizontal"
            case (true, true): "both"
            }
            out.append("reverse-scroll: \(word)")
        }
        if s.dropVertical != o.dropVertical { out.append("ignore-vertical-scroll-with: \(list(s.dropVertical))") }
        if s.dropHorizontal != o.dropHorizontal { out.append("ignore-horizontal-scroll-with: \(list(s.dropHorizontal))") }
        return out
    }

    private static func list(_ set: ModifierSet) -> String {
        "[" + ModifierSet.byName.filter { set.contains($0.1) }.map(\.0).joined(separator: ", ") + "]"
    }

    /// A mapping key: plain when it is simple, quoted otherwise.
    private static func key(_ text: String) -> String {
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || " ._-()".unicodeScalars.contains($0)
        } && !text.hasPrefix(" ") && !text.hasSuffix(" ") && !text.hasPrefix("-")
        return plain ? text : quoted(text)
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
