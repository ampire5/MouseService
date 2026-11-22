import Foundation

/// The exact setting found before muting a specific bonded dial.
struct D100HDetentRecovery: Codable, Equatable {
    let device: UUID
    let value: UInt16

    enum Action: Equatable {
        case idle
        case save(D100HDetentRecovery)
        case forget
        case write(UInt16)
    }

    static func action(device: UUID, current: UInt16, muted: Bool, saved: Self?) -> Action {
        if let saved, saved.device != device { return .idle }
        if muted, current != 0 {
            let original = Self(device: device, value: current)
            return saved == original ? .write(0) : .save(original)
        }
        if !muted, let saved {
            return current == 0 && saved.value != 0 ? .write(saved.value) : .forget
        }
        return .idle
    }
}
