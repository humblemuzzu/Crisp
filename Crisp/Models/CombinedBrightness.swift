import Foundation

/// The combined hardware + software brightness model, as used by BetterDisplay and
/// MonitorControl.
///
/// A monitor's DDC backlight does not reach zero. On the BenQ MA320U, DDC 0 is still
/// ~59 nits (TFTCentral measured 59-591 nits across the range) — a normal, comfortable
/// room brightness rather than anything close to dark. So one user-facing 0...100 value
/// is split across two dimmers at a switchover point:
///
///     u <= switchover : backlight parked at `hardwareFloor`, gamma carries u/switchover
///     u >  switchover : gamma off, backlight ramps hardwareFloor -> 100
///
/// The consequence that matters: at `u == switchover` the panel sits at its minimum
/// backlight with no software dimming at all. That is exactly where this user was
/// comfortable under BetterDisplay — its prefs recorded, for this display,
/// `combinedBrightness 0.5 / hardwareBrightness(DDC) 0 / softwareBrightness 1` — and
/// under this model it lands mid-slider, at press 8 of 16.
///
/// The model this replaces gave the whole 0...100 range to the backlight and pinned it
/// at 15 % from below, so the entire comfortable band was crushed into the bottom ~12 %
/// of the scale: one HUD segment was usable, two were blinding.
///
/// Pure math, no AppKit or IOKit, so it compiles straight into the test target.
enum CombinedBrightness {

    /// Slider percent below which dimming happens in software. 50 is the external-display
    /// default in both BetterDisplay and MonitorControl.
    static let switchover: Double = 50.0

    /// Lowest DDC value the backlight is driven to. 0 suits DC-dimmed, flicker-free panels
    /// like the MA320U. Panels that switch to PWM at low backlight want this raised, which
    /// is the only reason BetterDisplay exposes it — so it stays a parameter, not a constant.
    static let defaultHardwareFloor: Double = 0.0

    /// Presses to cross the full range. Flat 1/16, matching macOS, BetterDisplay and
    /// MonitorControl. The split itself does the perceptual work: below the switchover a
    /// press moves gamma, above it a press moves backlight. No extra curve is wanted on
    /// top — one would spend resolution in the region the user never occupies.
    static let stepsPerRange: Double = 16.0

    private static func clampedParameters(
        _ switchover: Double, _ hardwareFloor: Double
    ) -> (s: Double, floor: Double) {
        (min(max(switchover, 1.0), 99.0), min(max(hardwareFloor, 0.0), 100.0))
    }

    /// Splits one combined value into what each dimmer should do.
    /// - Returns: `hardware` as a DDC percent 0...100, and `software` as a gamma percent
    ///   0...100 where 100 means no software dimming at all.
    static func split(
        combined: Double,
        switchover: Double = switchover,
        hardwareFloor: Double = defaultHardwareFloor
    ) -> (hardware: Double, software: Double) {
        let u = min(max(combined, 0.0), 100.0)
        let (s, floor) = clampedParameters(switchover, hardwareFloor)
        if u <= s {
            return (hardware: floor, software: u / s * 100.0)
        }
        let above = (u - s) / (100.0 - s)
        return (hardware: floor + (100.0 - floor) * above, software: 100.0)
    }

    /// Inverse of `split`, for adopting a value read back from the hardware.
    ///
    /// Required because inside the software region a DDC read reports the parked floor,
    /// not what the user sees: adopting it raw would snap the slider to the switchover.
    static func combined(
        hardware: Double,
        software: Double,
        switchover: Double = switchover,
        hardwareFloor: Double = defaultHardwareFloor
    ) -> Double {
        let (s, floor) = clampedParameters(switchover, hardwareFloor)
        let sw = min(max(software, 0.0), 100.0)
        if sw < 100.0 {
            return sw / 100.0 * s
        }
        let hw = min(max(hardware, floor), 100.0)
        let span = max(100.0 - floor, 0.0001)
        return s + (hw - floor) / span * (100.0 - s)
    }

    /// One key press, snapped to the 1/16 grid so presses land on HUD segment boundaries
    /// even when the current value arrived from a drag.
    static func stepped(from combined: Double, up: Bool) -> Double {
        let step = 100.0 / stepsPerRange
        let index = (min(max(combined, 0.0), 100.0) / step).rounded()
        let next = (index + (up ? 1.0 : -1.0)) * step
        return min(max(next, 0.0), 100.0)
    }
}
