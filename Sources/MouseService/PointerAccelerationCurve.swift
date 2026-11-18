import Foundation
import PointerCore

/// An IOHID user curve: a quadratic up to the knee, then its tangent line.
/// IOHID normalizes the speed by pointer resolution, so sensitivity remains adjustable for every curve.
struct PointerAccelerationCurve {
    static let property = "UserPointerAccelCurvesKey"
    static let index: Double = 1

    let lowSpeedGain: Double
    let highSpeedGain: Double
    let knee: Double

    init?(_ profile: PointerProfile?) {
        switch profile {
        case .linear:
            (lowSpeedGain, highSpeedGain, knee) = (1, 1, 1)
        case .windowsEPP:
            (lowSpeedGain, highSpeedGain, knee) = (0.43, 2.4, 5)
        case .libinputAdaptive:
            (lowSpeedGain, highSpeedGain, knee) = (0.30, 2.2, 10)
        case .macOS, nil:
            return nil
        }
    }

    var hidValue: NSArray {
        func fixed(_ value: Double) -> Int { Int((value * 65536).rounded()) }
        // IOHID squares the parabolic coefficient, and uses the derivative at the knee above it.
        let parabolic = ((highSpeedGain - lowSpeedGain) / (2 * knee)).squareRoot()
        return [[
            "HIDAccelIndex": fixed(Self.index),
            "HIDAccelGainLinear": fixed(lowSpeedGain),
            "HIDAccelGainParabolic": fixed(parabolic),
            "HIDAccelTangentSpeedLinear": fixed(knee),
        ]] as NSArray
    }
}
