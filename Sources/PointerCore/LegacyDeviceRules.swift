import Foundation

/// LinearMouse's schemes (`devices.json`, LinearMouse's own file), the fields MouseService acted on. Kept to migrate
/// them into `config.yaml` (`DevicesMigration`) and to prove the migration exact. Schemes whose `if` matches apply in
/// file order, later fields over earlier ones.
public struct LegacyDeviceRules: Sendable {
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

    /// The devices the conditions name by vendor and product (and serial), one identity per such triple, with the first
    /// name and category given for it (a category left out is a mouse).
    var identities: [DeviceIdentity] {
        var order: [[String]] = []
        var found: [[String]: DeviceIdentity] = [:]
        for condition in schemes.flatMap(\.conditions) where !condition.unsupported {
            guard let vendor = condition.vendorID, let product = condition.productID else { continue }
            let key = ["\(vendor)", "\(product)", condition.serialNumber ?? ""]
            if var device = found[key] {
                device.productName = device.productName ?? condition.productName
                if condition.category != nil, device.category == .mouse { device.category = condition.category ?? .mouse }
                found[key] = device
            } else {
                order.append(key)
                found[key] = DeviceIdentity(vendorID: vendor, productID: product, productName: condition.productName,
                                            serialNumber: condition.serialNumber, category: condition.category ?? .mouse)
            }
        }
        return order.compactMap { found[$0] }
    }

    /// Every app the conditions name, in first-seen order.
    var apps: [String] {
        var seen = Set<String>()
        return schemes.flatMap(\.conditions).compactMap(\.app).filter { seen.insert($0).inserted }
    }

    public static let empty = LegacyDeviceRules(schemes: [], ignoredFields: [])

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
