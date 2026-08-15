import XCTest

/// Headless tests for the first-run guide's decision core.
///
/// `OnboardingPlan` is compiled directly into this test target (see `project.yml`
/// sources, same route as `BrightnessRung`, which it reads), so no
/// `@testable import Crisp` is needed — that would drag in AppKit and defeat the
/// headless purity these tests exist to keep. Each test names the mutation it is
/// designed to kill in a trailing comment.
final class OnboardingPlanTests: XCTestCase {

    // MARK: - Presenting at launch

    /// The whole point of the flag: a user who has been through the guide (or
    /// skipped it) is never shown it again on their own.
    /// Kills mutation: returning a constant, or inverting the flag.
    func testPresentsAtLaunchOnlyUntilCompleted() {
        XCTAssertTrue(OnboardingPlan.shouldPresentAtLaunch(hasCompletedOnboarding: false))
        XCTAssertFalse(OnboardingPlan.shouldPresentAtLaunch(hasCompletedOnboarding: true))
    }

    // MARK: - Which steps

    /// A fresh install with no Accessibility grant sees all four screens, in the
    /// one order they make sense in (what it does → the permission → what was
    /// found → where it lives).
    /// Kills mutation: reordering `canonicalOrder`, or dropping a step outright.
    func testFullFlowWhenKeysAreNotWorking() {
        XCTAssertEqual(
            OnboardingPlan.steps(keysAlreadyWorking: false),
            [.whatItDoes, .accessibility, .displays, .done]
        )
    }

    /// Accessibility already armed (a reinstall over an existing grant): the one
    /// screen that asks for something is dropped, the rest keep their order.
    /// Kills mutation: ignoring `keysAlreadyWorking`; dropping the wrong step.
    func testAccessibilityStepDroppedWhenKeysAlreadyWork() {
        XCTAssertEqual(
            OnboardingPlan.steps(keysAlreadyWorking: true),
            [.whatItDoes, .displays, .done]
        )
    }

    /// `keeping:` overrides the drop rule *in place*: the kept step stays at its
    /// canonical index (1), it is not appended to the end.
    /// Kills mutation: implementing `keeping` as `steps + [keeping]`, which would
    /// put the accessibility screen after "done".
    func testKeepingReinstatesADroppedStepAtItsCanonicalPosition() {
        XCTAssertEqual(
            OnboardingPlan.steps(keysAlreadyWorking: true, keeping: .accessibility),
            [.whatItDoes, .accessibility, .displays, .done]
        )
    }

    /// Keeping a step the filter would have kept anyway must not duplicate it.
    /// Kills mutation: unioning `keeping` into the result instead of filtering.
    func testKeepingAStepThatSurvivesAnywayDoesNotDuplicateIt() {
        XCTAssertEqual(
            OnboardingPlan.steps(keysAlreadyWorking: false, keeping: .accessibility),
            [.whatItDoes, .accessibility, .displays, .done]
        )
    }

    /// The detection screen is never dropped, even with nothing attached: it is
    /// where the "no external monitors" message lives.
    /// Kills mutation: gating `.displays` on anything at all.
    func testDisplaysStepIsAlwaysPresent() {
        XCTAssertTrue(OnboardingPlan.steps(keysAlreadyWorking: true).contains(.displays))
        XCTAssertTrue(OnboardingPlan.steps(keysAlreadyWorking: false).contains(.displays))
    }

    // MARK: - Per-display verdicts

    /// A healthy external monitor is the case the app exists for.
    /// Kills mutation: collapsing `.ddcHardware` into the software branch.
    func testExternalOnDDCHardwareIsHardwareVerdict() {
        let fact = OnboardingDisplayFact(name: "BenQ MA320U")
        XCTAssertEqual(OnboardingPlan.verdict(for: fact), .hardwareDDC)
    }

    /// `BrightnessRung.resolve` reports the built-in panel as `.ddcHardware` (its
    /// IOKit backlight really is hardware), so the built-in check must come first
    /// or a lidded MacBook with nothing plugged in reads as a working monitor.
    /// Kills mutation: switching on the rung before testing `isBuiltin`.
    func testBuiltInPanelIsNeverCountedAsADDCMonitor() {
        let fact = OnboardingDisplayFact(name: "Built-in Display", isBuiltin: true, rung: .ddcHardware)
        XCTAssertEqual(OnboardingPlan.verdict(for: fact), .builtIn)
    }

    /// Gamma-table dimming is a monitor with no DDC channel, and the reason the
    /// ladder recorded travels with it (the user is shown *why*, never a bare
    /// "unsupported").
    /// Kills mutation: dropping the reason, or substituting a different one.
    func testGammaFallbackIsSoftwareOnlyAndKeepsItsReason() {
        let fact = OnboardingDisplayFact(name: "Dock monitor", rung: .gammaTable(reason: .noDDCChannel))
        XCTAssertEqual(OnboardingPlan.verdict(for: fact), .softwareOnly(.noDDCChannel))
    }

    /// The overlay rung is the same story one step further down, and must not be
    /// reported as "no control": the slider does still dim the screen.
    /// Kills mutation: mapping `.overlay` to `.noControl`.
    func testOverlayFallbackIsAlsoSoftwareOnly() {
        let fact = OnboardingDisplayFact(name: "AirPlay screen", rung: .overlay(reason: .virtualDisplay))
        XCTAssertEqual(OnboardingPlan.verdict(for: fact), .softwareOnly(.virtualDisplay))
    }

    /// Nothing can dim it: say so, with the reason.
    /// Kills mutation: mapping `.unavailable` to `.softwareOnly`, which would
    /// promise a control that writes nowhere.
    func testUnavailableRungIsNoControl() {
        let fact = OnboardingDisplayFact(name: "Offline monitor", rung: .unavailable(reason: .displayOffline))
        XCTAssertEqual(OnboardingPlan.verdict(for: fact), .noControl(.displayOffline))
    }

    // MARK: - Survey

    /// Externals become rows in the order given; the built-in is counted, not
    /// listed.
    /// Kills mutation: listing the built-in as a row, sorting the rows, or
    /// counting the built-in as an external.
    func testSurveyListsExternalsInOrderAndOnlyCountsTheBuiltIn() {
        let survey = OnboardingPlan.survey([
            OnboardingDisplayFact(name: "Built-in Display", isBuiltin: true),
            OnboardingDisplayFact(name: "BenQ MA320U"),
            OnboardingDisplayFact(name: "Dell U2720Q", rung: .gammaTable(reason: .noDDCChannel))
        ])
        XCTAssertEqual(survey.rows.map(\.name), ["BenQ MA320U", "Dell U2720Q"])
        XCTAssertEqual(survey.builtInCount, 1)
        XCTAssertEqual(survey.externalCount, 2)
        XCTAssertTrue(survey.hasExternalDisplays)
    }

    /// The laptop user who installs Crisp before plugging in the dock: one
    /// built-in, no externals. The guide has to be able to tell this from "no
    /// displays at all", because the honest sentence names the built-in.
    /// Kills mutation: deriving `hasExternalDisplays` from the total display
    /// count instead of the external rows.
    func testOnlyBuiltInMeansNoExternalDisplays() {
        let survey = OnboardingPlan.survey([
            OnboardingDisplayFact(name: "Built-in Display", isBuiltin: true)
        ])
        XCTAssertFalse(survey.hasExternalDisplays)
        XCTAssertEqual(survey.externalCount, 0)
        XCTAssertEqual(survey.builtInCount, 1)
        XCTAssertTrue(survey.rows.isEmpty)
    }

    /// The headless / clamshell-free case: nothing attached at all.
    /// Kills mutation: a survey that crashes or fabricates a row on empty input.
    func testEmptySurveyHasNothing() {
        let survey = OnboardingPlan.survey([])
        XCTAssertFalse(survey.hasExternalDisplays)
        XCTAssertEqual(survey.builtInCount, 0)
        XCTAssertEqual(survey.hardwareCount, 0)
        XCTAssertFalse(survey.externalsAllLackDDC)
    }

    /// Only externals on the hardware rung count as working DDC.
    /// Kills mutation: counting every row, or counting built-ins.
    func testHardwareCountCountsOnlyExternalsOnDDC() {
        let survey = OnboardingPlan.survey([
            OnboardingDisplayFact(name: "Built-in Display", isBuiltin: true),
            OnboardingDisplayFact(name: "BenQ MA320U"),
            OnboardingDisplayFact(name: "Studio Display", rung: .gammaTable(reason: .noDDCChannel))
        ])
        XCTAssertEqual(survey.hardwareCount, 1)
        XCTAssertFalse(survey.externalsAllLackDDC)
    }

    /// "None of your monitors support DDC" must be true only when there is at
    /// least one monitor. With none attached the count comparison alone is
    /// vacuously true, which would show the wrong message on the empty screen.
    /// Kills mutation: dropping the `hasExternalDisplays` guard from
    /// `externalsAllLackDDC`.
    func testAllExternalsLackDDCIsFalseWhenThereAreNoExternals() {
        let degraded = OnboardingPlan.survey([
            OnboardingDisplayFact(name: "DisplayLink dock", rung: .gammaTable(reason: .noDDCChannel))
        ])
        XCTAssertTrue(degraded.externalsAllLackDDC)

        let builtInOnly = OnboardingPlan.survey([
            OnboardingDisplayFact(name: "Built-in Display", isBuiltin: true)
        ])
        XCTAssertFalse(builtInOnly.externalsAllLackDDC)
    }

    // MARK: - Flow

    /// A fresh flow starts on the first screen and knows it is not the last.
    /// Kills mutation: starting at a non-zero index; an off-by-one `isLast`.
    func testFlowStartsAtTheFirstStep() {
        let flow = OnboardingFlow(keysAlreadyWorking: false)
        XCTAssertEqual(flow.current, .whatItDoes)
        XCTAssertTrue(flow.isFirst)
        XCTAssertFalse(flow.isLast)
        XCTAssertEqual(flow.position, 1)
        XCTAssertEqual(flow.count, 4)
    }

    /// Next walks the plan and stops dead on the last screen: there is no page
    /// past "done" to fall into.
    /// Kills mutation: an unclamped `index += 1` (out-of-range `current`).
    func testAdvanceStopsAtTheLastStep() {
        var flow = OnboardingFlow(keysAlreadyWorking: false)
        for _ in 0..<10 { flow.advance() }
        XCTAssertEqual(flow.current, .done)
        XCTAssertTrue(flow.isLast)
        XCTAssertEqual(flow.position, 4)
    }

    /// Back walks the plan and stops on the first screen.
    /// Kills mutation: an unclamped `index -= 1` (negative index).
    func testBackStopsAtTheFirstStep() {
        var flow = OnboardingFlow(keysAlreadyWorking: false)
        flow.advance()
        XCTAssertEqual(flow.current, .accessibility)
        for _ in 0..<10 { flow.back() }
        XCTAssertEqual(flow.current, .whatItDoes)
        XCTAssertTrue(flow.isFirst)
    }

    /// The permission lands while the user is reading the screen that asked for
    /// it: the screen stays put (the status line turns green under them) and the
    /// plan still knows it is now the second of four.
    /// Kills mutation: re-planning without `keeping:`, which deletes the current
    /// screen and jumps the window a page mid-read.
    func testGrantingWhileOnTheAccessibilityStepKeepsTheUserThere() {
        var flow = OnboardingFlow(keysAlreadyWorking: false)
        flow.advance()
        XCTAssertEqual(flow.current, .accessibility)

        flow.replan(keysAlreadyWorking: true)
        XCTAssertEqual(flow.current, .accessibility)
        XCTAssertEqual(flow.position, 2)
        XCTAssertEqual(flow.count, 4)

        // The kept screen stays navigable in both directions: going back to a
        // now-green permission screen is informative, not a dead end.
        flow.advance()
        XCTAssertEqual(flow.current, .displays)
        flow.back()
        XCTAssertEqual(flow.current, .accessibility)
    }

    /// The permission lands while the user is on an earlier screen: the now
    /// pointless step is dropped, so Next goes straight to the detection screen.
    /// Kills mutation: a `replan` that keeps every step regardless.
    func testGrantingBeforeTheAccessibilityStepDropsIt() {
        var flow = OnboardingFlow(keysAlreadyWorking: false)
        XCTAssertEqual(flow.current, .whatItDoes)

        flow.replan(keysAlreadyWorking: true)
        XCTAssertEqual(flow.count, 3)
        flow.advance()
        XCTAssertEqual(flow.current, .displays)
    }

    /// A revoke mid-flow puts the screen back rather than leaving the guide
    /// claiming a permission that is gone.
    /// Kills mutation: a one-way `replan` that can only remove steps.
    func testRevokingMidFlowReinstatesTheAccessibilityStep() {
        var flow = OnboardingFlow(keysAlreadyWorking: true)
        XCTAssertEqual(flow.count, 3)

        flow.replan(keysAlreadyWorking: false)
        XCTAssertEqual(flow.count, 4)
        XCTAssertEqual(flow.current, .whatItDoes)
        flow.advance()
        XCTAssertEqual(flow.current, .accessibility)
    }

    /// A flow with no steps would be a window with nothing in it and no way out.
    /// Kills mutation: dropping the empty-plan guard in `init`, which makes
    /// `current` crash on an out-of-range index.
    func testEmptyPlanDegradesToTheClosingStep() {
        let flow = OnboardingFlow(steps: [])
        XCTAssertEqual(flow.current, .done)
        XCTAssertTrue(flow.isFirst)
        XCTAssertTrue(flow.isLast)
    }
}
