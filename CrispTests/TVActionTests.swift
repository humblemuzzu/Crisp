import XCTest

/// Headless tests for what automation may ask a television to do.
///
/// The property this file exists for is the same one `AutomationRequestTests`
/// pins for VCP codes, one identifier space over: **no automation origin can turn
/// a TV off or switch its input on its own.** It is asserted over the whole TV
/// registry and over every origin, rather than trusted at the three entry points
/// (`crisp://`, App Intents, the panel).
///
/// Each test names the mutation it is designed to kill.
final class TVActionTests: XCTestCase {

    private let lg = TVDeviceID("uuid:lg")
    private let samsung = TVDeviceID("uuid:samsung")
    private var known: [TVDeviceID: TVPlatform] { [lg: .webOS, samsung: .tizen] }

    private func request(
        _ origin: AutomationOrigin = .url,
        _ device: TVDeviceID? = nil,
        _ feature: TVFeatureID,
        _ value: TVActionValue
    ) -> TVActionRequest {
        TVActionRequest(origin: origin, device: device ?? lg, feature: feature, value: value)
    }

    // MARK: - The destructive rule, over everything

    /// **The property.** For every origin and every destructive feature, the plan
    /// is `needsConfirmation`. There is no parameter that changes it because
    /// `TVActionRequest` has no way to express "trusted".
    /// Kills mutation: adding an origin special case, or flipping `destructive`
    /// on power or input — either of which would let a link a web page opened
    /// turn a television off with no dialog.
    func testNoOriginCanPerformADestructiveTVActionOnItsOwn() {
        let destructive = TVFeatureRegistry.all.filter(\.destructive)
        XCTAssertFalse(destructive.isEmpty, "the property is vacuous if nothing is destructive")

        for origin in AutomationOrigin.allCases {
            for spec in destructive {
                let value: TVActionValue = spec.kind == .flag ? .flag(false) : .code("HDMI_1")
                let plan = request(origin, lg, spec.id, value).plan(known: known)
                guard case .needsConfirmation(_, let hazard) = plan else {
                    return XCTFail("\(origin) + \(spec.id) planned \(plan), not a confirmation")
                }
                XCTAssertFalse(hazard.isEmpty, "\(spec.id) must say what is at stake")
            }
        }
    }

    /// The harmless features really do go straight through, or the test above
    /// would pass with the whole feature disabled.
    /// Kills mutation: making everything need confirmation, which trains the user
    /// to click through the dialog that matters.
    func testNonDestructiveActionsAreReadyWithoutADialog() {
        for spec in TVFeatureRegistry.all where !spec.destructive {
            let value: TVActionValue
            switch spec.kind {
            case .percent: value = .percent(40)
            case .flag: value = .flag(true)
            case .code: value = .code("HDMI_1")
            }
            let plan = request(.url, lg, spec.id, value).plan(known: known)
            guard case .ready = plan else {
                return XCTFail("\(spec.id) planned \(plan), not ready")
            }
        }
    }

    // MARK: - Unpaired devices

    /// A link naming a TV nobody paired does nothing, and it says so *before* any
    /// dialog is shown.
    /// Kills mutation: planning against an unknown device (there is nothing to
    /// talk to and guessing an address would put power-off commands on the LAN),
    /// or ordering the destructive check first — which would put a confirmation
    /// dialog on screen about a television that does not exist.
    func testAnUnpairedDeviceIsRejectedBeforeAnyConfirmation() {
        let plan = request(.url, TVDeviceID("uuid:nobody"), .power, .flag(false)).plan(known: known)
        guard case .rejected(let reason) = plan else {
            return XCTFail("an unpaired TV planned \(plan)")
        }
        XCTAssertTrue(reason.contains("uuid:nobody"))
    }

    // MARK: - Platform capability

    /// Asking a Samsung for brightness is refused with the reason, not accepted
    /// and dropped.
    /// Kills mutation: planning it `ready` and letting the service no-op, which
    /// is the silent failure this whole feature is written to avoid.
    func testTizenBrightnessIsRejectedWithTheReason() {
        let plan = request(.appIntent, samsung, .brightness, .percent(50)).plan(known: known)
        guard case .rejected(let reason) = plan else {
            return XCTFail("Tizen brightness planned \(plan)")
        }
        XCTAssertEqual(reason, TVUnsupportedReason.tizenHasNoRemoteBrightness.text)
    }

    // MARK: - Value shapes

    /// A percentage is not a port and a port is not a percentage.
    /// Kills mutation: coercing between the shapes, which would aim an input
    /// switch at whatever identifier "40%" happened to land on.
    func testMismatchedValueShapesAreRejectedRatherThanCoerced() {
        for (feature, value) in [
            (TVFeatureID.volume, TVActionValue.code("HDMI_1")),
            (.volume, .flag(true)),
            (.input, .percent(40)),
            (.mute, .percent(40))
        ] as [(TVFeatureID, TVActionValue)] {
            guard case .rejected = request(.url, lg, feature, value).plan(known: known) else {
                return XCTFail("\(feature) accepted a \(value)")
            }
        }
    }

    /// A percentage is clamped, and a non-finite one is refused outright.
    /// Kills mutation: clamping without the `isFinite` check — `min(100, .nan)`
    /// is 100 in Swift, so a NaN would arrive as the loudest possible volume.
    func testPercentagesAreClampedAndNaNIsRefused() {
        guard case .ready(let write) = request(.url, lg, .volume, .percent(180)).plan(known: known) else {
            return XCTFail("a clampable percentage should plan ready")
        }
        XCTAssertEqual(write.value, .percent(100))

        guard case .rejected = request(.url, lg, .volume, .percent(.nan)).plan(known: known) else {
            return XCTFail("NaN must not become a volume")
        }
    }

    /// An input identifier is bounded and whitespace-free: it arrives from a URL
    /// any web page can open.
    /// Kills mutation: dropping the length or whitespace check, which would
    /// forward an unbounded blob into the frame builder.
    func testHostileInputIdentifiersAreRefused() {
        for code in ["", " ", "HDMI 1", String(repeating: "H", count: 500), "\n"] {
            let plan = request(.url, lg, .input, .code(code)).plan(known: known)
            guard case .rejected = plan else {
                return XCTFail("'\(code.prefix(10))' planned \(plan)")
            }
        }
    }

    // MARK: - The write gate

    /// The gate is the second, independent layer, and it uses the *same*
    /// authorization currency as the DDC gate.
    /// Kills mutation: accepting `.automatic` for a destructive TV action, which
    /// would let the coalescing pump or a future scheduled apply reach a power-off.
    func testTheGateRefusesADestructiveActionWithoutUserConfirmation() {
        let write = TVWrite(device: lg, platform: .webOS, feature: .power, value: .flag(false))
        let refused = TVWriteGate.approve(write, authorization: .automatic)
        XCTAssertFalse(refused.isApproved)
        XCTAssertTrue(refused.refusalReason?.contains("not confirmed") == true)

        let allowed = TVWriteGate.approve(write, authorization: .confirmed(by: TestConsent()))
        XCTAssertTrue(allowed.isApproved)
    }

    /// The gate refuses what the platform cannot do, whoever asked.
    /// Kills mutation: checking the platform only in `plan`, so a caller that
    /// built a `TVWrite` by hand could push Tizen brightness at the transport.
    func testTheGateRefusesWhatThePlatformCannotDoEvenWhenConfirmed() {
        let write = TVWrite(device: samsung, platform: .tizen, feature: .brightness, value: .percent(50))
        let approval = TVWriteGate.approve(write, authorization: .confirmed(by: TestConsent()))
        XCTAssertFalse(approval.isApproved)
        XCTAssertEqual(approval.refusalReason, TVUnsupportedReason.tizenHasNoRemoteBrightness.text)
    }

    /// The approved token carries the feature and value the *gate* decided on,
    /// not the ones the caller was holding.
    /// Kills mutation: a transport that reads the request instead of the token —
    /// the exact shape of the DDC bug `ApprovedWrite` was introduced to close.
    func testTheApprovedTokenCarriesWhatMayGoOnTheWire() {
        let write = TVWrite(device: lg, platform: .webOS, feature: .volume, value: .percent(30))
        guard case .approved(let approved) = TVWriteGate.approve(write, authorization: .automatic) else {
            return XCTFail("a non-destructive action should be approved")
        }
        XCTAssertEqual(approved.device, lg)
        XCTAssertEqual(approved.platform, .webOS)
        XCTAssertEqual(approved.feature, .volume)
        XCTAssertEqual(approved.value, .percent(30))
    }
}

/// The escape hatch AGENTS.md describes, used where it is meant to be used: a
/// headless test needs *some* way to hold a consent, and the protocol cannot stop
/// an in-module conformer from existing. It is loud rather than quiet — a type
/// declaration in a test file, visible in any diff — and it is deliberately not
/// in the app target, so nothing shipping can reach it.
private struct TestConsent: DestructiveWriteConsent {
    let consentSite = "a unit test stood in for the user"
}
