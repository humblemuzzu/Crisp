import XCTest

/// Headless tests for the automation surface's decision core.
///
/// `AutomationRequest`, `DDCFeatureRegistry` and `DisplayUUID` are compiled
/// straight into this target (see `project.yml`), so there is no
/// `@testable import Crisp` and no monitor, URL handler or Shortcuts runtime
/// involved. Each test names the mutation it is designed to kill.
///
/// The property the whole file exists for is `testNoOriginCanApplyADestructiveFeature`:
/// every destructive VCP code in the registry, from every automation origin,
/// with every value shape — never `.ready`.
final class AutomationRequestTests: XCTestCase {

    private let uuid = DisplayUUID("AEB55F97-FD93-4F8D-AD10-0942959D069C")
    private var attached: Set<DisplayUUID> { [uuid] }

    private func request(
        _ feature: DDCFeatureID,
        _ value: AutomationValue,
        origin: AutomationOrigin = .url,
        display: DisplayUUID? = nil
    ) -> AutomationRequest {
        AutomationRequest(origin: origin, display: display ?? uuid, feature: feature, value: value)
    }

    // MARK: - The destructive rule

    /// *The rule this file exists for.* No origin, no feature, no value shape
    /// produces `.ready` for anything `DDCFeatureRegistry` marks destructive.
    /// Kills mutation: "return `.ready` when the origin is `.appIntent`" (a
    /// shortcut is the surface most likely to be argued into an exception), and
    /// "check `destructive` before the value shape" reordering that lets a
    /// wrong-shaped destructive value through as ready.
    func testNoOriginCanApplyADestructiveFeature() {
        let values: [AutomationValue] = [.raw(17), .raw(0), .raw(65535), .percent(50), .percent(-5)]
        for spec in DDCFeatureRegistry.all where spec.destructive {
            for origin in AutomationOrigin.allCases {
                for value in values {
                    let plan = request(spec.id, value, origin: origin).plan(attached: attached)
                    if case .ready = plan {
                        XCTFail("\(spec.id.rawValue) from \(origin.rawValue) with \(value) was applied without asking")
                    }
                }
            }
        }
    }

    /// Input source is destructive *and* driven by the app, so it is the one that
    /// actually reaches the dialog rather than being rejected as unsupported.
    /// The hazard handed over is the registry's own sentence, not a generic one.
    /// Kills mutation: "drop the hazard and pass a fixed 'are you sure?' string",
    /// and "return `.rejected` for destructive features" (which would make the
    /// rule above pass vacuously).
    func testInputSourceNeedsConfirmationAndCarriesTheRegistryHazard() {
        guard case .needsConfirmation(let write, let hazard) =
            request(.input, .raw(17)).plan(attached: attached) else {
            return XCTFail("a destructive input write should need confirmation")
        }
        XCTAssertEqual(write.raw, 17)
        XCTAssertEqual(write.feature, .input)
        XCTAssertEqual(hazard, DDCFeatureID.input.spec.hazard)
    }

    /// A URL for a destructive feature aimed at a display that is not attached is
    /// refused outright — no dialog at all. A prompt about a monitor that is not
    /// there has only one correct answer, and showing it teaches the user to
    /// dismiss the dialog that matters.
    /// Kills mutation: "check the attached set after the destructive branch".
    func testAbsentDisplayIsRefusedBeforeTheConfirmation() {
        let plan = request(.input, .raw(17), display: DisplayUUID("not-attached")).plan(attached: attached)
        guard case .rejected(let reason) = plan else {
            return XCTFail("an absent display must not reach the confirmation")
        }
        XCTAssertTrue(reason.contains("not-attached"), reason)
    }

    /// The same for a harmless feature: nothing is applied to a display that is
    /// not connected, so a stale shortcut is a no-op and never a write aimed at
    /// whichever monitor happens to be there instead.
    /// Kills mutation: "ignore `attached` and let the service sort it out".
    func testAbsentDisplayIsANoOpForNonDestructiveFeatures() {
        let plan = request(.brightness, .percent(50), display: DisplayUUID("gone")).plan(attached: attached)
        guard case .rejected = plan else { return XCTFail("an absent display must not produce a write") }
    }

    /// An empty attached set is the ordinary "laptop on the train" case, not an
    /// edge case: every request is a no-op.
    /// Kills mutation: "treat an empty set as 'unknown, allow it'".
    func testNothingAttachedRefusesEverything() {
        for feature in DDCFeatureRegistry.established {
            let value: AutomationValue = feature.spec.kind.isContinuous ? .percent(50) : .raw(17)
            guard case .rejected = request(feature, value).plan(attached: []) else {
                return XCTFail("\(feature.rawValue) was planned with no displays attached")
            }
        }
    }

    // MARK: - Clamping

    /// Out-of-range percentages clamp rather than trap or wrap.
    /// Kills mutation: "reject anything outside 0...100" (a link that asks for
    /// 150 means 'as bright as possible', and refusing is worse than clamping),
    /// and "clamp with `%` or a truncating conversion" (which would wrap 150 to
    /// 50 and -10 to 246).
    func testPercentagesClampToTheEnds() {
        let cases: [(Double, Double)] = [(150, 100), (-10, 0), (0, 0), (100, 100), (49.5, 49.5)]
        for (asked, expected) in cases {
            guard case .ready(let write) = request(.brightness, .percent(asked)).plan(attached: attached) else {
                return XCTFail("brightness \(asked) should plan")
            }
            XCTAssertEqual(write.percent, expected, "brightness \(asked)")
        }
    }

    /// NaN and infinity are refused, not clamped. `min(100, .nan)` is 100 in
    /// Swift, so a NaN that reached the clamp would arrive as *full brightness* —
    /// the opposite of a safe default.
    /// Kills mutation: "drop the isFinite guard" (nan and inf then both become
    /// 100, and -inf becomes 0).
    func testNonFiniteValuesAreRefusedRatherThanClamped() {
        for value in [Double.nan, .infinity, -.infinity] {
            guard case .rejected = request(.brightness, .percent(value)).plan(attached: attached) else {
                return XCTFail("\(value) should not plan as a brightness")
            }
        }
    }

    // MARK: - Value shapes

    /// A percentage aimed at a code-shaped feature is refused, never scaled. VCP
    /// 0x60's `19` is a port, not 19% of anything, and scaling it would aim the
    /// write at whatever port that percentage landed on.
    /// Kills mutation: "convert a percent to a raw by scaling against the max".
    func testAPercentageIsNeverScaledIntoAnInputCode() {
        guard case .rejected(let reason) = request(.input, .percent(50)).plan(attached: attached) else {
            return XCTFail("a percentage must not become an input code")
        }
        XCTAssertTrue(reason.contains("0x60"), reason)
    }

    /// And the reverse: a raw code aimed at a percent-shaped feature.
    /// Kills mutation: "accept a raw value for a continuous feature and pass it
    /// through as a percentage".
    func testARawCodeIsRefusedForAPercentShapedFeature() {
        guard case .rejected = request(.brightness, .raw(50)).plan(attached: attached) else {
            return XCTFail("a raw code must not be taken as a brightness percentage")
        }
    }

    // MARK: - What automation is offered at all

    /// Only the four features the app drives end to end are automatable. The
    /// registry knows about a dozen more, and a percentage for one of those has
    /// no resolved raw range to be scaled into.
    /// Kills mutation: "allow every registry feature", which would offer a
    /// sharpness slider's worth of writes with nothing to show what they did.
    func testOnlyEstablishedFeaturesAreAutomatable() {
        for spec in DDCFeatureRegistry.all where !DDCFeatureRegistry.established.contains(spec.id) {
            let value: AutomationValue = spec.kind.isContinuous ? .percent(50) : .raw(1)
            guard case .rejected = request(spec.id, value).plan(attached: attached) else {
                return XCTFail("\(spec.id.rawValue) is not driven by the app and must not be automatable")
            }
        }
    }

    /// A read-only code is refused for the MCCS reason, before anything else has
    /// an opinion.
    /// Kills mutation: "drop the access check" — VCP 0xDF would then be planned
    /// and refused only at the DDC gate, one layer too late to explain itself.
    func testReadOnlyFeaturesAreRefusedByAccess() {
        guard case .rejected(let reason) = request(.vcpVersion, .raw(1)).plan(attached: attached) else {
            return XCTFail("a read-only code must not plan")
        }
        XCTAssertTrue(reason.contains("read-only"), reason)
    }

    // MARK: - The happy path

    /// The three non-destructive established features plan straight through, for
    /// every origin, with the value they were given.
    /// Kills mutation: "require confirmation for everything" — a rule nobody
    /// would keep, and the reason the destructive test above would otherwise pass
    /// for the wrong reason.
    func testNonDestructiveEstablishedFeaturesApplyDirectly() {
        for feature in [DDCFeatureID.brightness, .contrast, .volume] {
            for origin in AutomationOrigin.allCases {
                guard case .ready(let write) =
                    request(feature, .percent(42), origin: origin).plan(attached: attached) else {
                    return XCTFail("\(feature.rawValue) from \(origin.rawValue) should apply directly")
                }
                XCTAssertEqual(write.percent, 42)
                XCTAssertEqual(write.display, uuid)
            }
        }
    }

    /// `percent` and `raw` are shape-checked accessors, so a caller cannot read a
    /// port number as a percentage by accident.
    /// Kills mutation: "make `percent` return the raw value cast to Double".
    func testWriteAccessorsDoNotCrossValueShapes() {
        let percentWrite = AutomationWrite(display: uuid, feature: .brightness, value: .percent(30))
        XCTAssertEqual(percentWrite.percent, 30)
        XCTAssertNil(percentWrite.raw)

        let rawWrite = AutomationWrite(display: uuid, feature: .input, value: .raw(19))
        XCTAssertEqual(rawWrite.raw, 19)
        XCTAssertNil(rawWrite.percent)
    }
}
