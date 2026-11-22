import Foundation

struct D100HTurnMapping: Codable, Equatable {
    enum Slot: UInt8, CaseIterable {
        case left = 0x0b
        case right = 0x0c
    }

    struct Assignments: Codable, Equatable {
        let left: UInt8
        let right: UInt8

        subscript(slot: Slot) -> UInt8 { slot == .left ? left : right }
    }

    let device: UUID
    let original: Assignments

    enum Action: Equatable {
        case ready, forget, conflict
        case save(D100HTurnMapping)
        case write(Slot, UInt8)
    }

    private static let profile = Assignments(left: 0x15, right: 0x60)

    static func action(device: UUID, current: Assignments, enabled: Bool, saved: Self?) -> Action {
        if let saved, saved.device != device { return .conflict }
        if enabled {
            if current == profile { return .ready }
            guard let saved else { return .save(Self(device: device, original: current)) }
            for slot in Slot.allCases where current[slot] != profile[slot] {
                guard current[slot] == saved.original[slot] else { return .conflict }
            }
            if let slot = Slot.allCases.first(where: { current[$0] != profile[$0] }) {
                return .write(slot, profile[slot])
            }
        } else if let saved {
            // Another owner's edits survive. Only undo values installed by this profile.
            if let slot = Slot.allCases.first(where: { current[$0] == profile[$0] && current[$0] != saved.original[$0] }) {
                return .write(slot, saved.original[slot])
            }
            return .forget
        }
        return .ready
    }
}
