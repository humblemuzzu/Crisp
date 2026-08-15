import XCTest

/// Headless tests for the brightness-key stepping curve.
///
/// `BrightnessCurve` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DisplayModeGeometry`), so no `@testable import Crisp` is
/// needed. These exist because of a shipped regression: light output was quadratic
/// below the gamma blend threshold while the key step stayed linear, so one press
/// near the dark end changed actual light by >3x. Each test names the mutation it
/// is designed to kill.
final class BrightnessCurveTests: XCTestCase {

    // MARK: - Round trip

    /// *Round trip.* percent -> perceptual -> percent is the identity.
    /// Kills: a curve that applies gamma in the same direction both ways.
    func testPerceptualRoundTripIsIdentity() {
        for percent in stride(from: 0.0, through: 100.0, by: 2.5) {
            let back = BrightnessCurve.percent(
                fromPerceptual: BrightnessCurve.perceptual(fromPercent: percent)
            )
            XCTAssertEqual(back, percent, accuracy: 0.0001, "round trip failed at \(percent)")
        }
    }

    /// *Clamping.* Out-of-range inputs saturate instead of producing NaN from pow().
    /// Kills: dropping the clamps in perceptual(fromPercent:) / percent(fromPerceptual:).
    func testOutOfRangeInputsClamp() {
        XCTAssertEqual(BrightnessCurve.perceptual(fromPercent: -50), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BrightnessCurve.perceptual(fromPercent: 500), 1.0, accuracy: 0.0001)
        XCTAssertEqual(BrightnessCurve.percent(fromPerceptual: -1), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BrightnessCurve.percent(fromPerceptual: 9), 100.0, accuracy: 0.0001)
    }

    // MARK: - The regression this file exists for

    /// *No blinding jump.* THE regression test. Walking up from black, no single press
    /// may more than double emitted light once past a perceptible floor. The shipped bug
    /// produced a 3.3x jump at ~8 %.
    /// Kills: reverting to a flat additive step, or raising gamma high enough to bunch.
    func testNoSinglePressMoreThanDoublesLight() {
        var percent = 0.0
        for press in 0..<64 {
            let next = BrightnessCurve.stepped(from: percent, up: true)
            // Below 2 % the absolute change is imperceptible, so ratios there are noise.
            if percent >= 2.0 {
                XCTAssertLessThanOrEqual(
                    next / percent, 2.0,
                    "press \(press): \(percent)% -> \(next)% is a \(next / percent)x jump in light"
                )
            }
            percent = next
            if percent >= 100.0 { break }
        }
        XCTAssertEqual(percent, 100.0, accuracy: 0.0001, "stepping up must reach full")
    }

    /// *Monotonic.* A brighter starting point never yields a darker result, both
    /// directions. Non-decreasing rather than strictly increasing because the ends
    /// clamp: every start above 99.5 maps to 100.
    /// Kills: any non-monotonic curve or a sign error in the delta.
    func testSteppingIsMonotonicInStartingValue() {
        for up in [true, false] {
            var previous = -1.0
            for percent in stride(from: 0.0, through: 100.0, by: 0.5) {
                let next = BrightnessCurve.stepped(from: percent, up: up)
                XCTAssertGreaterThanOrEqual(next, previous, "non-monotonic at \(percent), up=\(up)")
                previous = next
            }
        }
    }

    /// *Strictly monotonic where unclamped.* Wherever the result is not sitting on a
    /// clamp, a higher start must give a strictly higher result, so distinct levels
    /// never collapse together. The clamped regions are excluded rather than assumed:
    /// stepping up saturates at 100 from ~87 % onward, which is correct behaviour.
    /// Kills: a curve that plateaus mid-range (e.g. an over-eager minimumStep floor).
    func testSteppingIsStrictlyMonotonicWhereUnclamped() {
        for up in [true, false] {
            var previous: Double?
            for percent in stride(from: 0.0, through: 100.0, by: 0.5) {
                let next = BrightnessCurve.stepped(from: percent, up: up)
                if let previous, next < 100.0, previous > 0.0 {
                    XCTAssertGreaterThan(next, previous, "plateau at \(percent), up=\(up)")
                }
                previous = next
            }
        }
    }

    /// *Direction.* Up increases, down decreases, everywhere in the interior.
    /// Kills: an inverted delta.
    func testDirectionIsRespected() {
        for percent in stride(from: 1.0, through: 99.0, by: 1.0) {
            XCTAssertGreaterThan(BrightnessCurve.stepped(from: percent, up: true), percent)
            XCTAssertLessThan(BrightnessCurve.stepped(from: percent, up: false), percent)
        }
    }

    /// *Never a dead key.* Every press moves by at least minimumStep in the interior,
    /// including right off zero where the curve would otherwise round to ~0.002 %.
    /// Kills: removing the minimumStep floor in stepped(from:up:).
    func testEveryPressMovesPerceptibly() {
        XCTAssertGreaterThanOrEqual(
            BrightnessCurve.stepped(from: 0.0, up: true), BrightnessCurve.minimumStep
        )
        // Stop at 99.5: past that the top clamp legitimately shortens the last press.
        for percent in stride(from: 0.0, through: 99.5 - BrightnessCurve.minimumStep, by: 0.5) {
            let next = BrightnessCurve.stepped(from: percent, up: true)
            XCTAssertGreaterThanOrEqual(next - percent, BrightnessCurve.minimumStep - 0.0001,
                                        "press up at \(percent)% moved less than the floor")
        }
        for percent in stride(from: BrightnessCurve.minimumStep, through: 100.0, by: 0.5) {
            let next = BrightnessCurve.stepped(from: percent, up: false)
            XCTAssertGreaterThanOrEqual(percent - next, BrightnessCurve.minimumStep - 0.0001,
                                        "press down at \(percent)% moved less than the floor")
        }
    }

    /// *Bounds.* Results never escape 0...100 and the ends are fixed points.
    /// Kills: dropping the final clamp in stepped(from:up:).
    func testStaysInRangeAndEndsAreStable() {
        XCTAssertEqual(BrightnessCurve.stepped(from: 100.0, up: true), 100.0, accuracy: 0.0001)
        XCTAssertEqual(BrightnessCurve.stepped(from: 0.0, up: false), 0.0, accuracy: 0.0001)
        for percent in stride(from: -10.0, through: 110.0, by: 3.0) {
            for up in [true, false] {
                let next = BrightnessCurve.stepped(from: percent, up: up)
                XCTAssertGreaterThanOrEqual(next, 0.0)
                XCTAssertLessThanOrEqual(next, 100.0)
            }
        }
    }

    /// *Resolution where it matters.* A press near black must be a much smaller absolute
    /// move than a press near full. That asymmetry is the entire point of the curve.
    /// Kills: replacing the curve with any linear stepping (which makes these equal).
    func testDarkEndHasFinerResolutionThanBrightEnd() {
        let darkMove = BrightnessCurve.stepped(from: 5.0, up: true) - 5.0
        let brightMove = BrightnessCurve.stepped(from: 90.0, up: true) - 90.0
        XCTAssertLessThan(darkMove, brightMove / 2.0,
                          "dark step \(darkMove) should be far finer than bright step \(brightMove)")
    }

    /// *Full traversal cost.* Crossing the range takes about stepsPerRange presses, so
    /// muscle memory from the built-in display carries over.
    /// Kills: changing stepsPerRange without intending to.
    func testFullRangeTakesRoughlySixteenPresses() {
        var percent = 0.0
        var presses = 0
        while percent < 100.0, presses < 200 {
            percent = BrightnessCurve.stepped(from: percent, up: true)
            presses += 1
        }
        XCTAssertGreaterThanOrEqual(presses, 12)
        XCTAssertLessThanOrEqual(presses, 22)
    }
}
