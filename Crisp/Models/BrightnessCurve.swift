import Foundation

/// Perceptual stepping for the brightness keys (F1/F2).
///
/// After the gamma-blend fix in `BrightnessService.writeDDCBrightnessCoalesced`,
/// emitted light is linear in percent across the whole 0...100 range. Perceived
/// brightness is not: the eye responds roughly to a power curve, so a fixed
/// step of 100/16 = 6.25 points is a ~80 % jump in light at the bottom of the
/// range and a ~7 % nudge at the top. That is the asymmetry behind "one press is
/// nothing, the next one blinds me".
///
/// So a press moves one step in a *perceptual* domain and is converted back.
/// The full range is still 16 presses (matching macOS), but they are ~2 points
/// wide near black and ~10 points wide near full, which is where the resolution
/// is actually wanted.
///
/// Pure math, no AppKit or IOKit, so it is compiled straight into the test target.
enum BrightnessCurve {

    /// Approximates perceived lightness from linear light. 2.2 is the standard
    /// display gamma and is close enough to CIE L* over this range; the exact
    /// value only changes how aggressively steps bunch up at the dark end.
    static let gamma: Double = 2.2

    /// Presses needed to traverse the full range. Matches macOS's own 1/16 stepping,
    /// so muscle memory from the built-in display carries over.
    static let stepsPerRange: Double = 16.0

    /// Smallest movement a press may produce, in percent. Without this the curve
    /// rounds to a no-op near 0 (a perceptual step off zero lands at 0.002 %),
    /// which reads as a dead key.
    static let minimumStep: Double = 0.5

    /// Linear percent (0...100) -> perceptual position (0...1).
    static func perceptual(fromPercent percent: Double) -> Double {
        let clamped = min(max(percent, 0.0), 100.0)
        return pow(clamped / 100.0, 1.0 / gamma)
    }

    /// Perceptual position (0...1) -> linear percent (0...100).
    static func percent(fromPerceptual position: Double) -> Double {
        let clamped = min(max(position, 0.0), 1.0)
        return pow(clamped, gamma) * 100.0
    }

    /// One key press from `percent`, in the direction given by `up`.
    ///
    /// Guarantees, all covered by `BrightnessCurveTests`:
    /// - the result stays inside 0...100,
    /// - it always moves by at least `minimumStep` unless already clamped at an end,
    /// - it is strictly monotonic in `percent`.
    static func stepped(from percent: Double, up: Bool) -> Double {
        let start = min(max(percent, 0.0), 100.0)
        let delta = (up ? 1.0 : -1.0) / stepsPerRange
        let curved = self.percent(fromPerceptual: perceptual(fromPercent: start) + delta)
        // Near the ends the curve compresses below a perceptible move; floor it so a
        // press is never swallowed.
        let nudged = up ? max(curved, start + minimumStep) : min(curved, start - minimumStep)
        return min(max(nudged, 0.0), 100.0)
    }
}
