import Foundation

/// D100H's 20-byte frames on service 1971. The framing and fixed TEA key are documented at
/// https://github.com/bitboxx/ulanzi-d100h/blob/main/PROTOCOL.md.
enum D100HProtocol {
    enum DetentReply: Equatable {
        case read(UInt16)
        case write(UInt16)
    }
    enum AssignmentReply: Equatable {
        case read(D100HTurnMapping.Slot, UInt8)
        case write(D100HTurnMapping.Slot, UInt8)
    }

    private static let key: [UInt32] = [0xcaa5baca, 0xbc2a8a6d, 0xca5a9eba, 0x9bb88bca]
    private static let delta: UInt32 = 0x9e3779b9

    static func readDetents() -> Data { command(0x01, value: 0) }
    static func writeDetents(_ value: UInt16) -> Data { command(0x04, value: value) }

    static func detentReply(_ packet: Data) -> DetentReply? {
        guard let (left, right) = decode(packet) else { return nil }
        let value = UInt16(truncatingIfNeeded: right)
        switch left {
        case 0x11400601: return .read(value)
        case 0x14400601: return .write(value)
        default: return nil
        }
    }

    static func readAssignment(_ slot: D100HTurnMapping.Slot) -> Data {
        frame(0x01100601, UInt32(slot.rawValue) << 8)
    }

    static func writeAssignment(_ slot: D100HTurnMapping.Slot, _ value: UInt8) -> Data {
        frame(0x04100601, UInt32(slot.rawValue) << 8 | UInt32(value) << 16)
    }

    static func assignmentReply(_ packet: Data) -> AssignmentReply? {
        guard let (header, payload) = decode(packet), UInt8(truncatingIfNeeded: payload) == 0,
              let slot = D100HTurnMapping.Slot(rawValue: UInt8(truncatingIfNeeded: payload >> 8)) else { return nil }
        let value = UInt8(truncatingIfNeeded: payload >> 16)
        switch header {
        case 0x11100601: return .read(slot, value)
        case 0x14100601: return .write(slot, value)
        default: return nil
        }
    }

    private static func decode(_ packet: Data) -> (UInt32, UInt32)? {
        guard packet.count == 20 else { return nil }
        let bytes = Array(packet)
        var left = word(bytes, at: 0)
        var right = word(bytes, at: 4)
        var sum = delta &* 32

        for _ in 0..<32 {
            right = right &- mix(left, sum, key[2], key[3])
            left = left &- mix(right, sum, key[0], key[1])
            sum = sum &- delta
        }

        return (left, right)
    }

    private static func command(_ operation: UInt8, value: UInt16) -> Data {
        let header = 0x00400601 | UInt32(operation) << 24
        return frame(header, UInt32(value))
    }

    private static func frame(_ header: UInt32, _ payload: UInt32) -> Data {
        Data(encrypt(header, payload) + encrypt(0, 0) + [0, 0, 0, 0])
    }

    private static func encrypt(_ first: UInt32, _ second: UInt32) -> [UInt8] {
        var left = first
        var right = second
        var sum: UInt32 = 0
        for _ in 0..<32 {
            sum = sum &+ delta
            left = left &+ mix(right, sum, key[0], key[1])
            right = right &+ mix(left, sum, key[2], key[3])
        }
        return bytes(left) + bytes(right)
    }

    private static func mix(_ word: UInt32, _ sum: UInt32, _ low: UInt32, _ high: UInt32) -> UInt32 {
        ((word << 4) &+ low) ^ (word &+ sum) ^ ((word >> 5) &+ high)
    }

    private static func bytes(_ word: UInt32) -> [UInt8] {
        [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: word >> $0) }
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
