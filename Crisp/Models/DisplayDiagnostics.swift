import Foundation

// Everything the diagnostics sheet shows and the bug report prints, as data.
//
// Why this exists. DDC either works on a monitor or it does not, and no app can
// change that by much — so the thing worth competing on is *diagnosability*.
// This fork started with three hours lost to a failure whose only signal was one
// line in the unified log (AGENTS.md §2, and the `grantedButRefused` case in
// `BrightnessKeyService`). A user who can read why a control is missing does not
// need that log.
//
// Two rules shape the whole file:
//
//  1. **Nothing here is a second source of truth.** Every field is copied from
//     the service that already owns it (`BrightnessRung`, `MonitorQuirkResolver`,
//     `DDCProtocolEngine`'s quarantine, `BrightnessKeyService`'s interception
//     state). A diagnostic that can disagree with the behaviour it describes is
//     worse than no diagnostic.
//  2. **Never a bare "unsupported".** Every negative and every unknown carries
//     the reason a human can act on, and a fact nobody established reads
//     "unknown", never "no".
//
// Pure Foundation, so it compiles into the headless `CrispTests` target the same
// way `MonitorQuirks` and `BrightnessRung` do (AGENTS.md §3.6). The collection
// half — the part that has to touch IOKit and the live services — lives in
// `Crisp/Services/DisplayDiagnosticsService.swift`.

// MARK: - Feature ↔ VCP

extension QuirkFeatureName {
    /// The MCCS VCP code this feature *is*, from `DDCFeatureRegistry`.
    ///
    /// Read from the registry rather than from `DDCService.brightnessVCP` and
    /// friends because this model is headless and `DDCService` is not — and read
    /// from the registry rather than restated here, because a second copy of a
    /// number is a second thing that can be wrong. The constants themselves are
    /// still pinned by a test.
    var vcpCode: UInt8 { spec.vcp }

    /// Title case, for the report's feature table.
    var reportName: String { spec.title }

    /// `0x12`, the way the report and the monitor's documentation both spell it.
    var vcpText: String { spec.vcpText }
}

extension QuirkSource {
    /// Where a resolved value came from, in words a contributor can act on.
    var reportName: String {
        switch self {
        case .userOverride: return "your own earlier choice"
        case .database: return "quirks database"
        case .probe: return "live probe"
        case .capabilities: return "the monitor's capabilities string"
        case .standard: return "MCCS default"
        }
    }
}

extension DDCCapabilities.Validity {
    /// How much of the capabilities string survived, in words.
    var reportText: String {
        switch self {
        case .valid: return "every segment parsed, nothing repaired"
        case .usable: return "parsed after repairs — see the parser notes"
        case .invalid: return "nothing usable came out of it"
        }
    }
}

extension BrightnessRung {
    /// The rung, plus why it is not the one above it. `.ddcHardware` needs no
    /// excuse, which is exactly why it prints without one.
    var reportDescription: String {
        switch self {
        case .ddcHardware:
            return "DDC hardware backlight"
        case .tvNetwork(let reason):
            return "smart-TV backlight over the network — \(reason.text)"
        case .gammaTable(let reason):
            return "GPU colour table (software dimming) — \(reason.text)"
        case .overlay(let reason):
            return "black overlay window — \(reason.text)"
        case .unavailable(let reason):
            return "nothing can dim this display — \(reason.text)"
        }
    }
}

// MARK: - Raw probe

/// One VCP read, exactly as the monitor answered it.
///
/// Shared with the quirks-entry generator, which turns `max` into a candidate
/// `range` — so the number a contributor submits and the number the report prints
/// are literally the same value.
struct RawProbe: Equatable, Sendable {
    let current: UInt16
    let max: UInt16

    init(current: UInt16, max: UInt16) {
        self.current = current
        self.max = max
    }

    /// `current / max`, the form `crispctl list` prints.
    var reportText: String { "\(current) / \(max)" }
}

// MARK: - Identity

/// Who this display is. The two per-unit fields are called out as such because
/// the report redacts them by default (see `DiagnosticReport.Privacy`).
struct DisplayIdentityDiagnostic: Equatable, Sendable {
    /// The monitor's marketing name, e.g. "BenQ MA320U". A model fact, not a
    /// machine fact, so it is never redacted.
    let name: String
    let vendor: UInt32
    let product: UInt32
    /// EDID serial. Identifies one physical unit, so it is opt-in in the report.
    let serial: UInt32
    /// `CGDisplayCreateUUIDFromDisplayID`. Also identifies one physical unit —
    /// and it is the key every piece of persistence uses (AGENTS.md §3.3), which
    /// is the one bug class where a maintainer genuinely needs to see it.
    let displayUUID: String
    let isBuiltin: Bool
    let isMain: Bool
    /// e.g. "3840 × 2160". `nil` when macOS reported no current mode.
    let resolution: String?
    /// The physical link (DisplayPort / HDMI / USB-C). `nil` means macOS does not
    /// expose it through any public API on this machine — which is the normal
    /// case on Apple Silicon, where the IORegistry names the display node
    /// (`dispext0`) but not the transport. Rendered as "unknown", never guessed.
    let connection: String?

    var vendorProductText: String {
        String(format: "0x%04X / 0x%04X", vendor, product)
    }
}

// MARK: - DDC status

/// Whether Crisp has a working DDC/CI channel to this display, and whether the
/// read quarantine is currently holding reads off the bus.
struct DDCStatusDiagnostic: Equatable, Sendable {
    /// Three states, not two. `unproven` is the honest description of a display
    /// nothing has been read from or written to yet, and reporting it as "no"
    /// would send a user chasing a fault that has not happened.
    enum Availability: Equatable, Sendable {
        case available
        case unavailable(reason: String)
        case unproven(reason: String)
        case notApplicable(reason: String)

        var reportText: String {
            switch self {
            case .available: return "available"
            case .unavailable(let reason): return "unavailable — \(reason)"
            case .unproven(let reason): return "unproven — \(reason)"
            case .notApplicable(let reason): return "not applicable — \(reason)"
            }
        }
    }

    let availability: Availability
    /// Consecutive failed VCP reads for this display, from `DDCProtocolEngine`.
    /// `nil` when the engine was not consulted (the built-in panel).
    let consecutiveReadFailures: Int?
    /// Seconds until the read quarantine lifts, or `nil` when no quarantine is
    /// active. Captured at collection time so rendering needs no clock.
    let quarantineRemaining: TimeInterval?

    var isQuarantined: Bool { quarantineRemaining != nil }

    var quarantineReportText: String {
        guard let quarantineRemaining else {
            guard let consecutiveReadFailures else {
                return "not applicable — this display's reads do not go through the DDC engine"
            }
            return "inactive (\(consecutiveReadFailures) consecutive read failure\(consecutiveReadFailures == 1 ? "" : "s"))"
        }
        let minutes = Int((quarantineRemaining / 60).rounded(.up))
        // The quarantine exists because a wedged DDC controller degrades further
        // under retry hammering, so say that rather than just "active".
        return "ACTIVE for ~\(minutes) more minute\(minutes == 1 ? "" : "s") — "
            + "reads kept off the I²C bus after \(consecutiveReadFailures ?? 0) consecutive failures; writes are unaffected"
    }
}

// MARK: - Per-feature support

/// One DDC feature on one display: is it there, what did the monitor answer, and
/// what raw range does the write path actually use.
struct FeatureDiagnostic: Equatable, Sendable {
    /// Four states. `unknown` is not a softer `unsupported`: a monitor that never
    /// answers a probe and a monitor that has no such control are indistinguishable
    /// on the wire (several never set the "unsupported feature" reply bit at all —
    /// that is the `reportsUnsupportedAsSupported` quirk), so claiming either one
    /// would be inventing evidence.
    enum Support: Equatable, Sendable {
        case supported
        case unsupported(reason: String)
        case unknown(reason: String)
        case notApplicable(reason: String)

        var reportText: String {
            switch self {
            case .supported: return "supported"
            case .unsupported(let reason): return "not supported — \(reason)"
            case .unknown(let reason): return "unknown — \(reason)"
            case .notApplicable(let reason): return "not applicable — \(reason)"
            }
        }

        var isSupported: Bool {
            if case .supported = self { return true }
            return false
        }
    }

    /// Everything the support decision is allowed to look at. Each field is owned
    /// by a service that already tracks it; nothing is re-derived here.
    struct Evidence: Equatable, Sendable {
        /// What the app's own UI gates on (`DisplayInfo.contrastSupported` and
        /// friends). This is the field that makes the report agree with the panel:
        /// if the slider is there, the report says supported.
        var appReportsSupported: Bool
        /// This run's probe answered. A monitor that answers now is supported now,
        /// whatever an older flag says.
        var probeAnswered: Bool
        /// `BrightnessService.ddcAvailable`: nil = unproven, true = proven,
        /// false = writes have failed often enough to give up.
        var ddcAvailable: Bool?
        /// The built-in panel, which is driven through IOKit and has no DDC bus.
        var isBuiltinDisplay: Bool

        init(
            appReportsSupported: Bool = false,
            probeAnswered: Bool = false,
            ddcAvailable: Bool? = nil,
            isBuiltinDisplay: Bool = false
        ) {
            self.appReportsSupported = appReportsSupported
            self.probeAnswered = probeAnswered
            self.ddcAvailable = ddcAvailable
            self.isBuiltinDisplay = isBuiltinDisplay
        }
    }

    let feature: QuirkFeatureName
    let support: Support
    /// This run's raw read. `nil` when the monitor did not answer.
    let probe: RawProbe?
    /// The raw range the write path converts percentages through, and where that
    /// range came from. `nil` for `input`, which is a set of codes, not a dial.
    let range: ResolvedQuirk<QuirkRange>?

    var rangeReportText: String {
        guard let range else { return "n/a" }
        return "\(range.value.min)–\(range.value.max)"
    }

    var rangeSourceReportText: String {
        guard let range else { return "n/a" }
        return "\(range.source.reportName) (\(range.confidence.rawValue))"
    }

    /// Resolves support from evidence. Pure, ordered, and the whole content of
    /// the "why is this control missing?" question.
    ///
    /// Order matters: the built-in panel first (it has no DDC bus at all, so every
    /// other question is moot), then live evidence, then remembered evidence, then
    /// the one negative we can actually prove, and only then "unknown".
    static func resolveSupport(_ feature: QuirkFeatureName, evidence: Evidence) -> Support {
        if evidence.isBuiltinDisplay {
            // Brightness is the exception: the built-in panel really does have a
            // hardware backlight, driven through IOKit rather than DDC/CI.
            guard feature == .brightness else {
                return .notApplicable(
                    reason: "the built-in panel is driven through IOKit, not DDC/CI — "
                        + "\(feature.reportName.lowercased()) is a control on external monitors"
                )
            }
            return .supported
        }
        if evidence.probeAnswered || evidence.appReportsSupported { return .supported }
        if evidence.ddcAvailable == false {
            return .unsupported(
                reason: "there is no working DDC channel on this connection "
                    + "(MST hub, DisplayLink dock, or DDC/CI switched off in the monitor's own menu), "
                    + "so VCP \(feature.vcpText) cannot be asked about at all"
            )
        }
        return .unknown(
            reason: "the monitor did not answer the VCP \(feature.vcpText) probe. "
                + "That reads the same on the wire whether the control is absent or this link is dropping DDC replies"
        )
    }
}

// MARK: - Quirks match

/// The quirks-database row that matched this monitor, if any.
struct QuirkMatchDiagnostic: Equatable, Sendable {
    let key: MonitorQuirkKey
    let vendorName: String
    let modelName: String
    /// The model-level default. Individual features and input codes may narrow it,
    /// which is why the feature table prints its own confidence per row.
    let confidence: QuirkConfidence
    /// The vendor file the entry came from, e.g. `benq.json`. `nil` when the
    /// bundle layout made the origin unidentifiable — reported as unknown rather
    /// than guessed from the vendor name.
    let fileName: String?
    let notes: String?

    var reportText: String {
        "\(fileName ?? "unknown file") → \(vendorName) \(modelName) (\(confidence.rawValue))"
    }
}

// MARK: - Capabilities string

/// The monitor's own capabilities string (DDC/CI command 0xF3), verbatim, plus
/// what Crisp made of it.
///
/// The raw text is carried unaltered and printed unaltered. Every tolerance rule
/// in `DDCCapabilities` exists because somebody posted a raw string from a
/// monitor that broke a parser; a report that prints only this parser's *opinion*
/// of the string cannot produce the next one of those. It is a model fact, not a
/// per-unit one — two units of the same monitor send the same string — so it is
/// not redacted.
struct CapabilitiesDiagnostic: Equatable, Sendable {
    /// Exactly what came off the wire.
    let raw: String
    let validity: DDCCapabilities.Validity
    /// Advertised VCP codes, named from `DDCFeatureRegistry` where it knows one.
    let advertised: [String]
    /// Capability fields this parser does not interpret. Preserved and listed
    /// because the spec's own rule is to discard them, which means nobody ever
    /// finds out what monitors are actually sending.
    let unknownSegments: [String]
    /// `mccs_ver()`, when it parsed. Never treated as truth — monitors
    /// contradict feature 0xDF freely — so it is reported, not acted on.
    let mccsVersion: String?
    let notes: [String]

    /// Projects a parse result into the report's shape.
    init(_ capabilities: DDCCapabilities) {
        raw = capabilities.raw
        validity = capabilities.validity
        advertised = capabilities.features.map { feature in
            guard let spec = DDCFeatureRegistry.feature(forVCP: feature.code) else { return feature.codeText }
            return "\(feature.codeText) \(spec.title.lowercased())"
        }
        unknownSegments = capabilities.unknownSegments.map(\.name)
        mccsVersion = capabilities.mccsVersion?.description
        notes = capabilities.diagnostics
    }

    private init(raw: String, validity: DDCCapabilities.Validity, notes: [String]) {
        self.raw = raw
        self.validity = validity
        self.advertised = []
        self.unknownSegments = []
        self.mccsVersion = nil
        self.notes = notes
    }

    /// The monitor never answered the request. Common and not a fault: plenty of
    /// monitors implement VCP reads and not 0xF3.
    static func unanswered(reason: String) -> CapabilitiesDiagnostic {
        CapabilitiesDiagnostic(raw: "", validity: .invalid, notes: [reason])
    }
}

// MARK: - Brightness keys

/// Why F1/F2 are or are not reaching this display. Projected from
/// `BrightnessKeyService.KeyInterceptionState` at collection time — the service
/// stays the only place that decides it.
enum KeyInterceptionDiagnostic: String, Equatable, Sendable {
    case armed
    case waitingForPermission
    case grantedButRefused
    case disabled
    /// The service was never consulted (should not happen in the app; exists so a
    /// report can say so rather than claim one of the four).
    case unknown

    var reportText: String {
        switch self {
        case .armed:
            return "armed — the event tap is installed and F1/F2 are being redirected"
        case .waitingForPermission:
            return "waiting for Accessibility — the tap cannot be installed until it is granted"
        case .grantedButRefused:
            return "Accessibility looks granted but macOS refused the tap — "
                + "a stale TCC record from a differently-signed build; `tccutil reset Accessibility <bundle id>` clears it"
        case .disabled:
            return "off — brightness-key redirection is switched off in Settings"
        case .unknown:
            return "unknown — the key service was not consulted"
        }
    }
}

/// The key state as it applies to one display: the global tap plus whether this
/// particular display is currently a key target.
struct BrightnessKeyDiagnostic: Equatable, Sendable {
    let interception: KeyInterceptionDiagnostic
    /// Whether a key press currently lands on *this* display, given the target
    /// setting. `nil` for the pointer-following target, where the answer depends
    /// on where the cursor is at the moment of the press.
    let targetsThisDisplay: Bool?
    /// How the target is configured, e.g. "Follow the pointer".
    let targetDescription: String

    var reportText: String {
        let routing: String
        switch targetsThisDisplay {
        case true?: routing = "targets this display"
        case false?: routing = "does NOT target this display"
        case nil: routing = "targets whichever display the pointer is on"
        }
        return "\(interception.reportText); \(targetDescription) — \(routing)"
    }
}

// MARK: - One display

/// The complete diagnostic block for one attached display.
struct DisplayDiagnostics: Equatable, Sendable {
    let identity: DisplayIdentityDiagnostic
    let rung: BrightnessRung
    let ddc: DDCStatusDiagnostic
    /// In a fixed order (brightness, contrast, volume, input) so two reports from
    /// two users line up row for row.
    let features: [FeatureDiagnostic]
    let quirkMatch: QuirkMatchDiagnostic?
    /// The input the monitor is on right now, resolved through
    /// `MonitorQuirkResolver.input` — the same call the input menu makes, so the
    /// report cannot print a different label from the one the user sees.
    let currentInput: ResolvedInput?
    let brightnessKeys: BrightnessKeyDiagnostic
    /// The 0xF3 capabilities string. `nil` when it was not asked for at all —
    /// which is the state for the built-in panel, and for any collection that
    /// deliberately kept the extra I²C transactions off the bus.
    var capabilities: CapabilitiesDiagnostic? = nil

    func feature(_ name: QuirkFeatureName) -> FeatureDiagnostic? {
        features.first { $0.feature == name }
    }
}

// MARK: - Environment

/// The machine-level facts a bug report needs.
///
/// There is deliberately no field for the machine's serial number, the user name
/// or the host name. `reference/windowserver-crash.md` set that standard when it
/// stripped the crash-reporter key, incident UUID, boot-session UUID and hardware
/// model out of a crash log before committing it — none of them added anything to
/// the finding. Neither would they here: `macModel` is a *model identifier*
/// (`Mac16,8`), shared by every unit of that model, which is the part that
/// actually matters for a DDC bug.
struct DiagnosticEnvironment: Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    /// e.g. "26.4.1 (25G76)".
    let osVersion: String
    /// `hw.model`, e.g. "Mac16,8".
    let macModel: String
    /// "arm64" or "x86_64" — the two DDC transports are entirely different code.
    let architecture: String
    /// `DDCService.mappingWarning`: set when more than one external display is
    /// connected and the display→AVService pairing fell back to traversal order.
    /// The single most useful line in a "the wrong monitor changed" report.
    let ddcMappingWarning: String?
    let quirksDatabaseModelCount: Int

    init(
        appVersion: String,
        appBuild: String,
        osVersion: String,
        macModel: String,
        architecture: String,
        ddcMappingWarning: String? = nil,
        quirksDatabaseModelCount: Int = 0
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.macModel = macModel
        self.architecture = architecture
        self.ddcMappingWarning = ddcMappingWarning
        self.quirksDatabaseModelCount = quirksDatabaseModelCount
    }
}

// MARK: - Report rendering

/// Diagnostic facts → a markdown bug report, ready to paste into a GitHub issue.
///
/// Pure: it renders what it is given and reads nothing. That is what lets the
/// privacy guarantee be a *test* — a report cannot leak a field the renderer was
/// never handed, and the fields it is handed are enumerated in
/// `DiagnosticEnvironment` and `DisplayIdentityDiagnostic` above.
enum DiagnosticReport {

    /// What the report is allowed to include about the individual machine.
    struct Privacy: Equatable, Sendable {
        /// EDID serial and display UUID: they identify one physical unit rather
        /// than a model. Off by default.
        ///
        /// They are not merely paranoia-bait — there are exactly two bug classes
        /// that need them (two identical monitors whose DDC channels get swapped,
        /// which `DDCServiceMatcher` resolves by serial; and per-display settings
        /// not surviving a reconnect, which is keyed by UUID) — so this is a
        /// switch the UI labels with that reason, not a hidden default.
        var includePerUnitIdentifiers: Bool

        static let redacted = Privacy(includePerUnitIdentifiers: false)
        static let full = Privacy(includePerUnitIdentifiers: true)
    }

    /// Printed in place of a redacted per-unit field.
    static let redactedPlaceholder = "_(omitted — see the privacy note)_"

    static func privacyNote(_ privacy: Privacy) -> String {
        let base = "Crisp collects no machine serial number, no user name and no host name for this report."
        if privacy.includePerUnitIdentifiers {
            return base + " Per-unit display identifiers (EDID serial, display UUID) **are** included, "
                + "because they were asked for: they are what identifies which of two identical monitors is which."
        }
        return base + " Per-unit display identifiers (EDID serial, display UUID) are omitted. "
            + "Re-copy with \"Include per-unit display identifiers\" only if a maintainer asks — "
            + "they are needed for two identical monitors swapping DDC channels, or settings not surviving a reconnect."
    }

    /// The whole report.
    static func markdown(
        environment: DiagnosticEnvironment,
        displays: [DisplayDiagnostics],
        privacy: Privacy = .redacted
    ) -> String {
        var out: [String] = []
        out.append("## Crisp diagnostics")
        out.append("")
        out.append(contentsOf: environmentTable(environment))
        out.append("")
        out.append(privacyNote(privacy))

        if displays.isEmpty {
            out.append("")
            out.append("No displays attached at the time this report was generated.")
        }

        for (index, display) in displays.enumerated() {
            out.append("")
            out.append(contentsOf: displaySection(display, number: index + 1, privacy: privacy))
        }

        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: Sections

    private static func environmentTable(_ environment: DiagnosticEnvironment) -> [String] {
        var rows: [(String, String)] = [
            ("Crisp", "\(environment.appVersion) (\(environment.appBuild))"),
            ("macOS", environment.osVersion),
            ("Mac model", environment.macModel),
            ("Architecture", environment.architecture),
            ("Quirks database", "\(environment.quirksDatabaseModelCount) monitor model(s) loaded")
        ]
        // Only printed when it is set: an absent warning is the normal state and a
        // row saying "none" would make every report look like it had one.
        if let warning = environment.ddcMappingWarning {
            rows.append(("DDC channel mapping", warning))
        }
        return table(header: ("Item", "Value"), rows: rows)
    }

    private static func displaySection(
        _ display: DisplayDiagnostics,
        number: Int,
        privacy: Privacy
    ) -> [String] {
        let identity = display.identity
        // A newline inside an EDID product name would split the heading and leave
        // the rest of it as body text. Pipes are harmless in a heading, so only the
        // line breaks are collapsed here; `cell` does the fuller job below.
        var out: [String] = ["### Display \(number) — \(singleLine(identity.name))", ""]

        let perUnit: (String) -> String = { value in
            privacy.includePerUnitIdentifiers ? value : redactedPlaceholder
        }

        var rows: [(String, String)] = [
            ("Vendor / product", identity.vendorProductText),
            ("EDID serial", perUnit(String(identity.serial))),
            ("Display UUID", perUnit(identity.displayUUID)),
            ("Connection", identity.connection ?? "unknown — macOS exposes no public link type for this display"),
            ("Resolution", identity.resolution ?? "unknown — macOS reported no current mode"),
            ("Role", "\(identity.isBuiltin ? "built-in panel" : "external")\(identity.isMain ? ", main display" : "")"),
            ("Brightness path", display.rung.reportDescription),
            ("DDC", display.ddc.availability.reportText),
            ("Read quarantine", display.ddc.quarantineReportText),
            ("Quirks entry", display.quirkMatch?.reportText
                ?? "none — no contributed entry for this vendor/product, so MCCS defaults are in use"),
            ("Brightness keys", display.brightnessKeys.reportText)
        ]
        if let input = display.currentInput {
            rows.append((
                "Current input",
                "\(input.code) → \(input.displayLabel) "
                    + "(label from \(input.labelSource.reportName), \(input.labelConfidence.rawValue); "
                    + "switching to it is \(input.switchConfidence.rawValue))"
            ))
        }
        if let notes = display.quirkMatch?.notes {
            rows.append(("Quirks notes", notes))
        }
        out.append(contentsOf: table(header: ("Item", "Value"), rows: rows))

        out.append("")
        out.append("| Feature | VCP | Support | Probe (raw) | Range in use | Range source |")
        out.append("|---|---|---|---|---|---|")
        for feature in display.features {
            out.append(row([
                feature.feature.reportName,
                feature.feature.vcpText,
                feature.support.reportText,
                feature.probe?.reportText ?? "no answer",
                feature.rangeReportText,
                feature.rangeSourceReportText
            ]))
        }
        if let capabilities = display.capabilities {
            out.append("")
            out.append(contentsOf: capabilitiesSection(capabilities))
        }
        return out
    }

    /// The capabilities string, verbatim, then what was derived from it.
    ///
    /// Verbatim first and in a fenced block, because the raw string is the
    /// evidence and everything under it is this app's reading of it. A maintainer
    /// looking at a monitor nobody has seen before needs the bytes, not the
    /// summary — and the fence is what stops a string full of pipes and parens
    /// from destroying the tables above it.
    private static func capabilitiesSection(_ capabilities: CapabilitiesDiagnostic) -> [String] {
        var out = ["**Capabilities string (VCP 0xF3)** — \(capabilities.validity.rawValue)", ""]
        if capabilities.raw.isEmpty {
            out.append("_(the monitor returned nothing)_")
        } else {
            // Backticks inside a capabilities string would end the fence early;
            // no monitor has been seen sending one, but the whole point of this
            // block is that the string is untrusted input from a stranger's
            // hardware.
            out.append("```")
            out.append(singleLine(capabilities.raw).replacingOccurrences(of: "`", with: "'"))
            out.append("```")
        }
        out.append("")
        var rows: [(String, String)] = [
            ("Validity", capabilities.validity.reportText),
            ("MCCS version claimed", capabilities.mccsVersion ?? "not stated"),
            ("Advertised VCP codes", capabilities.advertised.isEmpty
                ? "none" : capabilities.advertised.joined(separator: ", ")),
            ("Unsupported fields kept", capabilities.unknownSegments.isEmpty
                ? "none" : capabilities.unknownSegments.joined(separator: ", "))
        ]
        for note in capabilities.notes {
            rows.append(("Parser note", note))
        }
        out.append(contentsOf: table(header: ("Item", "Value"), rows: rows))
        out.append("")
        // Said in the report because it is the question every reader of this
        // section asks next, and the answer is a rule rather than an omission.
        out.append(
            "Crisp uses this string only to *offer* a control it would otherwise not know about, "
                + "never to take one away: a code missing here is no evidence at all — the HP LP2480zx "
                + "omits 0x10 and drives brightness perfectly well — and a code listed here is offered "
                + "read-only until a live read confirms it."
        )
        return out
    }

    // MARK: Markdown helpers

    private static func table(header: (String, String), rows: [(String, String)]) -> [String] {
        var out = [row([header.0, header.1]), "|---|---|"]
        out.append(contentsOf: rows.map { row([$0.0, $0.1]) })
        return out
    }

    private static func row(_ cells: [String]) -> String {
        "| " + cells.map(cell).joined(separator: " | ") + " |"
    }

    /// A pipe or a newline inside a value would silently break the table and
    /// scramble the columns of a report a maintainer is trying to read. Monitor
    /// names and contributed `notes` are free text from strangers, so escape both.
    private static func cell(_ text: String) -> String {
        singleLine(text).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
