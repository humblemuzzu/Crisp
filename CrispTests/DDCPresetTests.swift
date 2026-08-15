import XCTest

/// Headless tests for DDC presets: what one may contain, and what applying one
/// means.
///
/// The load-bearing test here is `testAPresetCannotCarryADestructiveFeature`,
/// which is asserted over the whole registry rather than against a hand-written
/// list. `DDCPreset`'s header sets out the argument for excluding input source;
/// this is the part that keeps it true when someone adds a VCP code next year.
///
/// Each test names the mutation it is designed to kill in a trailing comment.
final class DDCPresetTests: XCTestCase {

    private let displayA = DisplayUUID("AAAA-0001")
    private let displayB = DisplayUUID("BBBB-0002")

    private func preset(
        _ settings: [DisplayUUID: DDCPresetSettings], name: String = "Night"
    ) -> DDCPreset {
        DDCPreset(id: "p", name: name, settings: settings)
    }

    // MARK: - The safety boundary

    /// **The property this feature's safety rests on.** Every feature a preset
    /// may carry has to be non-destructive, because applying a preset is a thing
    /// a schedule does at 22:00 on a Mac nobody is sitting at, and a destructive
    /// write needs a human who was shown the hazard. Checked against the registry
    /// so adding `.input` (or 0xD6, or 0xCA) to `DDCPresetPlan.features` fails
    /// here rather than shipping.
    /// Kills mutation: putting any destructive feature in `features`, or reading
    /// `destructive` from anywhere but the registry.
    func testAPresetCannotCarryADestructiveFeature() {
        for feature in DDCPresetPlan.features {
            XCTAssertFalse(
                feature.spec.destructive,
                "\(feature.rawValue) is destructive; a preset must not be able to carry it"
            )
            XCTAssertNil(feature.spec.hazard, "a non-destructive feature carries no hazard")
        }
        XCTAssertFalse(DDCPresetPlan.features.contains(.input))
    }

    /// Everything a preset carries is percent-shaped and writable, and is one of
    /// the features Crisp drives end to end. A non-continuous code would mean a
    /// percentage was being scaled into an enumeration — VCP 0x60's `19` is a
    /// port, not 19% of anything — and a feature with no control would apply a
    /// value nothing in the app can show.
    /// Kills mutation: adding a `nonContinuous` or read-only feature to
    /// `features`, or one outside `DDCFeatureRegistry.established`.
    func testEveryPresetFeatureIsPercentShapedWritableAndDriven() {
        for feature in DDCPresetPlan.features {
            XCTAssertTrue(feature.spec.kind.isContinuous, "\(feature.rawValue) is not percent-shaped")
            XCTAssertTrue(feature.spec.access.canWrite, "\(feature.rawValue) is read-only")
            XCTAssertTrue(feature.spec.isKnown)
            XCTAssertTrue(
                DDCFeatureRegistry.established.contains(feature),
                "\(feature.rawValue) has no control in the app"
            )
        }
    }

    /// The three fields and the three features are the same three things. A
    /// mismatch would be a settings field that silently never applies, or a
    /// feature the model cannot store.
    /// Kills mutation: adding a field to `DDCPresetSettings` without adding it to
    /// `features`, or the reverse.
    func testTheSettingsFieldsAndThePlannedFeaturesAgree() {
        var settings = DDCPresetSettings()
        for feature in DDCPresetPlan.features {
            settings.setValue(42, for: feature)
            XCTAssertEqual(settings.value(for: feature), 42, "\(feature.rawValue) has no field")
        }
        XCTAssertEqual(settings, DDCPresetSettings(brightness: 42, contrast: 42, volume: 42))

        // And nothing outside the list can be stored through the same door.
        settings.setValue(99, for: .input)
        XCTAssertEqual(settings, DDCPresetSettings(brightness: 42, contrast: 42, volume: 42))
        XCTAssertNil(DDCPresetSettings(brightness: 10).value(for: .input))
    }

    // MARK: - Planning

    /// A preset applies only to the displays that are attached. The rest is a
    /// no-op for those displays and not an error — a preset outlives the desk it
    /// was captured on, and a laptop is away from that desk most of the time.
    /// Kills mutation: dropping the `attached` filter (writes aimed at displays
    /// that are not there), or refusing the whole preset when one is missing.
    func testAPresetAppliesOnlyToAttachedDisplays() {
        let preset = preset([
            displayA: DDCPresetSettings(brightness: 20, contrast: 45),
            displayB: DDCPresetSettings(brightness: 80)
        ])

        let steps = DDCPresetPlan.steps(for: preset, attached: [displayA])

        XCTAssertEqual(steps.map(\.display), [displayA, displayA])
        XCTAssertEqual(steps.map(\.feature), [.brightness, .contrast])
        XCTAssertEqual(DDCPresetPlan.missingDisplays(for: preset, attached: [displayA]), [displayB])
    }

    /// Nothing attached is an empty plan, not a failure. Same rule, at the edge
    /// where it is most tempting to throw.
    /// Kills mutation: treating an empty plan as an error condition upstream.
    func testAPresetWithNothingAttachedPlansNothing() {
        let preset = preset([displayA: DDCPresetSettings(brightness: 20)])

        XCTAssertTrue(DDCPresetPlan.steps(for: preset, attached: []).isEmpty)
        XCTAssertEqual(DDCPresetPlan.missingDisplays(for: preset, attached: []), [displayA])
    }

    /// A `nil` field means "this preset does not touch it" and produces no step,
    /// while `0` is a value the user chose and does. Collapsing the two would
    /// make a brightness-only preset silently reset contrast to zero.
    /// Kills mutation: defaulting the optionals, or filtering steps on `> 0`.
    func testAnUnsetFieldIsSkippedButZeroIsApplied() {
        let steps = DDCPresetPlan.steps(
            for: preset([displayA: DDCPresetSettings(brightness: 0, volume: nil)]),
            attached: [displayA]
        )

        XCTAssertEqual(steps.map(\.feature), [.brightness])
        XCTAssertEqual(steps.map(\.percent), [0])
    }

    /// Values are clamped and non-numbers are dropped. A hand-edited file is the
    /// realistic source of both, and `min(100, .nan)` is 100 in Swift — a NaN
    /// that reached the clamp would arrive as full brightness.
    /// Kills mutation: clamping without the `isFinite` check, or omitting the
    /// clamp so an out-of-range percent reaches the raw-value scaling.
    func testValuesAreClampedAndNonNumbersDropped() {
        let steps = DDCPresetPlan.steps(
            for: preset([displayA: DDCPresetSettings(brightness: 140, contrast: -20, volume: .nan)]),
            attached: [displayA]
        )

        XCTAssertEqual(steps.map(\.feature), [.brightness, .contrast])
        XCTAssertEqual(steps.map(\.percent), [100, 0])
    }

    /// The plan is ordered by display and then by `features`, so applying a
    /// preset twice issues the same writes in the same order — which is what
    /// makes a run reproducible in a log and comparable in a test.
    /// Kills mutation: iterating the settings dictionary directly, whose order
    /// Swift deliberately varies between runs.
    func testStepsAreDeterministicallyOrdered() {
        let preset = preset([
            displayB: DDCPresetSettings(brightness: 30, contrast: 20, volume: 10),
            displayA: DDCPresetSettings(volume: 40)
        ])

        let steps = DDCPresetPlan.steps(for: preset, attached: [displayA, displayB])

        XCTAssertEqual(steps.map(\.display), [displayA, displayB, displayB, displayB])
        XCTAssertEqual(steps.map(\.feature), [.volume, .brightness, .contrast, .volume])
    }

    // MARK: - The model

    /// An entry that would apply nothing is dropped, and the count the UI shows
    /// counts what would actually happen rather than what is stored.
    /// Kills mutation: counting `settings.count` before normalising, which shows
    /// "3 displays" for a preset that touches one.
    func testNormalisingDropsEntriesThatWouldApplyNothing() {
        let preset = preset([
            displayA: DDCPresetSettings(brightness: 20),
            displayB: DDCPresetSettings()
        ])

        XCTAssertEqual(Array(preset.normalized().settings.keys), [displayA])
        XCTAssertEqual(preset.displayCount, 1)
        XCTAssertTrue(DDCPresetSettings().isEmpty)
        XCTAssertFalse(DDCPresetSettings(volume: 0).isEmpty)
    }
}
