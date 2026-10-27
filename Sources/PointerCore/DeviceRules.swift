import Foundation

/// What a rule's `if` can name of a pointing device (LinearMouse's `if.device`).
public struct DeviceIdentity: Equatable, Sendable {
    public enum Category: String, Sendable { case mouse, trackpad }

    public var vendorID: Int
    public var productID: Int
    public var productName: String?
    public var serialNumber: String?
    public var category: Category

    public init(vendorID: Int, productID: Int, productName: String? = nil, serialNumber: String? = nil,
                category: Category) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.serialNumber = serialNumber
        self.category = category
    }
}

/// The pointer part of the resolved rules; nil leaves the device's own value.
public struct PointerSettings: Equatable, Sendable {
    /// 0…1, LinearMouse's scale (`PointerMath.resolution(speed:)`).
    public var speed: Double?
    /// 0…40, the HID acceleration value.
    public var acceleration: Double?
    public var disableAcceleration: Bool?

    public init(speed: Double? = nil, acceleration: Double? = nil, disableAcceleration: Bool? = nil) {
        self.speed = speed
        self.acceleration = acceleration
        self.disableAcceleration = disableAcceleration
    }

    public var isEmpty: Bool { speed == nil && acceleration == nil && disableAcceleration == nil }
}

/// The modifier keys a scroll rule can name.
public struct ModifierSet: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ModifierSet(rawValue: 1)
    public static let shift = ModifierSet(rawValue: 2)
    public static let option = ModifierSet(rawValue: 4)
    public static let control = ModifierSet(rawValue: 8)

    static let byName: [(String, ModifierSet)] = [("command", .command), ("shift", .shift), ("option", .option),
                                                  ("control", .control)]
}

/// The scroll part of the resolved rules, read by the scroll tap for every event of a device.
public struct ScrollRule: Equatable, Sendable {
    public var reverseVertical = false
    public var reverseHorizontal = false
    /// A vertical scroll with one of these held is dropped (`preventDefault`).
    public var dropVertical: ModifierSet = []
    /// A horizontal scroll with one of these held is dropped.
    public var dropHorizontal: ModifierSet = []

    public init(reverseVertical: Bool = false, reverseHorizontal: Bool = false, dropVertical: ModifierSet = [],
                dropHorizontal: ModifierSet = []) {
        self.reverseVertical = reverseVertical
        self.reverseHorizontal = reverseHorizontal
        self.dropVertical = dropVertical
        self.dropHorizontal = dropHorizontal
    }

    public static let none = ScrollRule()

    public enum Decision: Equatable, Sendable {
        case pass
        case drop
        case negate(x: Bool, y: Bool)
    }

    /// What to do with one scroll event. Its axis is vertical when it moves vertically at all, as LinearMouse decides
    /// it for the modifier rules.
    public func decide(deltaX: Double, deltaY: Double, flags: ModifierSet) -> Decision {
        let drops = deltaY != 0 ? dropVertical : dropHorizontal
        if !drops.isDisjoint(with: flags) { return .drop }
        guard reverseVertical || reverseHorizontal else { return .pass }
        return .negate(x: reverseHorizontal, y: reverseVertical)
    }
}

/// What applies to one device in one app.
public struct ResolvedRules: Equatable, Sendable {
    public var pointer = PointerSettings()
    public var scroll = ScrollRule.none
}

/// `devices.json`: LinearMouse's schemes, the fields MouseService acts on (the design spec, "Fields read"). Schemes
/// whose `if` matches apply in file order, later fields over earlier ones.
public struct DeviceRules: Sendable {
    struct Condition: Sendable {
        var vendorID: Int?
        var productID: Int?
        var productName: String?
        var serialNumber: String?
        var category: DeviceIdentity.Category?
        var app: String?
        /// The condition names something MouseService cannot check: it never matches, so the rule does not widen to
        /// every device.
        var unsupported = false

        func matches(_ device: DeviceIdentity, app frontmost: String?) -> Bool {
            if unsupported { return false }
            if let vendorID, vendorID != device.vendorID { return false }
            if let productID, productID != device.productID { return false }
            if let productName, productName != device.productName { return false }
            if let serialNumber, serialNumber != device.serialNumber { return false }
            if let category, category != device.category { return false }
            if let app, app != frontmost { return false }
            return true
        }
    }

    /// One field of a scheme's scroll part; nil leaves what earlier schemes set.
    struct ScrollPart: Sendable {
        var reverseVertical: Bool?
        var reverseHorizontal: Bool?
        /// Per axis and modifier: true drops (`preventDefault`), false clears an earlier drop (any other type).
        var vertical: [(ModifierSet, Bool)] = []
        var horizontal: [(ModifierSet, Bool)] = []
    }

    struct Scheme: Sendable {
        /// Any of them matches (LinearMouse takes one condition or an array); empty: always.
        var conditions: [Condition]
        var pointer: PointerSettings
        var scroll: ScrollPart
    }

    var schemes: [Scheme]
    /// The fields present in the file that MouseService does not act on.
    public private(set) var ignoredFields: [String]

    public var count: Int { schemes.count }
    /// Whether some scheme names an app: the frontmost app then matters.
    public var dependsOnApp: Bool { schemes.contains { $0.conditions.contains { $0.app != nil } } }

    public static let empty = DeviceRules(schemes: [], ignoredFields: [])

    public init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["schemes"] as? [[String: Any]] else {
            throw RulesError.noSchemes
        }
        var ignored: [String] = []
        schemes = try list.enumerated().map { index, raw in
            try Self.scheme(raw, path: "schemes[\(index)]", ignored: &ignored)
        }
        ignoredFields = ignored
    }

    init(schemes: [Scheme], ignoredFields: [String]) {
        self.schemes = schemes
        self.ignoredFields = ignoredFields
    }

    public func resolve(_ device: DeviceIdentity, app: String?) -> ResolvedRules {
        var result = ResolvedRules()
        for scheme in schemes where scheme.conditions.isEmpty || scheme.conditions.contains(where: { $0.matches(device, app: app) }) {
            if let v = scheme.pointer.speed { result.pointer.speed = v }
            if let v = scheme.pointer.acceleration { result.pointer.acceleration = v }
            if let v = scheme.pointer.disableAcceleration { result.pointer.disableAcceleration = v }
            if let v = scheme.scroll.reverseVertical { result.scroll.reverseVertical = v }
            if let v = scheme.scroll.reverseHorizontal { result.scroll.reverseHorizontal = v }
            for (modifier, drop) in scheme.scroll.vertical {
                if drop { result.scroll.dropVertical.insert(modifier) } else { result.scroll.dropVertical.remove(modifier) }
            }
            for (modifier, drop) in scheme.scroll.horizontal {
                if drop { result.scroll.dropHorizontal.insert(modifier) } else { result.scroll.dropHorizontal.remove(modifier) }
            }
        }
        return result
    }

    // MARK: Parsing

    public enum RulesError: Error, Equatable, CustomStringConvertible {
        case noSchemes
        case bad(String)

        public var description: String {
            switch self {
            case .noSchemes: "no \"schemes\" array"
            case let .bad(path): "bad value at \(path)"
            }
        }
    }

    private static func scheme(_ raw: [String: Any], path: String, ignored: inout [String]) throws -> Scheme {
        var scheme = Scheme(conditions: [], pointer: PointerSettings(), scroll: ScrollPart())
        for (key, value) in raw {
            switch key {
            case "if":
                let items = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] }
                guard let items else { throw RulesError.bad("\(path).if") }
                scheme.conditions = try items.map { try condition($0, path: "\(path).if", ignored: &ignored) }
            case "pointer":
                guard let pointer = value as? [String: Any] else { throw RulesError.bad("\(path).pointer") }
                for (field, v) in pointer {
                    switch field {
                    case "speed": scheme.pointer.speed = try number(v, "\(path).pointer.speed", in: 0...1)
                    case "acceleration": scheme.pointer.acceleration = try number(v, "\(path).pointer.acceleration", in: 0...40)
                    case "disableAcceleration":
                        guard let b = v as? Bool else { throw RulesError.bad("\(path).pointer.disableAcceleration") }
                        scheme.pointer.disableAcceleration = b
                    default: ignored.append("\(path).pointer.\(field)")
                    }
                }
            case "scrolling":
                guard let scrolling = value as? [String: Any] else { throw RulesError.bad("\(path).scrolling") }
                for (field, v) in scrolling {
                    switch field {
                    case "reverse":
                        if let b = v as? Bool {
                            scheme.scroll.reverseVertical = b
                            scheme.scroll.reverseHorizontal = b
                        } else if let axes = v as? [String: Any] {
                            scheme.scroll.reverseVertical = axes["vertical"] as? Bool
                            scheme.scroll.reverseHorizontal = axes["horizontal"] as? Bool
                        } else {
                            throw RulesError.bad("\(path).scrolling.reverse")
                        }
                    case "modifiers":
                        guard let axes = v as? [String: Any] else { throw RulesError.bad("\(path).scrolling.modifiers") }
                        scheme.scroll.vertical = modifiers(axes["vertical"])
                        scheme.scroll.horizontal = modifiers(axes["horizontal"])
                    default: ignored.append("\(path).scrolling.\(field)")
                    }
                }
            default:
                ignored.append("\(path).\(key)")
            }
        }
        return scheme
    }

    private static func condition(_ raw: [String: Any], path: String, ignored: inout [String]) throws -> Condition {
        var condition = Condition()
        for (key, value) in raw {
            switch key {
            case "app":
                guard let s = value as? String else { throw RulesError.bad("\(path).app") }
                condition.app = s
            case "device":
                guard let device = value as? [String: Any] else { throw RulesError.bad("\(path).device") }
                for (field, v) in device {
                    switch field {
                    case "vendorID": condition.vendorID = try hex(v, "\(path).device.vendorID")
                    case "productID": condition.productID = try hex(v, "\(path).device.productID")
                    case "productName": condition.productName = v as? String
                    case "serialNumber": condition.serialNumber = v as? String
                    case "category":
                        guard let s = v as? String, let c = DeviceIdentity.Category(rawValue: s) else {
                            throw RulesError.bad("\(path).device.category")
                        }
                        condition.category = c
                    default: ignored.append("\(path).device.\(field)")
                    }
                }
            default:
                ignored.append("\(path).\(key)")
                condition.unsupported = true
            }
        }
        return condition
    }

    private static func modifiers(_ raw: Any?) -> [(ModifierSet, Bool)] {
        guard let raw = raw as? [String: Any] else { return [] }
        return ModifierSet.byName.compactMap { name, modifier in
            guard let action = raw[name] as? [String: Any] else { return nil }
            return (modifier, action["type"] as? String == "preventDefault")
        }
    }

    /// `"0x46d"` or a number.
    private static func hex(_ value: Any, _ path: String) throws -> Int {
        if let n = value as? Int { return n }
        if let s = value as? String, s.lowercased().hasPrefix("0x"), let n = Int(s.dropFirst(2), radix: 16) { return n }
        throw RulesError.bad(path)
    }

    private static func number(_ value: Any, _ path: String, in range: ClosedRange<Double>) throws -> Double {
        guard let n = (value as? NSNumber)?.doubleValue, !(value is Bool) else { throw RulesError.bad(path) }
        return min(max(n, range.lowerBound), range.upperBound)
    }
}

/// LinearMouse's mapping between its pointer speed and the HID pointer resolution (dots per inch the system assumes):
/// speed 0…1 runs linearly over 1/resolution from 1/1200 to 1/40.
public enum PointerMath {
    static let inverseRange = (1.0 / 1200)...(1.0 / 40)

    public static func resolution(speed: Double) -> Double {
        let s = min(max(speed, 0), 1)
        return 1 / (inverseRange.lowerBound + s * (inverseRange.upperBound - inverseRange.lowerBound))
    }

    public static func speed(resolution: Double) -> Double {
        (1 / resolution - inverseRange.lowerBound) / (inverseRange.upperBound - inverseRange.lowerBound)
    }
}

/// The one-time import of LinearMouse's configuration: its schemes with only the fields MouseService acts on; schemes
/// left with nothing but a condition are dropped.
public enum LinearMouseImport {
    public static func convert(_ data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemes = root["schemes"] as? [[String: Any]] else {
            throw DeviceRules.RulesError.noSchemes
        }
        let kept: [[String: Any]] = schemes.compactMap { scheme in
            var out: [String: Any] = [:]
            if let pointer = scheme["pointer"] as? [String: Any] {
                let p = pointer.filter { ["speed", "acceleration", "disableAcceleration"].contains($0.key) }
                if !p.isEmpty { out["pointer"] = p }
            }
            if let scrolling = scheme["scrolling"] as? [String: Any] {
                var s: [String: Any] = [:]
                if let reverse = scrolling["reverse"] { s["reverse"] = reverse }
                if let modifiers = scrolling["modifiers"] as? [String: Any] {
                    var m: [String: Any] = [:]
                    for axis in ["vertical", "horizontal"] {
                        guard let actions = modifiers[axis] as? [String: Any] else { continue }
                        let drops = actions.filter { ($0.value as? [String: Any])?["type"] as? String == "preventDefault" }
                        if !drops.isEmpty { m[axis] = drops }
                    }
                    if !m.isEmpty { s["modifiers"] = m }
                }
                if !s.isEmpty { out["scrolling"] = s }
            }
            guard !out.isEmpty else { return nil }
            if let condition = scheme["if"] { out["if"] = condition }
            return out
        }
        return try JSONSerialization.data(withJSONObject: ["schemes": kept], options: [.prettyPrinted, .sortedKeys])
    }
}
