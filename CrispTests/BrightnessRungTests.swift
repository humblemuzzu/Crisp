import XCTest

/// Headless tests for the brightness fallback ladder's decision core.
///
/// `BrightnessRung` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DDCServiceMatcher`), so no `@testable import Crisp` is
/// needed: the resolver is Foundation-only by construction, and the AppKit overlay
/// window it decides about lives in a separate file. Each test names the mutation
/// it is designed to kill in a trailing comment.
final class BrightnessRungTests: XCTestCase {

    // MARK: - Rung 1: hardware

    /// *Proven DDC.* A monitor whose writes land is on the top rung, no reason attached.
    /// Kills: a resolver that reports a working monitor as software-dimmed.
    func testProvenDDCResolvesToHardware() {
        let rung = BrightnessRung.resolve(.init(ddcAvailable: true))
        XCTAssertEqual(rung, .ddcHardware)
        XCTAssertNil(rung.reason)
        XCTAssertTrue(rung.isControllable)
    }

    /// *Unproven DDC (nil).* Nothing has been written yet, so the write path still
    /// aims at DDC and the badge must say what is actually being attempted.
    /// Kills mutation: treating `nil` as "no DDC" and pre-emptively reporting gamma
    /// (every freshly-connected monitor would show a degraded badge for a beat).
    func testUnprovenDDCResolvesToHardwareNotGamma() {
        XCTAssertEqual(BrightnessRung.resolve(.init(ddcAvailable: nil)), .ddcHardware)
    }

    /// *Built-in panel.* Driven through IOKit, which has nothing to do with the DDC
    /// availability map; a stale `false` there must not demote the internal display.
    /// Kills mutation M1: "drop the isBuiltin branch" → this flips to `.gammaTable`.
    func testBuiltinIsHardwareEvenWhenDDCIsMarkedUnavailable() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(isBuiltin: true, ddcAvailable: false)),
            .ddcHardware
        )
    }

    // MARK: - Rung 2: gamma table

    /// *DDC writes have failed.* MST hub, DisplayLink dock, DDC/CI off in the OSD:
    /// the display drops exactly one rung, and the reason names the missing channel.
    /// Kills mutation: returning `.gammaTable` with the wrong reason, or skipping
    /// straight past gamma to the overlay on a display that accepts gamma.
    func testFailedDDCFallsToGammaWithNoChannelReason() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(ddcAvailable: false)),
            .gammaTable(reason: .noDDCChannel)
        )
    }

    /// *HDR mode.* A DisplayHDR monitor acks DDC brightness and then ignores it, so
    /// even a proven-DDC display dims in software while HDR is engaged.
    /// Kills mutation M2: "drop the hdrSoftwareDimmed check" → this flips to
    /// `.ddcHardware`, i.e. the badge claims a backlight that is not moving.
    func testHDRModeDemotesEvenAProvenDDCDisplay() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(ddcAvailable: true, hdrSoftwareDimmed: true)),
            .gammaTable(reason: .hdrIgnoresDDC)
        )
    }

    /// Both true: no DDC channel at all is the more fundamental fact than "and it is
    /// also in HDR mode", so that is the explanation the user gets.
    /// Kills mutation: swapping the reason precedence → `.hdrIgnoresDDC`, which would
    /// tell a DisplayLink user to turn HDR off to fix a dock that has no I2C at all.
    func testNoChannelBeatsHDRAsTheStatedReason() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(ddcAvailable: false, hdrSoftwareDimmed: true)),
            .gammaTable(reason: .noDDCChannel)
        )
    }

    // MARK: - Rung 3: overlay

    /// *Virtual / AirPlay / Sidecar.* Gamma is written successfully and dims nothing
    /// the viewer sees, so these skip rung 2 entirely.
    /// Kills mutation M3: "check isVirtual after the DDC branch" → with a stale
    /// `ddcAvailable: true` this would resolve to `.ddcHardware`; and "let virtual
    /// displays use gamma" → `.gammaTable`.
    func testVirtualDisplayGoesToOverlayBeforeAnyDDCConsideration() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(isVirtual: true, ddcAvailable: true)),
            .overlay(reason: .virtualDisplay)
        )
    }

    /// *Gamma rejected.* The display refused `CGSetDisplayTransferByTable`, so the
    /// ladder drops one further and says so — the reason is the rejection, not the
    /// missing DDC channel that got us to rung 2 in the first place.
    /// Kills mutation M4: "drop the gammaWritable check" → `.gammaTable`, i.e. a
    /// slider that writes a table the display throws away.
    func testGammaRejectionFallsThroughToOverlay() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(ddcAvailable: false, gammaWritable: false)),
            .overlay(reason: .gammaRejected)
        )
    }

    // MARK: - Rung 4: unavailable

    /// *Offline.* Checked before everything else: a display that is gone is not a
    /// built-in panel with a working backlight, whatever the other flags still say.
    /// Kills mutation M5: "test isOnline last (or not at all)" → `.ddcHardware`.
    func testOfflineDisplayIsUnavailableRegardlessOfEveryOtherCapability() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(isOnline: false, isBuiltin: true, ddcAvailable: true)),
            .unavailable(reason: .displayOffline)
        )
    }

    /// *Nothing left.* No DDC, no gamma, and no `NSScreen` to hang an overlay window
    /// on. This is the case the ladder exists to admit to rather than fake.
    /// Kills mutation M6: "assume an overlay is always possible" → `.overlay`, which
    /// would leave a control that moves and a screen that does not.
    func testNoScreenMakesTheBottomRungUnavailable() {
        let rung = BrightnessRung.resolve(
            .init(ddcAvailable: false, gammaWritable: false, hasScreen: false)
        )
        XCTAssertEqual(rung, .unavailable(reason: .notDrawable))
        XCTAssertFalse(rung.isControllable, "the UI disables the slider off isControllable")
    }

    /// A virtual display that AppKit has no screen for: same bottom, reached through
    /// the other branch (allowGamma == false).
    /// Kills mutation: an overlay-or-unavailable helper that only guards `hasScreen`
    /// on the gamma-rejected path.
    func testVirtualDisplayWithoutAScreenIsUnavailable() {
        XCTAssertEqual(
            BrightnessRung.resolve(.init(isVirtual: true, hasScreen: false)),
            .unavailable(reason: .notDrawable)
        )
    }

    /// `isControllable` is the single fact the view disables the slider on, and only
    /// `.unavailable` may turn it off.
    /// Kills mutation: `isControllable` returning false for the degraded-but-working
    /// rungs, which would disable the slider on every DisplayLink dock.
    func testOnlyUnavailableDisablesTheControl() {
        XCTAssertTrue(BrightnessRung.ddcHardware.isControllable)
        XCTAssertTrue(BrightnessRung.gammaTable(reason: .noDDCChannel).isControllable)
        XCTAssertTrue(BrightnessRung.overlay(reason: .virtualDisplay).isControllable)
        XCTAssertFalse(BrightnessRung.unavailable(reason: .displayOffline).isControllable)
    }

    // MARK: - Reasons are user-presentable

    /// Every reason carries prose a user can act on: a sentence, not an enum name.
    /// Kills mutation: a `text` that returns "" or `String(describing: self)` — the
    /// tooltip is the only place a degraded rung explains itself.
    func testEveryReasonHasUserPresentableProse() {
        let reasons: [BrightnessRung.Reason] = [
            .noDDCChannel, .hdrIgnoresDDC, .virtualDisplay,
            .gammaRejected, .notDrawable, .displayOffline
        ]
        for reason in reasons {
            let text = reason.text
            XCTAssertGreaterThan(text.count, 20, "\(reason) needs a real explanation")
            XCTAssertTrue(text.hasSuffix("."), "\(reason) should read as a sentence")
            XCTAssertTrue(text.contains(" "), "\(reason) must not be a debug token")
        }
    }

    // MARK: - Overlay dim maths

    /// Full brightness paints nothing; the alpha is the inverse of the percentage.
    /// Kills mutation: using the percentage directly (100% would go black).
    func testOverlayAlphaIsTheInverseOfBrightness() {
        XCTAssertEqual(BrightnessOverlay.alpha(forBrightnessPercent: 100), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BrightnessOverlay.alpha(forBrightnessPercent: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(BrightnessOverlay.alpha(forBrightnessPercent: 20), 0.8, accuracy: 0.0001)
    }

    /// The safety cap: 0% must still leave the screen readable, because the overlay
    /// is the only dimmer on displays that reach this rung — a fully black screen
    /// hides the slider needed to undo it.
    /// Kills mutation M7: "drop the min(maxAlpha, ...) cap" → 1.0, an unrecoverable
    /// black screen.
    func testOverlayNeverFullyBlacksOutAScreen() {
        XCTAssertEqual(BrightnessOverlay.alpha(forBrightnessPercent: 0), 0.85, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(BrightnessOverlay.maxAlpha, 0.85)
    }

    /// Out-of-range input (a boost-region value, a negative from a bad caller) is
    /// clamped rather than producing a negative or >cap alpha.
    /// Kills mutation: dropping the input clamp → 160% yields alpha -0.6, which
    /// AppKit treats as 0 on some paths and garbage on others.
    func testOverlayAlphaClampsOutOfRangeBrightness() {
        XCTAssertEqual(BrightnessOverlay.alpha(forBrightnessPercent: 160), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BrightnessOverlay.alpha(forBrightnessPercent: -20), 0.85, accuracy: 0.0001)
    }
}
