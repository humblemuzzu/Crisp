import XCTest

/// Headless tests for the diagnostics decision core: the per-feature support rule
/// and the markdown bug report.
///
/// `DisplayDiagnostics` is compiled directly into this test target (see
/// `project.yml` sources, same route as `MonitorQuirks` and `BrightnessRung`), so
/// no `@testable import Crisp` is needed — that would pull AppKit and the private
/// bridging header and defeat headless purity. Each test names the mutation it is
/// designed to kill.
///
/// Two properties matter more than the rest and get the most tests: **no negative
/// is ever bare** (a user reading "unsupported" with no reason is exactly the
/// experience this feature exists to replace), and **the report leaks nothing
/// identifying about the machine**.
final class DisplayDiagnosticsTests: XCTestCase {

    // MARK: - VCP codes

    /// The four MCCS codes the whole app is built on. Restated in the diagnostics
    /// model because it is headless and `DDCService` is not, so pin them.
    /// Kills mutation: swapping contrast (0x12) and input (0x60), or transcribing
    /// volume as 0x60 — either would make the report name the wrong register while
    /// still looking plausible.
    func testFeatureVCPCodesMatchMCCS() {
        XCTAssertEqual(QuirkFeatureName.brightness.vcpCode, 0x10)
        XCTAssertEqual(QuirkFeatureName.contrast.vcpCode, 0x12)
        XCTAssertEqual(QuirkFeatureName.volume.vcpCode, 0x62)
        XCTAssertEqual(QuirkFeatureName.input.vcpCode, 0x60)
        XCTAssertEqual(QuirkFeatureName.contrast.vcpText, "0x12", "two hex digits, the way MCCS writes them")
    }

    // MARK: - Support resolution

    /// A monitor that answered this run's probe is supported, whatever any cached
    /// flag says.
    /// Kills mutation: consulting only `appReportsSupported`, which would report a
    /// freshly-attached monitor as unknown until some other code path set the flag.
    func testLiveProbeAloneProvesSupport() {
        let support = FeatureDiagnostic.resolveSupport(
            .contrast, evidence: .init(appReportsSupported: false, probeAnswered: true)
        )
        XCTAssertEqual(support, .supported)
    }

    /// The app's own flag proves support too: `DisplayInfo.volumeSupported` is what
    /// gates the slider, and a report that disagrees with the visible UI is worse
    /// than no report. Flaky DDC makes a single probe miss routinely.
    /// Kills mutation: consulting only this run's probe, which would print
    /// "unknown" next to a slider the user is looking at.
    func testRememberedAppFlagAloneProvesSupport() {
        let support = FeatureDiagnostic.resolveSupport(
            .volume, evidence: .init(appReportsSupported: true, probeAnswered: false)
        )
        XCTAssertEqual(support, .supported)
    }

    /// No evidence either way, and DDC has not been ruled out: unknown, never "no".
    /// A monitor with no such control and a link that drops DDC replies are
    /// indistinguishable on the wire, so claiming either invents evidence.
    /// Kills mutation: collapsing `unknown` into `unsupported` (the single most
    /// tempting simplification in this file, and the one that produces the bare
    /// "unsupported" the feature exists to abolish).
    func testUnansweredProbeWithUnprovenDDCIsUnknownNotUnsupported() {
        let support = FeatureDiagnostic.resolveSupport(
            .contrast, evidence: .init(probeAnswered: false, ddcAvailable: nil)
        )
        guard case .unknown(let reason) = support else {
            return XCTFail("an unanswered probe on an unproven link must be unknown, got \(support)")
        }
        XCTAssertTrue(reason.contains("0x12"), "the reason must name the register that went unanswered")
    }

    /// Only a *proven-dead* DDC channel justifies "not supported": that is the one
    /// negative the app can actually demonstrate.
    /// Kills mutation: treating `ddcAvailable == nil` as false, which would report
    /// every display as unsupported for the first few seconds after it appears.
    func testProvenDeadDDCChannelIsTheOnlyUnsupportedVerdict() {
        let dead = FeatureDiagnostic.resolveSupport(
            .contrast, evidence: .init(probeAnswered: false, ddcAvailable: false)
        )
        guard case .unsupported = dead else {
            return XCTFail("a failed DDC channel must read as unsupported, got \(dead)")
        }
        let unproven = FeatureDiagnostic.resolveSupport(
            .contrast, evidence: .init(probeAnswered: false, ddcAvailable: nil)
        )
        guard case .unknown = unproven else {
            return XCTFail("an unproven channel must NOT read as unsupported, got \(unproven)")
        }
    }

    /// The built-in panel has no I²C bus, so contrast/volume/input are not
    /// applicable there — but its backlight is real, so brightness is supported.
    /// Kills mutation: reporting the built-in panel's contrast as "unsupported"
    /// (which sends a user hunting for a fault that does not exist), or letting the
    /// built-in branch swallow brightness too.
    func testBuiltinPanelSeparatesBrightnessFromTheDDCOnlyFeatures() {
        XCTAssertEqual(
            FeatureDiagnostic.resolveSupport(.brightness, evidence: .init(isBuiltinDisplay: true)),
            .supported
        )
        for feature in [QuirkFeatureName.contrast, .volume, .input] {
            let support = FeatureDiagnostic.resolveSupport(feature, evidence: .init(isBuiltinDisplay: true))
            guard case .notApplicable = support else {
                return XCTFail("\(feature.rawValue) on the built-in panel must be notApplicable, got \(support)")
            }
        }
    }

    /// The built-in branch runs before the DDC branch: a built-in panel whose DDC
    /// availability somehow reads false must still report brightness as supported,
    /// not fall through to "no DDC channel".
    /// Kills mutation: reordering `resolveSupport` so the ddcAvailable check comes
    /// first — the same ordering bug `BrightnessRung.resolve` guards against.
    func testBuiltinBranchOutranksDeadDDCChannel() {
        XCTAssertEqual(
            FeatureDiagnostic.resolveSupport(
                .brightness, evidence: .init(ddcAvailable: false, isBuiltinDisplay: true)
            ),
            .supported
        )
    }

    /// **The rule of the whole feature.** Every non-supported verdict, for every
    /// feature, over every combination of evidence, must carry prose a human can
    /// act on — and must not be the bare word.
    /// Kills mutation: any future branch that returns `.unsupported(reason: "")`
    /// or `.unknown(reason: "unknown")`.
    func testNoNegativeVerdictIsEverBare() {
        let evidences: [FeatureDiagnostic.Evidence] = [
            .init(),
            .init(ddcAvailable: false),
            .init(ddcAvailable: true),
            .init(isBuiltinDisplay: true),
            .init(ddcAvailable: false, isBuiltinDisplay: true)
        ]
        for feature in QuirkFeatureName.allCases {
            for evidence in evidences {
                let support = FeatureDiagnostic.resolveSupport(feature, evidence: evidence)
                switch support {
                case .supported:
                    continue
                case .unsupported(let reason), .unknown(let reason), .notApplicable(let reason):
                    XCTAssertGreaterThan(
                        reason.count, 30,
                        "\(feature.rawValue)/\(evidence) got a stub reason: \"\(reason)\""
                    )
                    XCTAssertTrue(
                        support.reportText.contains("—"),
                        "\(feature.rawValue)/\(evidence) rendered without its reason: \(support.reportText)"
                    )
                }
            }
        }
    }

    // MARK: - Quarantine rendering

    /// An active quarantine says so loudly, names the failure count, and says that
    /// writes still work — because "my monitor stopped responding" with a silent
    /// back-off behind it is precisely the undiagnosable failure this app is about.
    /// Kills mutation: rendering the quarantine as a bare boolean, or rounding the
    /// remaining time down to "0 minutes" while it is still active.
    func testActiveQuarantineRendersTheRemainingTimeAndTheReason() {
        let status = DDCStatusDiagnostic(
            availability: .available,
            consecutiveReadFailures: 6,
            quarantineRemaining: 61
        )
        XCTAssertTrue(status.isQuarantined)
        let text = status.quarantineReportText
        XCTAssertTrue(text.contains("ACTIVE"), text)
        XCTAssertTrue(text.contains("2 more minutes"), "61s must round up to 2 minutes, got: \(text)")
        XCTAssertTrue(text.contains("6 consecutive failures"), text)
        XCTAssertTrue(text.contains("writes are unaffected"), text)
    }

    /// No quarantine still reports the streak, so a marginal link that keeps
    /// resetting is visible before it trips the threshold.
    /// Kills mutation: printing "inactive" with no count, which hides the run-up.
    func testInactiveQuarantineStillReportsTheFailureStreak() {
        let status = DDCStatusDiagnostic(
            availability: .available, consecutiveReadFailures: 1, quarantineRemaining: nil
        )
        XCTAssertFalse(status.isQuarantined)
        XCTAssertEqual(status.quarantineReportText, "inactive (1 consecutive read failure)")
    }

    // MARK: - Report privacy

    /// **The privacy contract.** With the default privacy setting the report must
    /// contain neither the EDID serial nor the display UUID, and must say so.
    /// Kills mutation: rendering `identity.serial` / `identity.displayUUID`
    /// unconditionally, or dropping the note that explains the omission.
    func testDefaultReportOmitsPerUnitIdentifiers() {
        let markdown = DiagnosticReport.markdown(
            environment: environment, displays: [display()], privacy: .redacted
        )
        XCTAssertFalse(markdown.contains("16843009"), "EDID serial leaked:\n\(markdown)")
        XCTAssertFalse(markdown.contains("37D8832A-2D66-02CA"), "display UUID leaked:\n\(markdown)")
        XCTAssertTrue(markdown.contains(DiagnosticReport.redactedPlaceholder))
        XCTAssertTrue(markdown.contains("are omitted"), "the report must say what it withheld")
    }

    /// Opting in includes both, and swaps the note for one that says they are in
    /// there — a user who pastes this must know what they pasted.
    /// Kills mutation: wiring the toggle to only one of the two fields, or leaving
    /// the "omitted" wording in place when nothing was omitted.
    func testOptingInIncludesPerUnitIdentifiersAndSaysSo() {
        let markdown = DiagnosticReport.markdown(
            environment: environment, displays: [display()], privacy: .full
        )
        XCTAssertTrue(markdown.contains("16843009"), "opted-in report must carry the serial")
        XCTAssertTrue(markdown.contains("37D8832A-2D66-02CA-9A3B-D0E1A2B3C4D5"))
        XCTAssertFalse(markdown.contains(DiagnosticReport.redactedPlaceholder))
        XCTAssertTrue(markdown.contains("**are** included"))
    }

    /// No privacy setting may ever put a machine-identifying field in the report.
    /// The guarantee is structural — `DiagnosticEnvironment` has no field for a
    /// machine serial, user name or host name — and this pins it: a future field
    /// carrying one would have to be rendered, and rendering it would fail here.
    /// Kills mutation: adding `hostName` / `userName` / the machine serial to the
    /// environment and printing it.
    func testNoPrivacySettingEverLeaksMachineIdentity() {
        // Values planted in every free-text field a hostile refactor might route
        // an identifying value through.
        let hostile = DisplayDiagnostics(
            identity: DisplayIdentityDiagnostic(
                name: "BenQ MA320U",
                vendor: 0x09D1,
                product: 0x8075,
                serial: 16_843_009,
                displayUUID: "37D8832A-2D66-02CA-9A3B-D0E1A2B3C4D5",
                isBuiltin: false,
                isMain: true,
                resolution: "3840 × 2160",
                connection: nil
            ),
            rung: .ddcHardware,
            ddc: DDCStatusDiagnostic(
                availability: .available, consecutiveReadFailures: 0, quarantineRemaining: nil
            ),
            features: [],
            quirkMatch: nil,
            currentInput: nil,
            brightnessKeys: BrightnessKeyDiagnostic(
                interception: .armed, targetsThisDisplay: nil, targetDescription: "target: follow the pointer"
            )
        )
        for privacy in [DiagnosticReport.Privacy.redacted, .full] {
            let markdown = DiagnosticReport.markdown(
                environment: environment, displays: [hostile], privacy: privacy
            )
            for forbidden in ["C02XL0THJGH5", "muzammil", "Muzammils-MacBook-Pro.local"] {
                XCTAssertFalse(
                    markdown.lowercased().contains(forbidden.lowercased()),
                    "\(forbidden) reached the report at privacy \(privacy)"
                )
            }
        }
    }

    // MARK: - Report content

    /// A degraded rung must print *why* it degraded, not just which rung it is.
    /// Kills mutation: rendering the rung as a bare case name, which is the whole
    /// difference between this report and the one every other app produces.
    func testDegradedRungCarriesItsReasonIntoTheReport() {
        let degraded = display(rung: .gammaTable(reason: .noDDCChannel))
        let markdown = DiagnosticReport.markdown(
            environment: environment, displays: [degraded], privacy: .redacted
        )
        XCTAssertTrue(markdown.contains("GPU colour table"), markdown)
        XCTAssertTrue(
            markdown.contains(BrightnessRung.Reason.noDDCChannel.text),
            "the rung's own user-facing reason must appear verbatim, not a paraphrase"
        )
    }

    /// The feature table renders one row per feature, with the register, the raw
    /// probe, and where the range came from.
    /// Kills mutation: dropping the range source column, which is what separates
    /// "the database says 0–50" from "the monitor claimed 0–50".
    func testFeatureTableCarriesRegisterProbeAndRangeProvenance() {
        let markdown = DiagnosticReport.markdown(
            environment: environment, displays: [display()], privacy: .redacted
        )
        XCTAssertTrue(markdown.contains("| Volume | 0x62 | supported | 44 / 50 | 0–50 | quirks database (verified) |"),
                      markdown)
        XCTAssertTrue(markdown.contains("| Input source | 0x60 |"), markdown)
    }

    /// A contributed `notes` string is free text from a stranger, and a pipe in it
    /// scrambles every column to its right in a GitHub-rendered table — turning
    /// the one artefact a maintainer has to read into noise.
    /// Kills mutation: dropping the cell escaping, or escaping only the header.
    func testTableCellsEscapePipesAndNewlines() {
        let awkward = display(quirkNotes: "measured | on macOS 26\nsecond line")
        let markdown = DiagnosticReport.markdown(
            environment: environment, displays: [awkward], privacy: .redacted
        )
        XCTAssertTrue(markdown.contains("measured \\| on macOS 26 second line"), markdown)
        for line in markdown.split(separator: "\n") where line.hasPrefix("| Quirks notes") {
            // Count only the pipes markdown will treat as separators: the escaped
            // one is a literal character in the cell, which is the whole point.
            let separators = line.replacingOccurrences(of: "\\|", with: "").filter { $0 == "|" }.count
            XCTAssertEqual(separators, 3, "row gained a column: \(line)")
        }
    }

    /// A newline inside an EDID product name must not split the section heading,
    /// which would leave the rest of the name as body text and the table orphaned.
    /// Kills mutation: interpolating `identity.name` into the heading raw.
    func testDisplayHeadingSurvivesANewlineInTheMonitorName() {
        let awkward = display(name: "Weird Monitor\nSecond line")
        let markdown = DiagnosticReport.markdown(
            environment: environment, displays: [awkward], privacy: .redacted
        )
        XCTAssertTrue(markdown.contains("### Display 1 — Weird Monitor Second line"), markdown)
        XCTAssertEqual(markdown.split(separator: "\n").filter { $0.hasPrefix("### ") }.count, 1)
    }

    /// A report with no displays still renders the environment and says why it is
    /// short, instead of looking truncated.
    /// Kills mutation: early-returning an empty string when there are no displays.
    func testEmptyDisplayListStillProducesAUsableReport() {
        let markdown = DiagnosticReport.markdown(
            environment: environment, displays: [], privacy: .redacted
        )
        XCTAssertTrue(markdown.contains("## Crisp diagnostics"))
        XCTAssertTrue(markdown.contains("Mac16,8"))
        XCTAssertTrue(markdown.contains("No displays attached"))
    }

    /// The channel-mapping warning is the single most useful line in a "the wrong
    /// monitor changed" report, and its absence is the normal state — so it must
    /// appear when set and leave no row behind when not.
    /// Kills mutation: always emitting the row (every report then looks like it has
    /// an ambiguity), or never emitting it.
    func testMappingWarningAppearsOnlyWhenSet() {
        let quiet = DiagnosticReport.markdown(environment: environment, displays: [], privacy: .redacted)
        XCTAssertFalse(quiet.contains("DDC channel mapping"))

        var noisy = environment
        noisy = DiagnosticEnvironment(
            appVersion: environment.appVersion,
            appBuild: environment.appBuild,
            osVersion: environment.osVersion,
            macModel: environment.macModel,
            architecture: environment.architecture,
            ddcMappingWarning: "2 external displays, channels assigned by traversal order",
            quirksDatabaseModelCount: environment.quirksDatabaseModelCount
        )
        let markdown = DiagnosticReport.markdown(environment: noisy, displays: [], privacy: .redacted)
        XCTAssertTrue(markdown.contains("traversal order"), markdown)
    }

    // MARK: - Capabilities in the report

    /// **The raw capabilities string is printed verbatim.** It is the evidence;
    /// everything under it is Crisp's reading of it, and a report that carried
    /// only the reading could never produce the next bug report about a string a
    /// parser mishandles.
    /// Kills mutation: printing only the parsed summary, or normalising the raw
    /// text before printing it.
    func testReportPrintsTheRawCapabilitiesStringVerbatim() {
        let raw = "(prot(monitor)type(LCD)model(MA320U)vcp(10 12 60(0F 11 12 15) 62 87)mswhql(1)mccs_ver(2.2))"
        var withCaps = display()
        withCaps.capabilities = CapabilitiesDiagnostic(DDCCapabilities.parse(raw))

        let markdown = DiagnosticReport.markdown(environment: environment, displays: [withCaps])

        XCTAssertTrue(markdown.contains(raw), "the raw string must appear untouched:\n\(markdown)")
        XCTAssertTrue(markdown.contains("Capabilities string (VCP 0xF3)"))
        XCTAssertTrue(markdown.contains("valid"), "the validity level is stated")
        XCTAssertTrue(markdown.contains("0x87 sharpness"), "derived codes are named where the registry knows them")
        XCTAssertTrue(markdown.contains("mswhql"), "and the fields Crisp ignores are still listed")
        XCTAssertTrue(markdown.contains("2.2"), "the claimed MCCS version")
        XCTAssertTrue(
            markdown.contains("never to take one away"),
            "the report has to say what the string is and is not used for"
        )
    }

    /// A monitor with no capabilities string produces no section rather than an
    /// empty one, and one that was asked and said nothing says so.
    /// Kills mutation: rendering an empty fenced block, or treating an unanswered
    /// request as a fault.
    func testReportOmitsCapabilitiesSectionWhenThereIsNone() {
        let markdown = DiagnosticReport.markdown(environment: environment, displays: [display()])
        XCTAssertFalse(markdown.contains("Capabilities string"))

        var unanswered = display()
        unanswered.capabilities = .unanswered(reason: "the monitor did not answer the VCP 0xF3 request")
        let second = DiagnosticReport.markdown(environment: environment, displays: [unanswered])
        XCTAssertTrue(second.contains("the monitor returned nothing"))
        XCTAssertTrue(second.contains("did not answer"))
    }

    // MARK: - Fixtures

    private let environment = DiagnosticEnvironment(
        appVersion: "1.4.1",
        appBuild: "5",
        osVersion: "26.4.1 (25G76)",
        macModel: "Mac16,8",
        architecture: "arm64 (IOAVService I²C)",
        quirksDatabaseModelCount: 1
    )

    /// The BenQ MA320U as the app actually sees it, so the expectations below are
    /// checkable against `reference/benq-ma320u.md` rather than invented.
    private func display(
        name: String = "BenQ MA320U",
        rung: BrightnessRung = .ddcHardware,
        quirkNotes: String? = nil
    ) -> DisplayDiagnostics {
        DisplayDiagnostics(
            identity: DisplayIdentityDiagnostic(
                name: name,
                vendor: 0x09D1,
                product: 0x8075,
                serial: 16_843_009,
                displayUUID: "37D8832A-2D66-02CA-9A3B-D0E1A2B3C4D5",
                isBuiltin: false,
                isMain: true,
                resolution: "3840 × 2160",
                connection: nil
            ),
            rung: rung,
            ddc: DDCStatusDiagnostic(
                availability: .available, consecutiveReadFailures: 0, quarantineRemaining: nil
            ),
            features: [
                FeatureDiagnostic(
                    feature: .brightness,
                    support: .supported,
                    probe: RawProbe(current: 0, max: 100),
                    range: ResolvedQuirk(value: QuirkRange.mccsPercent, source: .probe, confidence: .verified)
                ),
                FeatureDiagnostic(
                    feature: .contrast,
                    support: .supported,
                    probe: RawProbe(current: 50, max: 100),
                    range: ResolvedQuirk(value: QuirkRange.mccsPercent, source: .database, confidence: .verified)
                ),
                FeatureDiagnostic(
                    feature: .volume,
                    support: .supported,
                    probe: RawProbe(current: 44, max: 50),
                    range: ResolvedQuirk(
                        value: QuirkRange(min: 0, max: 50) ?? .mccsPercent,
                        source: .database,
                        confidence: .verified
                    )
                ),
                FeatureDiagnostic(
                    feature: .input,
                    support: .supported,
                    probe: RawProbe(current: 19, max: 19),
                    range: nil
                )
            ],
            quirkMatch: QuirkMatchDiagnostic(
                key: MonitorQuirkKey(vendor: 0x09D1, product: 0x8075),
                vendorName: "BenQ",
                modelName: "MA320U",
                confidence: .verified,
                fileName: "benq.json",
                notes: quirkNotes
            ),
            currentInput: MonitorQuirkResolver.input(
                code: 19, quirks: nil, currentInput: 19, userSelectedInput: nil
            ),
            brightnessKeys: BrightnessKeyDiagnostic(
                interception: .armed,
                targetsThisDisplay: nil,
                targetDescription: "target: follow the pointer"
            )
        )
    }
}
