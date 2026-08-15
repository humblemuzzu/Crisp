import Foundation

// One automated change to one display, and the rule that decides what may happen
// to it. Shared by every automation surface the app exposes — the `crisp://` URL
// scheme, the Shortcuts intents, and (should it ever drive a registry feature)
// the hotkeys — so that "what is automation allowed to do" is answered once,
// here, rather than once per entry point.
//
// The rule this file exists for:
//
//   **No automation surface can perform a destructive write by itself.**
//
// `DDCFeatureRegistry` marks a feature destructive when getting it wrong costs
// the user something they cannot undo from the Mac: VCP 0x60 switches the panel
// to a port that may have nothing attached, 0xD6 powers it down, 0xCA can
// disable the monitor's own buttons permanently (ddcutil issue #153). A URL is
// the sharp case — any web page can fire `crisp://…` at this app without the
// user doing more than following a link — but the argument is not really about
// URLs: a shortcut can be triggered by a location, a time of day or another app,
// and none of those is a person who understood the hazard either.
//
// So `plan` below is total and has exactly three answers, and the destructive
// ones can only ever be `needsConfirmation`. There is deliberately no parameter,
// no flag and no origin that turns that into `ready`: `AutomationRequest` has no
// way to express "trusted", so no caller can pass one. The confirmation itself
// is the app's job (`AutomationService`), and its dialog is what produces the
// `AutomationService.UserConsent` that travels down to the DDC write gate as a
// `DDCFeatureDiscovery.Authorization.userConfirmed` — the second, independent
// layer. Neither is a comment: the first is pinned by `AutomationRequestTests`
// over the whole registry, the second by two `fileprivate` initialisers —
// `UserConsent`'s, so only the dialog mints the proof, and
// `DDCFeatureDiscovery.UserConfirmation`'s, so only a proof mints the
// authorization a destructive write needs.
//
// Pure Foundation, so all of that is testable without a monitor, a URL handler
// or a Shortcuts runtime (AGENTS.md §3.6).

// MARK: - Origin

/// Which surface asked for a change. Reported, never trusted: nothing in `plan`
/// grants one origin more than another, and the type exists so a refusal can say
/// where it came from and so a future audit line can.
enum AutomationOrigin: String, Equatable, Sendable, CaseIterable {
    /// A `crisp://` URL. Anything on the machine can open one, including a web
    /// page the user merely clicked a link on.
    case url
    /// A Shortcuts / App Intents run. Authored by the user, but triggerable by
    /// automation the user is not watching.
    case appIntent
    /// A user-assigned global hotkey. Present for completeness — no hotkey action
    /// drives a registry feature today — so that adding one cannot quietly become
    /// the one origin the destructive rule was never written for.
    case hotkey
    /// A button in Crisp's own panel: applying a preset. The user is looking at
    /// the app, which is the *most* trustworthy origin there is — and it gets
    /// exactly the same plan as the others, because the moment one origin is
    /// special the rule below stops being a rule.
    case panel
    /// A schedule firing. The sharpest case after a URL, and the reason it is
    /// named rather than folded into `.panel`: a schedule runs at a time the user
    /// chose weeks ago, on a Mac they may not be sitting at. A confirmation
    /// dialog is not a thing a schedule can satisfy, which is precisely why
    /// nothing destructive may be reachable from one.
    case schedule
}

// MARK: - Value

/// The value an automation request carries, in the shape its feature has.
///
/// Two cases rather than one number because the registry's two value shapes are
/// not interchangeable: VCP 0x60's `19` is a port, not 19% of anything, and
/// scaling it the way a slider scales brightness would aim a write at whatever
/// port `19%` happens to land on. `plan` refuses a mismatch instead of coercing.
enum AutomationValue: Equatable, Sendable {
    /// A percentage for a `continuous` feature, before clamping.
    case percent(Double)
    /// A raw code for a `nonContinuous` feature, as the monitor spells it.
    case raw(UInt16)
}

// MARK: - Request

/// What a surface is asking for, before anything has decided whether it may.
struct AutomationRequest: Equatable, Sendable {
    let origin: AutomationOrigin
    /// The display, by the identity that survives a reconnect. Never a
    /// `CGDirectDisplayID`: macOS reassigns those, so a shortcut or a link built
    /// today would silently aim at a different physical panel next week
    /// (AGENTS.md §3.3).
    let display: DisplayUUID
    let feature: DDCFeatureID
    let value: AutomationValue
}

// MARK: - Approved shape

/// A request that survived `plan`: same target and feature, with a value that has
/// been checked and clamped. Still not permission to write — `AutomationService`
/// hands it to `DDCFeatureService`, whose own gate re-decides at the wire.
struct AutomationWrite: Equatable, Sendable {
    let display: DisplayUUID
    let feature: DDCFeatureID
    /// Clamped to the feature's shape: a percent is 0...100, a raw code is
    /// whatever the monitor's own range allows and is left to the service.
    let value: AutomationValue

    /// The clamped percent, for the percent-shaped features. `nil` for a raw
    /// value, so a caller cannot read a port number as a percentage.
    var percent: Double? {
        if case .percent(let value) = value { return value }
        return nil
    }

    /// The raw code, for the non-continuous features.
    var raw: UInt16? {
        if case .raw(let value) = value { return value }
        return nil
    }
}

// MARK: - The plan

/// What may happen to a request. Total: every request gets exactly one of these.
enum AutomationPlan: Equatable, Sendable {
    /// Non-destructive and well formed. The service may apply it directly.
    case ready(AutomationWrite)
    /// Destructive. The service may apply it *only* after the user has been shown
    /// `hazard` and said yes. There is no origin for which a destructive feature
    /// produces `.ready` instead — that is the whole point of this file.
    case needsConfirmation(AutomationWrite, hazard: String)
    /// Nothing happens, and this is why. A malformed or unsupported request is a
    /// no-op, never a partial write.
    case rejected(reason: String)

    /// The write, whether or not it still needs asking. For a service that wants
    /// to log what was requested; never a way to skip the asking.
    var requestedWrite: AutomationWrite? {
        switch self {
        case .ready(let write): return write
        case .needsConfirmation(let write, _): return write
        case .rejected: return nil
        }
    }
}

extension AutomationRequest {

    /// Percent-shaped values are clamped to this. The registry's continuous
    /// features are all MCCS percentages; the raw range a monitor actually wants
    /// is resolved per display by `MonitorQuirkResolver`, far below this layer.
    static let percentRange: ClosedRange<Double> = 0...100

    /// Decides what may happen to this request. Pure, ordered, total.
    ///
    /// `attached` is the set of displays connected right now. It is a parameter
    /// rather than something looked up inside, so "a link naming a display that
    /// is not plugged in does nothing" is a property this file can be tested for
    /// rather than a branch buried in a service that needs a monitor to run.
    ///
    /// The order is by how badly each case would go if it were let through:
    /// a feature with no registry entry (nothing is known about the register),
    /// then one MCCS says is read-only, then one this app has no control for,
    /// then a display that is not there, then a value in the wrong shape, then a
    /// value that is not a number at all — and only then the destructive
    /// question, which no earlier check can answer and no later one can undo.
    ///
    /// The display check sits ahead of the destructive one deliberately: a
    /// confirmation dialog about a monitor that is not connected is a prompt
    /// whose only correct answer is Cancel, and showing it would train the user
    /// to dismiss the one dialog that matters.
    func plan(attached: Set<DisplayUUID>) -> AutomationPlan {
        let spec = feature.spec

        guard spec.isKnown else {
            return .rejected(reason: "\(feature.rawValue) has no registry entry, so there is no VCP code to write")
        }
        guard spec.access.canWrite else {
            return .rejected(reason: "MCCS marks VCP \(spec.vcpText) read-only")
        }
        // Automation is offered only for the features Crisp drives end to end.
        // The registry holds many more, and `DDCFeatureService` can read them,
        // but a percent for one of those has no resolved raw range to be scaled
        // into and a raw code for one has no control to show what it did. An
        // honest refusal beats a write nobody can check.
        guard DDCFeatureRegistry.established.contains(feature) else {
            return .rejected(
                reason: "Crisp has no automation control for \(spec.title.lowercased()) yet — "
                    + "only \(DDCFeatureRegistry.established.map(\.rawValue).joined(separator: ", "))"
            )
        }
        guard attached.contains(display) else {
            return .rejected(reason: "no attached display has the identifier \(display.rawValue)")
        }

        let checked: AutomationValue
        switch (value, spec.kind.isContinuous) {
        case (.percent(let percent), true):
            // Non-finite before clamping, not after: `min(100, .nan)` is 100 in
            // Swift, so a NaN that reached the clamp would arrive as full
            // brightness. A value that is not a number is not a request.
            guard percent.isFinite else {
                return .rejected(reason: "\(percent) is not a number \(spec.title.lowercased()) can be set to")
            }
            checked = .percent(min(max(percent, Self.percentRange.lowerBound), Self.percentRange.upperBound))
        case (.raw(let raw), false):
            checked = .raw(raw)
        case (.percent, false):
            return .rejected(
                reason: "VCP \(spec.vcpText) takes a code, not a percentage — "
                    + "scaling it would aim the write at whatever code that percentage landed on"
            )
        case (.raw, true):
            return .rejected(reason: "VCP \(spec.vcpText) takes a percentage, not a raw code")
        }

        let write = AutomationWrite(display: display, feature: feature, value: checked)
        guard !spec.destructive else {
            // The only exit for a destructive feature, from every origin. The
            // hazard is the registry's own words, so the dialog says what is
            // actually at stake instead of "are you sure?".
            return .needsConfirmation(
                write,
                hazard: spec.hazard ?? "Nothing is known about what writing VCP \(spec.vcpText) does."
            )
        }
        return .ready(write)
    }
}
