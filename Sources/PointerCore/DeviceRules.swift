import Foundation
import Yams

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

/// What one block of `config.yaml` sets: a device's own fields, or those of one of its apps. A field that is nil leaves
/// what an earlier entry set; `reverse` and the two drop lists replace as a whole.
struct RuleFields: Equatable, Sendable {
    var speed: Double?
    var acceleration: Double?
    var disableAcceleration: Bool?
    var reverse: (vertical: Bool, horizontal: Bool)?
    var dropVertical: ModifierSet?
    var dropHorizontal: ModifierSet?

    static func == (a: Self, b: Self) -> Bool {
        a.speed == b.speed && a.acceleration == b.acceleration && a.disableAcceleration == b.disableAcceleration
            && a.reverse?.vertical == b.reverse?.vertical && a.reverse?.horizontal == b.reverse?.horizontal
            && a.dropVertical == b.dropVertical && a.dropHorizontal == b.dropHorizontal
    }

    func apply(to result: inout ResolvedRules) {
        if let speed { result.pointer.speed = speed }
        if let acceleration { result.pointer.acceleration = acceleration }
        if let disableAcceleration { result.pointer.disableAcceleration = disableAcceleration }
        if let reverse {
            result.scroll.reverseVertical = reverse.vertical
            result.scroll.reverseHorizontal = reverse.horizontal
        }
        if let dropVertical { result.scroll.dropVertical = dropVertical }
        if let dropHorizontal { result.scroll.dropHorizontal = dropHorizontal }
    }
}

/// `config.yaml` (design spec `2026-10-28-yaml-config-design.md`): the devices, each named once with its app rules
/// nested. Every entry that matches a device applies in file order, its own fields and then those of its entry for the
/// frontmost app.
public struct DeviceRules: Sendable {
    struct Entry: Sendable {
        var vendorID: Int
        var productID: Int
        var serialNumber: String?
        var fields: RuleFields
        var apps: [String: RuleFields]

        func matches(_ device: DeviceIdentity) -> Bool {
            vendorID == device.vendorID && productID == device.productID
                && (serialNumber == nil || serialNumber == device.serialNumber)
        }
    }

    var entries: [Entry]
    /// The keys present in the file that MouseService does not act on, as paths.
    public private(set) var ignoredFields: [String]

    public var count: Int { entries.count }
    /// Whether some entry has app rules: the frontmost app then matters.
    public var dependsOnApp: Bool { entries.contains { !$0.apps.isEmpty } }

    public static let empty = DeviceRules(entries: [], ignoredFields: [])

    init(entries: [Entry], ignoredFields: [String]) {
        self.entries = entries
        self.ignoredFields = ignoredFields
    }

    public func resolve(_ device: DeviceIdentity, app: String?) -> ResolvedRules {
        var result = ResolvedRules()
        for entry in entries where entry.matches(device) {
            entry.fields.apply(to: &result)
            if let app, let fields = entry.apps[app] { fields.apply(to: &result) }
        }
        return result
    }

    // MARK: Parsing

    public enum RulesError: Error, Equatable, CustomStringConvertible {
        case syntax(String)
        case bad(String)

        public var description: String {
            switch self {
            case let .syntax(message): "not YAML: \(message)"
            case let .bad(path): "bad value at \(path.isEmpty ? "the top level" : path)"
            }
        }
    }

    public init(yaml text: String) throws {
        let root: Node?
        do { root = try Yams.compose(yaml: text) } catch { throw RulesError.syntax("\(error)") }
        var ignored: [String] = []
        var entries: [Entry] = []
        if let root, !Self.isEmpty(root) {
            guard let top = root.mapping else { throw RulesError.bad("") }
            for (key, value) in top {
                guard key.string == "devices" else {
                    ignored.append(key.string ?? "?")
                    continue
                }
                if Self.isEmpty(value) { continue }
                guard let devices = value.mapping else { throw RulesError.bad("devices") }
                for (nameNode, body) in devices {
                    let name = nameNode.string ?? "?"
                    entries.append(try Self.entry(body, path: "devices.\(name)", ignored: &ignored))
                }
            }
        }
        self.entries = entries
        ignoredFields = ignored
    }

    /// A comment-only file, or a key with nothing under it.
    private static func isEmpty(_ node: Node) -> Bool {
        node.scalar.map { $0.string.isEmpty } ?? false
    }

    private static func entry(_ body: Node, path: String, ignored: inout [String]) throws -> Entry {
        guard let map = body.mapping else { throw RulesError.bad(path) }
        var id: (Int, Int)?
        var serial: String?
        var fields = RuleFields()
        var apps: [String: RuleFields] = [:]
        for (keyNode, value) in map {
            let key = keyNode.string ?? "?"
            switch key {
            case "id": id = try Self.id(value, "\(path).id")
            case "serial":
                guard let s = value.string, !s.isEmpty else { throw RulesError.bad("\(path).serial") }
                serial = s
            case "apps":
                guard let list = value.mapping else {
                    if isEmpty(value) { continue }
                    throw RulesError.bad("\(path).apps")
                }
                for (appNode, block) in list {
                    let app = appNode.string ?? "?"
                    apps[app] = try Self.fields(block, path: "\(path).apps.\(app)", ignored: &ignored)
                }
            default:
                try Self.field(key, value, into: &fields, path: path, ignored: &ignored)
            }
        }
        guard let id else { throw RulesError.bad("\(path).id") }
        return Entry(vendorID: id.0, productID: id.1, serialNumber: serial, fields: fields, apps: apps)
    }

    private static func fields(_ body: Node, path: String, ignored: inout [String]) throws -> RuleFields {
        guard let map = body.mapping else {
            if isEmpty(body) { return RuleFields() }
            throw RulesError.bad(path)
        }
        var fields = RuleFields()
        for (keyNode, value) in map {
            try Self.field(keyNode.string ?? "?", value, into: &fields, path: path, ignored: &ignored)
        }
        return fields
    }

    private static func field(_ key: String, _ value: Node, into fields: inout RuleFields, path: String,
                              ignored: inout [String]) throws {
        let at = "\(path).\(key)"
        switch key {
        case "speed": fields.speed = try number(value, at, in: 0...1)
        case "acceleration": fields.acceleration = try number(value, at, in: 0...40)
        case "disable-acceleration":
            switch value.string {
            case "true": fields.disableAcceleration = true
            case "false": fields.disableAcceleration = false
            default: throw RulesError.bad(at)
            }
        case "reverse-scroll":
            switch value.string {
            case "none": fields.reverse = (false, false)
            case "vertical": fields.reverse = (true, false)
            case "horizontal": fields.reverse = (false, true)
            case "both": fields.reverse = (true, true)
            default: throw RulesError.bad(at)
            }
        case "ignore-vertical-scroll-with": fields.dropVertical = try modifiers(value, at)
        case "ignore-horizontal-scroll-with": fields.dropHorizontal = try modifiers(value, at)
        default: ignored.append(at)
        }
    }

    /// `vendor:product`, hex with or without `0x`; read as the text it is (YAML would take `1234:5678` for a number).
    private static func id(_ node: Node, _ path: String) throws -> (Int, Int) {
        guard let text = node.string else { throw RulesError.bad(path) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        func hex(_ s: Substring) -> Int? {
            let digits = s.lowercased().hasPrefix("0x") ? s.dropFirst(2) : s
            return Int(digits, radix: 16)
        }
        guard parts.count == 2, let vendor = hex(parts[0]), let product = hex(parts[1]) else { throw RulesError.bad(path) }
        return (vendor, product)
    }

    private static func number(_ node: Node, _ path: String, in range: ClosedRange<Double>) throws -> Double {
        guard node.scalar != nil, let text = node.string, let n = Double(text), n.isFinite else { throw RulesError.bad(path) }
        return min(max(n, range.lowerBound), range.upperBound)
    }

    /// A list of modifier names (a single name is a list of one).
    private static func modifiers(_ node: Node, _ path: String) throws -> ModifierSet {
        let names: [Node] = node.sequence.map { Array($0) } ?? (node.scalar.map { _ in [node] } ?? [])
        guard node.sequence != nil || node.scalar != nil else { throw RulesError.bad(path) }
        var set: ModifierSet = []
        for name in names where !(name.string ?? "").isEmpty {
            guard let match = ModifierSet.byName.first(where: { $0.0 == name.string }) else { throw RulesError.bad(path) }
            set.insert(match.1)
        }
        return set
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
