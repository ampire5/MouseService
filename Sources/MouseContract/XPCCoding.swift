import CoreGraphics
import XPC

// The messages as XPC dictionaries: a string `type` and the fields named as in the Swift cases. A set of controls is
// an array of uint64, sorted; a rect four doubles `[x, y, w, h]`; an optional an absent key. Unknown keys are
// ignored; an unknown type or a missing required field decodes to nil.

extension ClientMessage {
    public func xpc() -> xpc_object_t {
        let d = Writer()
        switch self {
        case let .hello(version, bundleID):
            d.type("hello")
            d.string("version", version.text)
            d.string("bundleID", bundleID)
        case let .want(want):
            d.type("want")
            d.controls("divert", want.divert)
            d.controls("watch", want.watch)
            d.bool("thumbWheel", want.thumbWheel)
            d.array("wheel", want.wheel.map(Self.encode))
        case let .play(pattern, strength):
            d.type("play")
            d.uint("pattern", UInt64(pattern))
            if let strength { d.uint("strength", UInt64(strength)) }
        }
        return d.object
    }

    public init?(xpc object: xpc_object_t) {
        guard let d = Reader(object), let type = d.string("type") else { return nil }
        switch type {
        case "hello":
            guard let version = d.string("version").flatMap(ContractVersion.init), let bundleID = d.string("bundleID") else {
                return nil
            }
            self = .hello(version: version, bundleID: bundleID)
        case "want":
            guard let divert = d.controls("divert"), let watch = d.controls("watch"), let thumbWheel = d.bool("thumbWheel"),
                  let wheel = d.array("wheel") else { return nil }
            let wishes = wheel.compactMap(Self.decodeWish)
            guard wishes.count == wheel.count else { return nil }
            self = .want(Want(divert: divert, watch: watch, thumbWheel: thumbWheel, wheel: wishes))
        case "play":
            guard let pattern = d.uint("pattern").flatMap(UInt8.init(exactly:)) else { return nil }
            self = .play(pattern: pattern, strength: d.uint("strength").flatMap(UInt8.init(exactly:)))
        default:
            return nil
        }
    }

    private static func encode(_ wish: WheelWish) -> xpc_object_t {
        let d = Writer()
        d.int("window", Int64(wish.window))
        if let rects = wish.rects {
            d.array("rects", rects.map { r in
                let a = xpc_array_create_empty()
                for v in [r.origin.x, r.origin.y, r.size.width, r.size.height] { xpc_array_set_double(a, XPC_ARRAY_APPEND, v) }
                return a
            })
        }
        if let highResolution = wish.highResolution { d.bool("highResolution", highResolution) }
        if let mode = wish.mode { d.uint("mode", UInt64(mode.rawValue)) }
        return d.object
    }

    private static func decodeWish(_ object: xpc_object_t) -> WheelWish? {
        guard let d = Reader(object), let window = d.int("window") else { return nil }
        var rects: [CGRect]?
        if let raw = d.array("rects") {
            let decoded = raw.compactMap { a -> CGRect? in
                guard xpc_get_type(a) == XPC_TYPE_ARRAY, xpc_array_get_count(a) == 4 else { return nil }
                var v: [Double] = []
                for i in 0..<4 {
                    let item = xpc_array_get_value(a, i)
                    guard xpc_get_type(item) == XPC_TYPE_DOUBLE else { return nil }
                    v.append(xpc_double_get_value(item))
                }
                return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
            }
            guard decoded.count == raw.count else { return nil }
            rects = decoded
        }
        return WheelWish(window: Int(window), rects: rects, highResolution: d.bool("highResolution"),
                         mode: d.uint("mode").flatMap { UInt8(exactly: $0) }.flatMap(WheelMode.init(rawValue:)))
    }
}

extension ServiceMessage {
    public func xpc() -> xpc_object_t {
        let d = Writer()
        switch self {
        case let .welcome(serviceVersion, device):
            d.type("welcome")
            d.string("serviceVersion", serviceVersion)
            d.set("device", Self.encode(device))
        case let .refused(reason):
            d.type("refused")
            d.string("reason", reason)
        case let .owner(owner):
            d.type("owner")
            d.bool("owner", owner)
        case let .watching(cids):
            d.type("watching")
            d.controls("cids", cids)
        case let .button(cid, pressed, time):
            d.type("button")
            d.uint("cid", UInt64(cid))
            d.bool("pressed", pressed)
            d.double("time", time)
        case let .thumbWheel(delta, touching, phase, time):
            d.type("thumbWheel")
            d.int("delta", Int64(delta))
            d.bool("touching", touching)
            d.string("phase", phase.rawValue)
            d.double("time", time)
        case let .wheel(highResolution, mode, byButton):
            d.type("wheel")
            d.bool("highResolution", highResolution)
            if let mode { d.uint("mode", UInt64(mode.rawValue)) }
            d.bool("byButton", byButton)
        case let .device(device):
            d.type("device")
            d.set("device", Self.encode(device))
        }
        return d.object
    }

    public init?(xpc object: xpc_object_t) {
        guard let d = Reader(object), let type = d.string("type") else { return nil }
        switch type {
        case "welcome":
            guard let version = d.string("serviceVersion"), let device = d.dictionary("device").flatMap(Self.decodeDevice) else {
                return nil
            }
            self = .welcome(serviceVersion: version, device: device)
        case "refused":
            guard let reason = d.string("reason") else { return nil }
            self = .refused(reason: reason)
        case "owner":
            guard let owner = d.bool("owner") else { return nil }
            self = .owner(owner)
        case "watching":
            guard let cids = d.controls("cids") else { return nil }
            self = .watching(cids)
        case "button":
            guard let cid = d.uint("cid").flatMap(UInt16.init(exactly:)), let pressed = d.bool("pressed"),
                  let time = d.double("time") else { return nil }
            self = .button(cid: cid, pressed: pressed, time: time)
        case "thumbWheel":
            guard let delta = d.int("delta"), let touching = d.bool("touching"),
                  let phase = d.string("phase").flatMap(ThumbPhase.init(rawValue:)), let time = d.double("time") else {
                return nil
            }
            self = .thumbWheel(delta: Int(delta), touching: touching, phase: phase, time: time)
        case "wheel":
            guard let highResolution = d.bool("highResolution"), let byButton = d.bool("byButton") else { return nil }
            let mode = d.uint("mode").flatMap { UInt8(exactly: $0) }.flatMap(WheelMode.init(rawValue:))
            self = .wheel(highResolution: highResolution, mode: mode, byButton: byButton)
        case "device":
            guard let device = d.dictionary("device").flatMap(Self.decodeDevice) else { return nil }
            self = .device(device)
        default:
            return nil
        }
    }

    private static func encode(_ device: DeviceInfo) -> xpc_object_t {
        let d = Writer()
        d.bool("present", device.present)
        d.array("controls", device.controls.map { c in
            let w = Writer()
            w.uint("cid", UInt64(c.cid))
            w.bool("divertable", c.divertable)
            w.bool("watchable", c.watchable)
            return w.object
        })
        if let steps = device.thumbWheelStepsPerRevolution { d.int("thumbWheelStepsPerRevolution", Int64(steps)) }
        d.bool("haptics", device.haptics)
        return d.object
    }

    private static func decodeDevice(_ object: xpc_object_t) -> DeviceInfo? {
        guard let d = Reader(object), let present = d.bool("present"), let raw = d.array("controls"),
              let haptics = d.bool("haptics") else { return nil }
        let controls = raw.compactMap { o -> ControlInfo? in
            guard let c = Reader(o), let cid = c.uint("cid").flatMap(UInt16.init(exactly:)),
                  let divertable = c.bool("divertable"), let watchable = c.bool("watchable") else { return nil }
            return ControlInfo(cid: cid, divertable: divertable, watchable: watchable)
        }
        guard controls.count == raw.count else { return nil }
        return DeviceInfo(present: present, controls: controls,
                          thumbWheelStepsPerRevolution: d.int("thumbWheelStepsPerRevolution").map(Int.init),
                          haptics: haptics)
    }
}

// MARK: Dictionary access

private struct Writer {
    let object = xpc_dictionary_create_empty()

    func type(_ value: String) { string("type", value) }
    func string(_ key: String, _ value: String) { xpc_dictionary_set_string(object, key, value) }
    func bool(_ key: String, _ value: Bool) { xpc_dictionary_set_bool(object, key, value) }
    func int(_ key: String, _ value: Int64) { xpc_dictionary_set_int64(object, key, value) }
    func uint(_ key: String, _ value: UInt64) { xpc_dictionary_set_uint64(object, key, value) }
    func double(_ key: String, _ value: Double) { xpc_dictionary_set_double(object, key, value) }
    func set(_ key: String, _ value: xpc_object_t) { xpc_dictionary_set_value(object, key, value) }

    func array(_ key: String, _ items: [xpc_object_t]) {
        let a = xpc_array_create_empty()
        for item in items { xpc_array_append_value(a, item) }
        set(key, a)
    }

    func controls(_ key: String, _ cids: Set<UInt16>) {
        let a = xpc_array_create_empty()
        for cid in cids.sorted() { xpc_array_set_uint64(a, XPC_ARRAY_APPEND, UInt64(cid)) }
        set(key, a)
    }
}

/// Typed reads: a value of another XPC type than expected reads as absent.
private struct Reader {
    let object: xpc_object_t

    init?(_ object: xpc_object_t) {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else { return nil }
        self.object = object
    }

    private func value(_ key: String, _ type: xpc_type_t) -> xpc_object_t? {
        guard let v = xpc_dictionary_get_value(object, key), xpc_get_type(v) == type else { return nil }
        return v
    }

    func string(_ key: String) -> String? {
        value(key, XPC_TYPE_STRING).flatMap { xpc_string_get_string_ptr($0) }.map { String(cString: $0) }
    }
    func bool(_ key: String) -> Bool? { value(key, XPC_TYPE_BOOL).map(xpc_bool_get_value) }
    func int(_ key: String) -> Int64? { value(key, XPC_TYPE_INT64).map(xpc_int64_get_value) }
    func uint(_ key: String) -> UInt64? { value(key, XPC_TYPE_UINT64).map(xpc_uint64_get_value) }
    func double(_ key: String) -> Double? { value(key, XPC_TYPE_DOUBLE).map(xpc_double_get_value) }
    func dictionary(_ key: String) -> xpc_object_t? { value(key, XPC_TYPE_DICTIONARY) }

    func array(_ key: String) -> [xpc_object_t]? {
        guard let a = value(key, XPC_TYPE_ARRAY) else { return nil }
        return (0..<xpc_array_get_count(a)).map { xpc_array_get_value(a, $0) }
    }

    func controls(_ key: String) -> Set<UInt16>? {
        guard let items = array(key) else { return nil }
        let cids = items.compactMap { item -> UInt16? in
            guard xpc_get_type(item) == XPC_TYPE_UINT64 else { return nil }
            return UInt16(exactly: xpc_uint64_get_value(item))
        }
        return cids.count == items.count ? Set(cids) : nil
    }
}
