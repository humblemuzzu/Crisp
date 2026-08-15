import XCTest
import CoreGraphics

/// Headless tests for the feature-discovery rule and the write gate.
///
/// `DDCFeatureDiscovery` is compiled directly into this test target (see
/// `project.yml` sources, same route as `DDCServiceMatcher`), so no
/// `@testable import Crisp` is needed.
///
/// Two properties are worth more than the rest of this file put together, and
/// both are stated as tests rather than comments because both have cost people
/// working controls on real hardware:
///
///   1. The capabilities string may only **widen** what Crisp offers.
///   2. Nothing unproven is writable, and nothing destructive is written without
///      the user having asked.
///   3. Rule 2 holds for *every* write path, including the generic percent
///      adapter a slider goes through — which for one phase it did not. The last
///      section drives that path over `FakeDDCTransport` and asserts on the
///      frames, because "the gate returned refused" and "nothing reached the
///      monitor" are different claims and only the second one is the point.
///
/// Each test names the mutation it is designed to kill.
final class DDCFeatureDiscoveryTests: XCTestCase {

    private let brightness = DDCFeatureID.brightness.spec
    private let sharpness = DDCFeatureID.sharpness.spec
    private let input = DDCFeatureID.input.spec

    /// The tests' stand-in for one of the app's three confirmation sites.
    ///
    /// It exists because `DestructiveWriteConsent`'s escape hatch is deliberate
    /// and this is what it is for: the real conformers keep their initialisers
    /// `fileprivate` to `DDCFeatureViews.swift`, `AutomationService.swift` and
    /// `DDCFeatureService.swift`, none of which is in this headless target. What
    /// the suite can still pin is the shape of the rule — that a confirmed
    /// authorization exists only where something produced a consent, and that a
    /// caller with no consent has nothing to say but `.automatic`.
    private struct TestConsent: DestructiveWriteConsent {
        let consentSite = "a test stood in for a confirmation site"
    }

    private var confirmed: DDCFeatureDiscovery.Authorization { .confirmed(by: TestConsent()) }

    private func quirk(_ confidence: QuirkConfidence) -> QuirkFeature {
        QuirkFeature(range: QuirkRange(min: 0, max: 100), values: [], confidence: confidence, complete: false)
    }

    // MARK: - Capabilities may only widen

    /// *A capabilities string that omits a feature the monitor answers changes
    /// nothing.* The HP LP2480zx omits 0x10 and drives brightness perfectly well.
    /// This is the exact behaviour ddcui gets wrong when it greys a control out.
    /// Kills mutation: consulting `capabilitiesAdvertises` before the probe, or
    /// letting `false` mean "absent".
    func testCapabilitiesCannotNarrowWhatTheProbeProved() {
        let resolution = DDCFeatureDiscovery.resolve(
            brightness,
            evidence: .init(probeAnswered: true, capabilitiesAdvertises: false)
        )
        XCTAssertEqual(resolution.availability, .proven)
        XCTAssertEqual(resolution.source, .probe)
        XCTAssertTrue(resolution.writable)
    }

    /// *A capabilities string that omits a feature the database knows changes
    /// nothing either.* Narrowing has to be impossible from every tier above it,
    /// not just from the one below.
    /// Kills mutation: an early `guard capabilitiesAdvertises != false`.
    func testCapabilitiesCannotNarrowWhatTheDatabaseKnows() {
        let resolution = DDCFeatureDiscovery.resolve(
            brightness,
            evidence: .init(quirk: quirk(.verified), capabilitiesAdvertises: false)
        )
        XCTAssertEqual(resolution.availability, .proven)
        XCTAssertEqual(resolution.source, .database)
    }

    /// *A capabilities string can add a feature nothing else knew about.* This is
    /// the half the rule is *for*: the BenQ MA320U advertises 0x87 and Crisp has
    /// no sharpness control, so the string is how it would ever get one.
    /// Kills mutation: dropping the capabilities tier entirely.
    func testCapabilitiesWidenToUnprovenNeverToProven() {
        let resolution = DDCFeatureDiscovery.resolve(
            sharpness,
            evidence: .init(capabilitiesAdvertises: true)
        )
        XCTAssertEqual(resolution.availability, .unproven)
        XCTAssertEqual(resolution.source, .capabilities)
        XCTAssertFalse(resolution.writable, "a well-formed parse is not evidence of support")
    }

    /// *A well-formed parse is never promoted to proof.* The LG 27MD5KL
    /// advertises dozens of features of which three respond; a parser that
    /// treated the string as truth would offer thirty controls that do nothing.
    /// Kills mutation: `.proven` in the capabilities branch.
    func testAdvertisedButSilentFeatureStaysUnprovenAndReadOnly() {
        let resolution = DDCFeatureDiscovery.resolve(
            sharpness,
            evidence: .init(probeAnswered: false, capabilitiesAdvertises: true)
        )
        XCTAssertEqual(resolution.availability, .unproven)
        XCTAssertFalse(resolution.writable)
    }

    /// *"Never asked" and "asked and silent" are different answers.* Both end up
    /// absent, but they must not be reported as the same thing: one is a monitor
    /// that has no such control, the other is a display nothing has probed yet.
    /// Kills mutation: collapsing `probeAnswered` to a Bool.
    func testSilenceAndAbsenceOfAProbeAreDistinguished() {
        let silent = DDCFeatureDiscovery.resolve(sharpness, evidence: .init(probeAnswered: false))
        let unasked = DDCFeatureDiscovery.resolve(sharpness, evidence: .init())
        XCTAssertEqual(silent.availability, .absent)
        XCTAssertEqual(unasked.availability, .absent)
        XCTAssertEqual(silent.source, .probe)
        XCTAssertEqual(unasked.source, .standard)
        XCTAssertNotEqual(silent.reason, unasked.reason)
    }

    // MARK: - The ladder

    /// *The user outranks everything, in both directions.* Including a live
    /// probe: a user who switched a control off does not want it back because the
    /// monitor answered.
    /// Kills mutation: checking the user override after the probe.
    func testUserOverrideBeatsEveryOtherTier() {
        let off = DDCFeatureDiscovery.resolve(
            brightness,
            evidence: .init(userOverride: false, quirk: quirk(.verified), probeAnswered: true, capabilitiesAdvertises: true)
        )
        XCTAssertEqual(off.availability, .absent)
        XCTAssertEqual(off.source, .userOverride)

        let on = DDCFeatureDiscovery.resolve(
            sharpness,
            evidence: .init(userOverride: true, probeAnswered: false, capabilitiesAdvertises: false)
        )
        XCTAssertEqual(on.availability, .proven)
        XCTAssertEqual(on.source, .userOverride)
    }

    /// *A `verified` database row is proof on its own.* It means a human watched
    /// the change happen on the physical panel, which is the strongest evidence
    /// anything in this app has.
    /// Kills mutation: requiring a probe as well.
    func testVerifiedDatabaseRowIsProofWithoutAProbe() {
        let resolution = DDCFeatureDiscovery.resolve(brightness, evidence: .init(quirk: quirk(.verified)))
        XCTAssertEqual(resolution.availability, .proven)
        XCTAssertEqual(resolution.source, .database)
    }

    /// *A `reported` row offers the feature but does not prove it — and a live
    /// answer promotes it.* One stranger's claim is not proof; the monitor
    /// answering is, and the database must not hold a proven feature down.
    /// Kills mutation: returning `.unproven` for a reported row regardless of the
    /// probe, or treating `reported` as `verified`.
    func testReportedDatabaseRowIsPromotedByALiveAnswer() {
        let alone = DDCFeatureDiscovery.resolve(brightness, evidence: .init(quirk: quirk(.reported)))
        XCTAssertEqual(alone.availability, .unproven)
        XCTAssertEqual(alone.source, .database)
        XCTAssertFalse(alone.writable)

        let confirmed = DDCFeatureDiscovery.resolve(
            brightness, evidence: .init(quirk: quirk(.reported), probeAnswered: true)
        )
        XCTAssertEqual(confirmed.availability, .proven)
        XCTAssertEqual(confirmed.source, .probe, "the probe is what proved it, so the probe is what is credited")
    }

    // MARK: - Access

    /// *MCCS read-only means never writable, however well proven.*
    /// Kills mutation: deriving `writable` from availability alone.
    func testReadOnlyFeatureIsNeverWritable() {
        let resolution = DDCFeatureDiscovery.resolve(
            DDCFeatureID.vcpVersion.spec, evidence: .init(probeAnswered: true)
        )
        XCTAssertEqual(resolution.availability, .proven)
        XCTAssertFalse(resolution.writable)
    }

    // MARK: - The write gate

    private func proven(_ spec: DDCFeatureSpec) -> DDCFeatureDiscovery.Resolution {
        DDCFeatureDiscovery.resolve(spec, evidence: .init(probeAnswered: true))
    }

    /// *A destructive feature is refused unless the user asked for this write.*
    /// The confirmation gate already exists for input switching; this is the rule
    /// that makes every other destructive code use the same one instead of a
    /// second copy.
    /// Kills mutation: allowing `.automatic` for destructive features.
    func testDestructiveWriteIsRefusedWithoutUserConfirmation() {
        let refused = DDCFeatureDiscovery.authorize(input, resolution: proven(input), authorization: .automatic)
        XCTAssertFalse(refused.isAllowed)
        XCTAssertEqual(refused.refusalReason?.contains("0x60"), true)
        XCTAssertEqual(refused.refusalReason?.contains("screen goes blank"), true,
                       "the refusal carries the registry's hazard, so a log line says what was at stake")

        XCTAssertTrue(
            DDCFeatureDiscovery.authorize(input, resolution: proven(input), authorization: confirmed).isAllowed
        )
    }

    /// *Every destructive code in the registry is gated, not just input.* 0xD6
    /// value 5 powers the panel off, 0x04 wipes the monitor's settings, 0xCA can
    /// disable its buttons permanently (ddcutil #153).
    /// Kills mutation: special-casing 0x60 instead of reading `destructive`.
    func testEveryDestructiveFeatureIsGated() {
        for feature in DDCFeatureID.allCases where feature.spec.destructive {
            let spec = feature.spec
            guard spec.access.canWrite else { continue }
            let decision = DDCFeatureDiscovery.authorize(
                spec, resolution: proven(spec), authorization: .automatic
            )
            XCTAssertFalse(decision.isAllowed, "\(feature.rawValue) may not be written automatically")
        }
    }

    /// *Restore factory defaults is write-only, so nothing can ever prove it, so
    /// it is never written by accident.* Two independent rules have to fail for
    /// 0x04 to reach the bus, which is the correct number for a code with no undo.
    /// Kills mutation: treating write-only features as proven by default.
    func testRestoreFactoryDefaultsCannotBeReachedByProbeEvidenceAlone() {
        let spec = DDCFeatureID.restoreFactoryDefaults.spec
        let resolution = DDCFeatureDiscovery.resolve(spec, evidence: .init(capabilitiesAdvertises: true))
        XCTAssertEqual(resolution.availability, .unproven)
        XCTAssertFalse(
            DDCFeatureDiscovery.authorize(spec, resolution: resolution, authorization: confirmed).isAllowed,
            "confirmed or not, an unproven feature is not written"
        )
    }

    /// *An unproven feature is read-only even for a harmless control.* This is
    /// the default the whole registry ships with: a feature nothing has confirmed
    /// stays readable until a quirks entry or a live read says otherwise.
    /// Kills mutation: gating writes on `destructive` alone.
    func testUnprovenHarmlessFeatureIsStillReadOnly() {
        let resolution = DDCFeatureDiscovery.resolve(sharpness, evidence: .init(capabilitiesAdvertises: true))
        let decision = DDCFeatureDiscovery.authorize(
            sharpness, resolution: resolution, authorization: confirmed
        )
        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.refusalReason?.contains("0x87"), true)
    }

    /// *A proven, harmless feature writes without ceremony.* The gate must not
    /// have made the ordinary case impossible: this is the path brightness,
    /// contrast and volume take on every slider drag.
    /// Kills mutation: requiring confirmation for everything.
    func testProvenHarmlessFeatureWritesAutomatically() {
        for feature in [DDCFeatureID.brightness, .contrast, .volume] {
            let spec = feature.spec
            XCTAssertTrue(
                DDCFeatureDiscovery.authorize(spec, resolution: proven(spec), authorization: .automatic).isAllowed,
                "\(feature.rawValue) must still write on a slider drag"
            )
        }
    }

    /// *A read-only feature is refused before anything else is considered.*
    /// Kills mutation: dropping the access check from the gate.
    func testReadOnlyFeatureIsRefusedByTheGate() {
        let spec = DDCFeatureID.displayTechnologyType.spec
        let decision = DDCFeatureDiscovery.authorize(
            spec, resolution: proven(spec), authorization: confirmed
        )
        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.refusalReason?.contains("read-only"), true)
    }

    // MARK: - The percent adapter (frames on the wire, not decisions in the air)

    /// `DDCFeatureService`'s percent pump, in the shape the service performs it:
    /// approve, then hand the transport **the token's** code and value.
    ///
    /// The service itself cannot come in here — it is `@MainActor` and drags in
    /// AppKit, IOKit and the display manager — so the seam these tests use is the
    /// one the service uses: an approval on one side, `DDCProtocolEngine` over a
    /// scriptable monitor on the other. That is exactly enough, because the token
    /// is the only thing that carries a VCP code and a value across it: an
    /// adapter that skipped the gate would have nothing to pass to
    /// `writeWithRetry`, which is the property under test.
    @discardableResult
    private func drivePercentPump(
        _ feature: DDCFeatureID,
        raw: UInt16,
        authorization: DDCFeatureDiscovery.Authorization,
        transport: FakeDDCTransport,
        displayID: CGDirectDisplayID = 7
    ) -> DDCFeatureDiscovery.WriteApproval {
        let spec = feature.spec
        let approval = DDCFeatureDiscovery.approve(
            spec, value: raw, resolution: proven(spec), authorization: authorization
        )
        if case .approved(let write) = approval {
            let engine = DDCProtocolEngine(transport: transport, sleep: { _ in })
            _ = engine.writeWithRetry(displayID: displayID, command: write.vcp, value: write.value)
        }
        return approval
    }

    /// *A destructive feature driven through the percent adapter never reaches
    /// the monitor unconfirmed.* VCP 0x0C is continuous and destructive at once,
    /// so a colour-temperature slider written by copying `setContrast` is the
    /// realistic way a destructive write gets onto the bus. The assertion is on
    /// frames, not on a Bool: nothing was framed, nothing was sent, the monitor's
    /// value is untouched.
    /// Kills mutation: a percent write path that calls the transport directly, or
    /// one that gates on `kind` instead of on `destructive`.
    func testDestructivePercentFeatureNeverReachesTheTransportUnconfirmed() {
        let transport = FakeDDCTransport()
        transport.setValue(50, max: 100, displayID: 7, code: 0x0C)

        let approval = drivePercentPump(
            .colorTemperature, raw: 95, authorization: .automatic, transport: transport
        )

        XCTAssertFalse(approval.decision.isAllowed)
        XCTAssertEqual(approval.decision.refusalReason?.contains("0x0C"), true)
        XCTAssertEqual(approval.decision.refusalReason?.contains("colour temperature"), true,
                       "the refusal carries the registry's hazard, not a generic message")
        XCTAssertEqual(transport.writeCount, 0, "a destructive percent write must not be framed at all")
        XCTAssertTrue(transport.sentFrames.isEmpty)
        XCTAssertEqual(transport.value(displayID: 7, code: 0x0C), 50)
    }

    /// *…and does reach it once the user has confirmed.* The gate has to be a
    /// gate, not a wall: a confirmed colour-temperature write is allowed, and it
    /// writes the registry's code with the caller's value.
    /// Kills mutation: refusing destructive features outright, or writing a code
    /// or a value other than the approved one.
    func testDestructivePercentFeatureReachesTheTransportOnceConfirmed() {
        let transport = FakeDDCTransport()
        transport.setValue(50, max: 100, displayID: 7, code: 0x0C)

        let approval = drivePercentPump(
            .colorTemperature, raw: 95, authorization: confirmed, transport: transport
        )

        guard case .approved(let write) = approval else {
            return XCTFail("a confirmed write to a proven destructive feature must be approved")
        }
        XCTAssertEqual(write.vcp, 0x0C)
        XCTAssertEqual(write.value, 95)
        XCTAssertEqual(transport.writeCount, 1)
        XCTAssertEqual(transport.value(displayID: 7, code: 0x0C), 95)
    }

    /// *A harmless percent feature still writes with no ceremony at all.* This is
    /// the no-behaviour-change half: contrast is driven by the slider and by the
    /// reconnect reapply, both `.automatic`, and both must still put one frame on
    /// the wire carrying VCP 0x12.
    /// Kills mutation: gating every percent write on `.userConfirmed`.
    func testHarmlessPercentFeatureStillReachesTheTransportAutomatically() {
        let transport = FakeDDCTransport()
        transport.setValue(50, max: 100, displayID: 7, code: 0x12)

        drivePercentPump(.contrast, raw: 40, authorization: .automatic, transport: transport)

        XCTAssertEqual(transport.writeCount, 1)
        XCTAssertEqual(transport.frames(matchingOpcode: 0x84).first?.bytes[3], 0x12)
        XCTAssertEqual(transport.value(displayID: 7, code: 0x12), 40)
    }

    /// *An approval carries the registry's code, never the caller's idea of it,
    /// and never a value the caller did not ask for.* This is what makes "take
    /// the code off the token" a real safety property rather than a style: a
    /// write path cannot aim at a register the gate did not judge.
    /// Kills mutation: an `ApprovedWrite` built from anything but the spec.
    func testApprovedWriteCarriesTheRegistrysOwnCodeAndTheCallersValue() {
        for feature in DDCFeatureID.allCases {
            let spec = feature.spec
            guard case .approved(let write) = DDCFeatureDiscovery.approve(
                spec, value: 42, resolution: proven(spec), authorization: confirmed
            ) else { continue }
            XCTAssertEqual(write.feature, feature)
            XCTAssertEqual(write.vcp, spec.vcp)
            XCTAssertEqual(write.value, 42)
        }
    }

    // MARK: - Consent is a value, not a claim

    /// *A caller that did not confirm cannot produce an authorized destructive
    /// write — for any destructive code, at any resolution.* `.automatic` is the
    /// only `Authorization` such a caller can build: `.userConfirmed` carries a
    /// `UserConfirmation` whose initialiser is `fileprivate` to
    /// `DDCFeatureDiscovery.swift`, so the only route to one is
    /// `.confirmed(by:)` with a `DestructiveWriteConsent` in hand, and every
    /// conformer's own initialiser is `fileprivate` to the file that owns a
    /// confirmation.
    ///
    /// This is the property that used to rest on review discipline:
    /// `DDCFeatureService.setInputSource` hardcoded `.userConfirmed` for every
    /// caller it would ever have, so an automatic path added later — a preset
    /// apply, a scheduled reapply — would have compiled clean and reached VCP
    /// 0x60 unconfirmed.
    /// Kills mutation: a default `authorization:` argument, a gate that reads
    /// anything but the token, or making `userConfirmed` a bare case again.
    func testACallerThatDidNotConfirmCannotAuthorizeADestructiveWrite() {
        for feature in DDCFeatureID.allCases where feature.spec.destructive {
            let spec = feature.spec
            guard spec.access.canWrite else { continue }
            for resolution in [proven(spec), DDCFeatureDiscovery.resolve(spec, evidence: .init())] {
                let approval = DDCFeatureDiscovery.approve(
                    spec, value: 1, resolution: resolution, authorization: .automatic
                )
                guard case .refused = approval else {
                    return XCTFail(
                        "\(feature.rawValue) handed an ApprovedWrite to a caller that never confirmed"
                    )
                }
            }
        }
    }

    /// *…and nothing it asked for is framed.* VCP 0x60 is the sharp one: a write
    /// that reaches the monitor sends the panel to a port that may have nothing
    /// attached, and only the monitor's own buttons undo it. The assertion is on
    /// the transport, because "the gate refused" and "the bus stayed quiet" are
    /// different claims.
    /// Kills mutation: a write path that frames first and checks after.
    func testAnUnconfirmedInputSwitchIsNeverFramed() {
        let transport = FakeDDCTransport()
        transport.setValue(19, max: 19, displayID: 7, code: 0x60)

        let approval = DDCFeatureDiscovery.approve(
            input, value: 17, resolution: proven(input), authorization: .automatic
        )
        if case .approved(let write) = approval {
            let engine = DDCProtocolEngine(transport: transport, sleep: { _ in })
            _ = engine.writeWithRetry(displayID: 7, command: write.vcp, value: write.value)
        }

        XCTAssertFalse(approval.decision.isAllowed)
        XCTAssertEqual(transport.writeCount, 0)
        XCTAssertTrue(transport.sentFrames.isEmpty)
        XCTAssertEqual(
            transport.value(displayID: 7, code: 0x60), 19,
            "the monitor is still on the input the user left it on"
        )
    }

    /// *A confirmed authorization remembers which site vouched, and an automatic
    /// one has nothing to remember.* The token carries the site so a refusal, a
    /// log line or a diagnostics row can say which of the three confirmations
    /// this was — the gate itself treats them alike, and that is deliberate: the
    /// question it answers is whether a human decided, not who asked them.
    /// Kills mutation: collapsing the payload back to a bare case.
    func testAConfirmedAuthorizationCarriesTheSiteThatVouched() {
        let authorization = confirmed
        XCTAssertTrue(authorization.isUserConfirmed)
        XCTAssertEqual(authorization.confirmationSite, TestConsent().consentSite)

        let automatic = DDCFeatureDiscovery.Authorization.automatic
        XCTAssertFalse(automatic.isUserConfirmed)
        XCTAssertNil(automatic.confirmationSite)
    }

    /// *The two doors into the gate answer identically, for every feature and
    /// both authorizations.* `authorize` is what a view asks and `approve` is
    /// what a write path asks; the moment they can disagree, one of them is a
    /// second gate with its own bugs.
    /// Kills mutation: reimplementing the rule in either one.
    func testApproveAndAuthorizeCannotDisagree() {
        for feature in DDCFeatureID.allCases {
            let spec = feature.spec
            for authorization in [DDCFeatureDiscovery.Authorization.automatic, confirmed] {
                for resolution in [proven(spec), DDCFeatureDiscovery.resolve(spec, evidence: .init())] {
                    XCTAssertEqual(
                        DDCFeatureDiscovery.approve(
                            spec, value: 1, resolution: resolution, authorization: authorization
                        ).decision,
                        DDCFeatureDiscovery.authorize(
                            spec, resolution: resolution, authorization: authorization
                        ),
                        "\(feature.rawValue) is judged differently depending on which door was used"
                    )
                }
            }
        }
    }
}
