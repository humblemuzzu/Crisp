import Foundation

// Which DDC features Crisp offers for a display, on what evidence, and whether a
// write to one is allowed. The rule, not a comment about the rule.
//
// Priority, highest first — `MonitorQuirkResolver`'s ladder with the monitor's
// own capabilities string wedged in below the live probe:
//
//     user override → quirks database → live probe → capabilities string → MCCS default
//
// and one constraint that is not a tie-break:
//
//   **The capabilities string may only WIDEN discovery, never narrow it, and
//   never override a live probe.**
//
// Both halves of that have cost people features on real hardware:
//
//   - The HP LP2480zx omits 0x10 from its capabilities string and supports
//     brightness perfectly well. A parser that narrows takes the slider away
//     from a monitor that answers every read.
//   - The LG 27MD5KL advertises dozens of features, of which three respond. A
//     parser that treats a well-formed parse as proof offers thirty controls
//     that do nothing.
//
// ddcui greys controls out from this string. That is the counter-example, not
// the model.
//
// The other half of this file is the write gate. ddcutil issue #153 documents a
// monitor whose OSD and physical buttons were permanently disabled by DDC
// commands, so the default for anything the app has not proved is **read-only**,
// and anything the registry marks destructive needs the user to have asked for
// it — through the one confirmation gate that already exists for input
// switching (`InputSourceMenuRow`), never a second copy of it.
//
// "The user asked for it" is a value, not a claim: `Authorization.userConfirmed`
// carries a `UserConfirmation` this file will only mint from a
// `DestructiveWriteConsent`, and every conformer keeps its initialiser
// `fileprivate` to the file that owns the decision. See the protocol's own
// documentation for exactly what that enforces and what it does not.
//
// Pure Foundation: it compiles into the headless `CrispTests` target, which is
// what makes "capabilities may only widen" a test rather than a convention.

enum DDCFeatureDiscovery {

    // MARK: - Evidence

    /// Everything the discovery rule is allowed to look at, one feature, one
    /// display. Each field is owned by a service that already tracks it; nothing
    /// is re-derived here.
    struct Evidence: Equatable, Sendable {
        /// The user turned this feature on or off for this display themselves.
        /// `nil` — the normal case — means they never said.
        var userOverride: Bool?
        /// The quirks-database row for this feature, when there is one.
        var quirk: QuirkFeature?
        /// A live DDC read of the feature's VCP code: `true` the monitor
        /// answered, `false` it was asked and said nothing, `nil` never asked.
        /// The three states are distinct: "asked and silent" and "never asked"
        /// look identical in a Bool and mean opposite things.
        var probeAnswered: Bool?
        /// Whether the monitor's capabilities string advertises the code. `nil`
        /// when no usable capabilities string has been read — which is not the
        /// same as a string that omits the code, and must not be treated as it.
        var capabilitiesAdvertises: Bool?

        init(
            userOverride: Bool? = nil,
            quirk: QuirkFeature? = nil,
            probeAnswered: Bool? = nil,
            capabilitiesAdvertises: Bool? = nil
        ) {
            self.userOverride = userOverride
            self.quirk = quirk
            self.probeAnswered = probeAnswered
            self.capabilitiesAdvertises = capabilitiesAdvertises
        }
    }

    // MARK: - Result

    /// Whether the feature is offered, and how well founded that is.
    enum Availability: String, Equatable, Sendable {
        /// Offer it, and allow writes (subject to `access` and confirmation).
        case proven
        /// Offer it, marked unproven, and keep it read-only. This is where a
        /// capabilities-only feature lands, permanently, until something answers.
        case unproven
        /// Do not offer it.
        case absent

        var isOffered: Bool { self != .absent }
    }

    /// The resolved answer for one feature on one display.
    struct Resolution: Equatable, Sendable {
        let feature: DDCFeatureID
        let availability: Availability
        /// Which tier of the ladder decided it.
        let source: QuirkSource
        /// Whether a write may be issued at all — before the destructive gate,
        /// which is a separate question with a separate answer.
        let writable: Bool
        /// A destructive feature always confirms, however well proven it is.
        let requiresConfirmation: Bool
        /// Why, in words a diagnostics report can print.
        let reason: String
    }

    // MARK: - The rule

    /// Resolves one feature from evidence. Pure, ordered, total.
    static func resolve(_ spec: DDCFeatureSpec, evidence: Evidence) -> Resolution {
        let outcome = availability(spec, evidence)
        return Resolution(
            feature: spec.id,
            availability: outcome.availability,
            source: outcome.source,
            // Read-only by MCCS, or unknown to the registry, and no amount of
            // evidence makes it writable.
            writable: outcome.availability == .proven && spec.access.canWrite && spec.isKnown,
            requiresConfirmation: spec.destructive,
            reason: outcome.reason
        )
    }

    private typealias Outcome = (availability: Availability, source: QuirkSource, reason: String)

    private static func availability(_ spec: DDCFeatureSpec, _ evidence: Evidence) -> Outcome {
        // 1. The user's own decision, in both directions. Nothing outranks it.
        if let userOverride = evidence.userOverride {
            return userOverride
                ? (.proven, .userOverride, "you enabled \(spec.title.lowercased()) for this display")
                : (.absent, .userOverride, "you turned \(spec.title.lowercased()) off for this display")
        }

        // 2. The quirks database. A `verified` row is a human's word that they
        //    watched this change on the physical panel, which is the strongest
        //    evidence in the file. A `reported` row is one person's claim — so it
        //    offers the feature, but a live answer is what promotes it.
        if let quirk = evidence.quirk {
            if quirk.confidence.isVerified {
                return (.proven, .database, "the quirks database has a verified \(spec.title.lowercased()) entry for this model")
            }
            if evidence.probeAnswered == true {
                return (.proven, .probe, "the monitor answered VCP \(spec.vcpText), confirming the quirks database's reported entry")
            }
            return (.unproven, .database, "the quirks database reports \(spec.title.lowercased()) on this model, unconfirmed")
        }

        // 3. The live probe. The monitor answering is proof, and it is the tier
        //    the capabilities string is forbidden to overrule.
        if evidence.probeAnswered == true {
            return (.proven, .probe, "the monitor answered a VCP \(spec.vcpText) read")
        }

        // 4. The capabilities string, which may only widen. It lands on
        //    `unproven` and stays there: a well-formed parse says the monitor's
        //    firmware mentions the code, not that the code does anything.
        if evidence.capabilitiesAdvertises == true {
            return (
                .unproven, .capabilities,
                "the monitor's capabilities string advertises VCP \(spec.vcpText), which nothing has confirmed"
            )
        }

        // 5. MCCS default: nothing is offered on the strength of the standard
        //    alone. Note what is deliberately absent here — a capabilities string
        //    that does NOT list the code changes nothing at this step, because
        //    that is exactly the narrowing this rule forbids.
        if evidence.probeAnswered == false {
            return (
                .absent, .probe,
                "the monitor did not answer a VCP \(spec.vcpText) read"
            )
        }
        return (
            .absent, .standard,
            "nothing has been read from this display for VCP \(spec.vcpText) yet"
        )
    }

    // MARK: - The write gate

    /// Who asked for a write.
    enum Authorization: Equatable, Sendable {
        /// The app decided by itself: a preset, a periodic refresh, a reapply of
        /// something nobody chose. Never enough for a destructive feature.
        case automatic
        /// The user asked for this specific write, having been shown what it
        /// does — either by answering a confirmation dialog, or by choosing a
        /// value the resolver could already vouch for, or (on reconnect) by
        /// having chosen this exact value earlier. Which of those it was is in
        /// the token; the gate treats them alike.
        case userConfirmed(UserConfirmation)

        /// The only way to build a `.userConfirmed`: hand it a consent the
        /// caller could only be *holding*, never spelling.
        static func confirmed(by consent: some DestructiveWriteConsent) -> Authorization {
            .userConfirmed(UserConfirmation(site: consent.consentSite))
        }

        var isUserConfirmed: Bool {
            if case .userConfirmed = self { return true }
            return false
        }

        /// Which confirmation site vouched, for a log line or a diagnostics row.
        var confirmationSite: String? {
            guard case .userConfirmed(let confirmation) = self else { return nil }
            return confirmation.site
        }
    }

    /// Proof that a specific human decided on a specific destructive write.
    ///
    /// The initialiser is `fileprivate` and the only thing in this file that
    /// calls it is `Authorization.confirmed(by:)`, which demands a
    /// `DestructiveWriteConsent`. That indirection is the whole point. Before it,
    /// the confirmed state was a bare enum case, so `.userConfirmed` was a claim
    /// any caller in the module could make — and `DDCFeatureService.setInputSource`
    /// made it once, hardcoded, on behalf of every caller it would ever have. Its
    /// three callers were correct only because each happened to confirm upstream;
    /// a fourth (a preset apply, a scheduled reapply) would have compiled clean
    /// and put an unconfirmed VCP 0x60 write on the bus.
    struct UserConfirmation: Equatable, Sendable {
        /// Which site vouched, in the words a refusal or a log line should use.
        /// Carried for reporting only — the gate does not read it.
        let site: String

        fileprivate init(site: String) { self.site = site }
    }
}

/// Something a caller can only hold because a particular human decision
/// happened. The currency `DDCFeatureDiscovery.Authorization.confirmed(by:)`
/// takes, so that "the user asked for this" is a value that had to be obtained
/// rather than an enum case anyone can type.
///
/// Each conforming type lives in the file that owns its decision and keeps its
/// initialiser `fileprivate`, which is the mechanism rather than a convention:
/// inside one Swift module, file privacy is the only thing that makes a value
/// genuinely unforgeable, so the proof has to be minted where the decision is
/// made and travel from there. The three that exist:
///
///   - `PanelConfirmation` (`Crisp/Views/DDCFeatureViews.swift`) — the app's one
///     destructive-write alert was answered, or the resolver could already vouch
///     for the value the user picked.
///   - `AutomationService.UserConsent` — the `NSAlert` a `crisp://` URL or a
///     Shortcuts run has to get past.
///   - `DDCFeatureService.RestoredUserChoice` — a reconnect re-applying the
///     exact value on record as this user's own choice for this display.
///
/// What it does not do is stop someone declaring a fourth conformer; nothing
/// in-module can. That escape hatch is deliberate — the headless tests need one —
/// and it is loud: a new type whose documented purpose is "a human decided this",
/// visible in a diff. What it does stop is the quiet version, a new automatic
/// caller writing `.userConfirmed` because that is what the parameter wanted.
protocol DestructiveWriteConsent: Sendable {
    /// How the site should be named in a log line: second person, because it
    /// ends up in a sentence about what the user did.
    var consentSite: String { get }
}

extension DDCFeatureDiscovery {

    /// Whether a write may go on the wire.
    enum WriteDecision: Equatable, Sendable {
        case allowed
        case refused(reason: String)

        var isAllowed: Bool { self == .allowed }
        var refusalReason: String? {
            guard case .refused(let reason) = self else { return nil }
            return reason
        }
    }

    /// A write that has passed the gate, carrying the code and the value that may
    /// go on the wire.
    ///
    /// The second layer of the gate, and a type rather than a convention because
    /// the first layer turned out to be easy to forget: `DDCFeatureService`'s
    /// generic percent adapter shipped for one phase writing `feature.spec.vcp`
    /// straight to the transport without ever calling `authorize`. Nothing broke,
    /// because the only feature driven through it was contrast — but VCP 0x0C is
    /// percent-shaped *and* destructive, so the first contributor to add a colour
    /// temperature slider the way that file's class doc tells them to would have
    /// shipped an unconfirmed destructive write that compiled clean.
    ///
    /// So a write path now takes its VCP code and its value **from this token**,
    /// never from the feature it thought it was writing, and the initialiser is
    /// `fileprivate`: no service and no test can mint one, and `approve` below is
    /// the only thing in the app that produces one. Skipping the gate no longer
    /// means an unguarded write, it means having nothing to hand the transport.
    struct ApprovedWrite: Equatable, Sendable {
        let feature: DDCFeatureID
        /// The registry's code for that feature, not the caller's idea of it.
        let vcp: UInt8
        /// The raw value, as asked for and as allowed.
        let value: UInt16

        fileprivate init(feature: DDCFeatureID, vcp: UInt8, value: UInt16) {
            self.feature = feature
            self.vcp = vcp
            self.value = value
        }
    }

    /// The gate's answer when a caller intends to write: the token, or the reason
    /// there isn't one.
    enum WriteApproval: Equatable, Sendable {
        case approved(ApprovedWrite)
        case refused(reason: String)

        /// The same answer as a plain decision, for reporting it.
        var decision: WriteDecision {
            switch self {
            case .approved: return .allowed
            case .refused(let reason): return .refused(reason: reason)
            }
        }
    }

    /// The gate every write to a registry feature passes.
    ///
    /// Ordered by how badly each refusal would have gone: a code the registry
    /// does not know, then one MCCS says is read-only, then one nothing has
    /// proved this monitor has, and finally the destructive ones — which are
    /// refused even when everything else about them checks out, unless the user
    /// asked for this exact write.
    static func approve(
        _ spec: DDCFeatureSpec,
        value: UInt16,
        resolution: Resolution,
        authorization: Authorization
    ) -> WriteApproval {
        guard spec.isKnown else {
            return .refused(reason: "\(spec.id.rawValue) has no registry entry, so there is no VCP code to write")
        }
        guard spec.access.canWrite else {
            return .refused(reason: "MCCS marks VCP \(spec.vcpText) read-only")
        }
        guard resolution.availability == .proven else {
            return .refused(
                reason: "nothing has proved this monitor supports VCP \(spec.vcpText) — "
                    + "\(resolution.reason). It stays read-only until a quirks entry or a live read says otherwise"
            )
        }
        guard !spec.destructive || authorization.isUserConfirmed else {
            return .refused(
                reason: "VCP \(spec.vcpText) is destructive and this write was not confirmed by the user. "
                    + (spec.hazard ?? "")
            )
        }
        return .approved(ApprovedWrite(feature: spec.id, vcp: spec.vcp, value: value))
    }

    /// The same gate for a caller that wants the decision without a value in hand
    /// — a view deciding whether to offer a control, a diagnostics line. The rule
    /// lives once, in `approve`; this cannot drift from it because it *is* it.
    static func authorize(
        _ spec: DDCFeatureSpec,
        resolution: Resolution,
        authorization: Authorization
    ) -> WriteDecision {
        approve(spec, value: 0, resolution: resolution, authorization: authorization).decision
    }
}
