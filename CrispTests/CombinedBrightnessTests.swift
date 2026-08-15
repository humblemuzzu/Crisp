import XCTest

/// Headless tests for the combined hardware + software brightness model.
///
/// `CombinedBrightness` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DisplayModeGeometry`), so no `@testable import Crisp` is
/// needed. These exist because of a shipped regression: the backlight was given the
/// whole 0...100 range and pinned at 15 % from below, so a monitor whose DDC 0 is
/// already ~59 nits had its entire comfortable band crushed into the bottom ~12 % of
/// the scale. Each test names the mutation it is designed to kill.
final class CombinedBrightnessTests: XCTestCase {

    private let accuracy = 0.0001

    // MARK: - The anchor this model exists to reproduce

    /// *The BetterDisplay anchor.* THE regression test. At the switchover the backlight
    /// must be at its floor with no software dimming, reproducing the exact state
    /// BetterDisplay persisted for this display at the user's comfortable setting
    /// (combined 0.5, hardware DDC 0, software 1.0).
    /// Kills: any model that drives the backlight above its floor at mid-slider.
    func testSwitchoverIsFloorBacklightWithNoSoftwareDimming() {
        let split = CombinedBrightness.split(combined: CombinedBrightness.switchover)
        XCTAssertEqual(split.hardware, CombinedBrightness.defaultHardwareFloor, accuracy: accuracy)
        XCTAssertEqual(split.software, 100.0, accuracy: accuracy)
    }

    /// *Mid-slider comfort.* The comfortable point must be reachable at press 8 of 16,
    /// not in the first segment. Kills: shifting the switchover away from the midpoint.
    func testComfortPointLandsMidSlider() {
        var value = 0.0
        var presses = 0
        while value < CombinedBrightness.switchover, presses < 100 {
            value = CombinedBrightness.stepped(from: value, up: true)
            presses += 1
        }
        XCTAssertEqual(value, CombinedBrightness.switchover, accuracy: accuracy)
        XCTAssertEqual(presses, 8)
    }

    // MARK: - Split

    /// *Endpoints.* 0 is fully dark in software, 100 is full backlight.
    /// Kills: an inverted or offset mapping.
    func testEndpoints() {
        let bottom = CombinedBrightness.split(combined: 0)
        XCTAssertEqual(bottom.hardware, CombinedBrightness.defaultHardwareFloor, accuracy: accuracy)
        XCTAssertEqual(bottom.software, 0.0, accuracy: accuracy)

        let top = CombinedBrightness.split(combined: 100)
        XCTAssertEqual(top.hardware, 100.0, accuracy: accuracy)
        XCTAssertEqual(top.software, 100.0, accuracy: accuracy)
    }

    /// *Only one dimmer moves at a time.* Below the switchover the backlight is constant;
    /// above it the software dim is constant. Stacking both is what made the old curve
    /// quadratic. Kills: reintroducing a multiplied blend region.
    func testExactlyOneDimmerVariesInEachRegion() {
        for u in stride(from: 0.0, through: CombinedBrightness.switchover, by: 1.0) {
            XCTAssertEqual(CombinedBrightness.split(combined: u).hardware,
                           CombinedBrightness.defaultHardwareFloor, accuracy: accuracy,
                           "backlight moved below the switchover at \(u)")
        }
        for u in stride(from: CombinedBrightness.switchover, through: 100.0, by: 1.0) {
            XCTAssertEqual(CombinedBrightness.split(combined: u).software, 100.0, accuracy: accuracy,
                           "software dim engaged above the switchover at \(u)")
        }
    }

    /// *Continuity.* No discontinuity in either dimmer as the value crosses the switchover.
    /// Kills: an off-by-one in the region boundary, which would show as a visible jump.
    func testNoJumpAcrossTheSwitchover() {
        let below = CombinedBrightness.split(combined: CombinedBrightness.switchover - 0.001)
        let above = CombinedBrightness.split(combined: CombinedBrightness.switchover + 0.001)
        XCTAssertEqual(below.hardware, above.hardware, accuracy: 0.01)
        XCTAssertEqual(below.software, above.software, accuracy: 0.01)
    }

    /// *Monotonic in emitted light.* Raising the combined value must never lower either
    /// dimmer. Kills: a sign error in either branch.
    func testSplitIsMonotonic() {
        var lastHardware = -1.0
        var lastSoftware = -1.0
        for u in stride(from: 0.0, through: 100.0, by: 0.5) {
            let split = CombinedBrightness.split(combined: u)
            XCTAssertGreaterThanOrEqual(split.hardware, lastHardware - accuracy, "backlight dipped at \(u)")
            XCTAssertGreaterThanOrEqual(split.software, lastSoftware - accuracy, "software dipped at \(u)")
            lastHardware = split.hardware
            lastSoftware = split.software
        }
    }

    /// *Clamping.* Out-of-range input saturates instead of driving the backlight past 100
    /// or negative. Kills: dropping the clamps in split().
    func testSplitClampsOutOfRangeInput() {
        XCTAssertEqual(CombinedBrightness.split(combined: -40).software, 0.0, accuracy: accuracy)
        XCTAssertEqual(CombinedBrightness.split(combined: 400).hardware, 100.0, accuracy: accuracy)
    }

    // MARK: - Inverse

    /// *Round trip.* split -> combined is the identity across the range. This is what lets
    /// a DDC readback be adopted safely. Kills: an inverse that ignores the software factor,
    /// which would snap the slider to the switchover on every refresh.
    func testCombinedIsTheInverseOfSplit() {
        for u in stride(from: 0.0, through: 100.0, by: 0.5) {
            let split = CombinedBrightness.split(combined: u)
            let back = CombinedBrightness.combined(hardware: split.hardware, software: split.software)
            XCTAssertEqual(back, u, accuracy: 0.0001, "round trip failed at \(u)")
        }
    }

    /// *Reading the parked floor.* A DDC read of the floor with no software dim means the
    /// switchover, not zero. Kills: treating a raw DDC percent as the combined value.
    func testFloorReadWithNoSoftwareDimMapsToSwitchover() {
        let value = CombinedBrightness.combined(
            hardware: CombinedBrightness.defaultHardwareFloor, software: 100.0
        )
        XCTAssertEqual(value, CombinedBrightness.switchover, accuracy: accuracy)
    }

    // MARK: - Stepping

    /// *Sixteen presses, on the grid.* The range takes 16 presses and every press lands on
    /// a 1/16 boundary so the HUD segments line up. Kills: changing stepsPerRange, or
    /// dropping the grid snap that keeps drags from desynchronising the ladder.
    func testSteppingIsSixteenPressesOnTheGrid() {
        var value = 0.0
        var presses = 0
        while value < 100.0, presses < 100 {
            value = CombinedBrightness.stepped(from: value, up: true)
            presses += 1
            let segment = value / (100.0 / CombinedBrightness.stepsPerRange)
            XCTAssertEqual(segment, segment.rounded(), accuracy: accuracy, "off-grid at \(value)")
        }
        XCTAssertEqual(presses, 16)
        XCTAssertEqual(value, 100.0, accuracy: accuracy)
    }

    /// *Snap from a drag.* A value between segments snaps to the nearest one, then moves.
    /// Kills: naive addition, which would keep an off-grid value off-grid forever.
    func testSteppingSnapsAnOffGridValue() {
        // 7.63 is the real persisted value that exposed the original bug.
        XCTAssertEqual(CombinedBrightness.stepped(from: 7.63, up: true), 12.5, accuracy: accuracy)
        XCTAssertEqual(CombinedBrightness.stepped(from: 7.63, up: false), 0.0, accuracy: accuracy)
    }

    /// *Bounds.* Stepping never escapes 0...100 and the ends are fixed points.
    /// Kills: dropping the final clamp.
    func testSteppingStaysInRange() {
        XCTAssertEqual(CombinedBrightness.stepped(from: 100.0, up: true), 100.0, accuracy: accuracy)
        XCTAssertEqual(CombinedBrightness.stepped(from: 0.0, up: false), 0.0, accuracy: accuracy)
        for u in stride(from: -20.0, through: 120.0, by: 3.0) {
            for up in [true, false] {
                let next = CombinedBrightness.stepped(from: u, up: up)
                XCTAssertGreaterThanOrEqual(next, 0.0)
                XCTAssertLessThanOrEqual(next, 100.0)
            }
        }
    }

    /// *No blinding jump in the backlight region.* Above the switchover, one press must not
    /// more than double the backlight once it is off the floor. Kills: a switchover so low
    /// that the backlight region is stepped too coarsely — the original complaint.
    func testNoPressMoreThanDoublesBacklightOnceLit() {
        var value = CombinedBrightness.switchover
        while value < 100.0 {
            let next = CombinedBrightness.stepped(from: value, up: true)
            let before = CombinedBrightness.split(combined: value).hardware
            let after = CombinedBrightness.split(combined: next).hardware
            if before >= 12.5 {
                XCTAssertLessThanOrEqual(after / before, 2.0,
                                         "press at \(value) took backlight \(before) -> \(after)")
            }
            value = next
        }
    }
}
