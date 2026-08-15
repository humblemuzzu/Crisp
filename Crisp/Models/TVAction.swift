import Foundation

// What may be done to a smart TV, and by whom.
//
// This is `AutomationRequest` + the `DDCFeatureDiscovery` write gate, for TVs.
// It is a separate file because a TV is a separate kind of target — addressed by
// `TVDeviceID`, not `DisplayUUID`; described by `TVFeatureRegistry`, not by a VCP
// code — but it is deliberately **not** a separate policy. The two rules are the
// same rules, and where they are the same they are the *same code*:
//
//   1. **No automation surface can perform a destructive TV action by itself.**
//      `plan` below is total and its answer for anything the registry marks
//      destructive can only be `.needsConfirmation`. There is no parameter, flag
//      or origin that produces `.ready` instead. Power-off and input switching
//      are destructive for the same reason VCP 0xD6 and 0x60 are: a TV on the
//      wrong input is a black screen, and a TV that has been switched off cannot
//      be switched back on over this protocol at all.
//
//   2. **"The user confirmed this" stays a value, and it is the *existing*
//      value.** `TVWriteGate.approve` takes a
//      `DDCFeatureDiscovery.Authorization` — the same type, carrying the same
//      `UserConfirmation`, mintable only from the same `DestructiveWriteConsent`
//      protocol. Crucially this phase adds **no new conformer** to that protocol:
//      the panel's TV confirmation reuses `PanelConfirmation` by going through
//      the app's one `destructiveDDCWriteConfirmation` alert, and automation
//      reuses `AutomationService.UserConsent` by going through the same dialog a
//      `crisp://` DDC write does. AGENTS.md calls a fourth conformer the
//      remaining escape hatch; the point of this file is that TV support did not
//      need it.
//
// And the second layer is here too, for the same reason it exists on the DDC
// side: `ApprovedTVAction`'s initialiser is `fileprivate`, so a write path takes
// its feature and its value *from the token* rather than from the request it
// thought it was performing. Skipping the gate does not produce an unguarded
// write — it produces nothing to hand the transport.
//
// Pure Foundation, so all of it is testable with no television, no URL handler
// and no Shortcuts runtime (AGENTS.md §3.6).

// MARK: - Request

/// What a surface is asking a TV to do, before anything decided whether it may.
struct TVActionRequest: Equatable, Sendable {
    /// Reported, never trusted. Nothing in `plan` grants one origin more than
    /// another — the type exists so a refusal can say where it came from.
    let origin: AutomationOrigin
    /// The TV, by the identity that survives a DHCP lease. Never a host: an
    /// address is a lease, and a link built today would point at a neighbour's
    /// television next week.
    let device: TVDeviceID
    let feature: TVFeatureID
    let value: TVActionValue
}

/// A request that survived `plan`: same target, with a value that has been
/// checked and clamped. Still not permission to act — `TVWriteGate.approve` is
/// the layer that produces the token a transport needs.
struct TVWrite: Equatable, Sendable {
    let device: TVDeviceID
    let platform: TVPlatform
    let feature: TVFeatureID
    let value: TVActionValue
}

// MARK: - The plan

/// What may happen to a request. Total: every request gets exactly one of these.
enum TVActionPlan: Equatable, Sendable {
    /// Non-destructive, well formed, and the platform can do it.
    case ready(TVWrite)
    /// Destructive. Only after the user has been shown `hazard` and agreed.
    /// There is no origin for which a destructive feature produces `.ready`.
    case needsConfirmation(TVWrite, hazard: String)
    /// Nothing happens, and this is why.
    case rejected(reason: String)

    var requestedWrite: TVWrite? {
        switch self {
        case .ready(let write): return write
        case .needsConfirmation(let write, _): return write
        case .rejected: return nil
        }
    }
}

extension TVActionRequest {

    /// Percent-shaped values are clamped to this.
    static let percentRange: ClosedRange<Double> = 0...100

    /// Decides what may happen. Pure, ordered, total.
    ///
    /// `known` is the paired devices and their platforms. A parameter rather
    /// than a lookup inside, so "a link naming a TV that was never paired does
    /// nothing" is a property this file is tested for rather than a branch buried
    /// in a service that needs a television to run.
    ///
    /// The order is by how badly each case would go if it were let through: a
    /// device nobody paired (there is nothing to talk to, and guessing an address
    /// would mean sending power-off commands onto the LAN), then a feature the
    /// platform cannot reach at all, then a value in the wrong shape, then one
    /// that is not a number — and only then the destructive question, which no
    /// earlier check can answer and no later one can undo.
    ///
    /// The pairing check sits ahead of the destructive one deliberately, exactly
    /// as the display check does in `AutomationRequest.plan`: a confirmation
    /// dialog about a television that was never added is a prompt whose only
    /// correct answer is Cancel, and showing it trains the user to dismiss the
    /// one dialog that matters.
    func plan(known: [TVDeviceID: TVPlatform]) -> TVActionPlan {
        guard let platform = known[device] else {
            return .rejected(reason: "no paired TV has the identifier \(device.rawValue)")
        }

        let spec = feature.spec
        let support = TVFeatureRegistry.support(feature, on: platform)
        guard support.canWrite else {
            let reason = support.unsupportedReason?.text
                ?? "\(platform.title) TVs do not expose \(spec.title.lowercased()) on the network."
            return .rejected(reason: reason)
        }

        let checked: TVActionValue
        switch (value, spec.kind) {
        case (.percent(let percent), .percent):
            // Non-finite before clamping, not after: `min(100, .nan)` is 100 in
            // Swift, so a NaN reaching the clamp would arrive as full volume.
            guard percent.isFinite else {
                return .rejected(reason: "\(percent) is not a value \(spec.title.lowercased()) can be set to")
            }
            checked = .percent(min(max(percent, Self.percentRange.lowerBound), Self.percentRange.upperBound))
        case (.flag(let flag), .flag):
            checked = .flag(flag)
        case (.code(let code), .code):
            // A code the TV named. Bounded and whitespace-free for the same
            // reason `CrispURL` bounds a display identifier: this string arrives
            // from a URL any web page can open.
            guard let code = Self.checkedCode(code) else {
                return .rejected(reason: "'\(code)' is not an input identifier")
            }
            checked = .code(code)
        default:
            return .rejected(
                reason: "\(spec.title.lowercased()) does not take that kind of value"
            )
        }

        let write = TVWrite(device: device, platform: platform, feature: feature, value: checked)
        guard !spec.destructive else {
            // The only exit for a destructive feature, from every origin.
            return .needsConfirmation(
                write,
                hazard: spec.hazard ?? "Nothing is known about what this does to the TV."
            )
        }
        return .ready(write)
    }

    /// The longest an input identifier may be, in UTF-8 bytes.
    ///
    /// `HDMI_1` and `KEY_HDMI2` are the real shapes; a hundred and twenty-eight
    /// bytes is far beyond anything a TV names and far below anything worth
    /// forwarding. Bytes rather than `count`, for the reason `CrispURL` spells
    /// out: `count` counts grapheme clusters and a cluster has no size limit.
    static let maximumCodeLength = 128

    private static func checkedCode(_ code: String) -> String? {
        guard !code.isEmpty, code.utf8.count <= maximumCodeLength,
              code.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return code
    }
}

// MARK: - The write gate

/// The gate every TV action passes on its way to a transport.
enum TVWriteGate {

    /// An action that has passed the gate, carrying the feature and the value
    /// that may go on the wire.
    ///
    /// `fileprivate init` for the same reason `DDCFeatureDiscovery.ApprovedWrite`
    /// has one: the DDC gate shipped for a phase with a write path that took its
    /// VCP code from the feature it *thought* it was writing and never called the
    /// gate at all. Nothing broke, because the only feature driven through it was
    /// harmless — and the next contributor to copy that shape would have shipped
    /// an unconfirmed destructive write that compiled clean. So a TV write path
    /// takes its feature and value from this token, and no service and no test
    /// can mint one.
    struct ApprovedTVAction: Equatable, Sendable {
        let device: TVDeviceID
        let platform: TVPlatform
        let feature: TVFeatureID
        let value: TVActionValue

        fileprivate init(device: TVDeviceID, platform: TVPlatform, feature: TVFeatureID, value: TVActionValue) {
            self.device = device
            self.platform = platform
            self.feature = feature
            self.value = value
        }
    }

    /// The gate's answer: the token, or the reason there is not one.
    enum Approval: Equatable, Sendable {
        case approved(ApprovedTVAction)
        case refused(reason: String)

        var isApproved: Bool {
            if case .approved = self { return true }
            return false
        }

        var refusalReason: String? {
            guard case .refused(let reason) = self else { return nil }
            return reason
        }
    }

    /// Ordered by how badly each refusal would have gone: a feature the platform
    /// cannot reach, then the destructive ones — refused even when everything
    /// else checks out, unless the user asked for this exact action.
    ///
    /// `authorization` is `DDCFeatureDiscovery.Authorization` on purpose. Using
    /// the same currency means a TV power-off is authorised by exactly the tokens
    /// a VCP 0xD6 write is, minted at exactly the same two dialogs, and a future
    /// automatic caller cannot reach either by writing down the word "confirmed".
    static func approve(
        _ write: TVWrite,
        authorization: DDCFeatureDiscovery.Authorization
    ) -> Approval {
        let spec = write.feature.spec
        let support = TVFeatureRegistry.support(write.feature, on: write.platform)
        guard support.canWrite else {
            return .refused(
                reason: support.unsupportedReason?.text
                    ?? "\(write.platform.title) TVs do not expose \(spec.title.lowercased()) on the network."
            )
        }
        guard !spec.destructive || authorization.isUserConfirmed else {
            return .refused(
                reason: "\(spec.title) on a TV is destructive and this was not confirmed by the user. "
                    + (spec.hazard ?? "")
            )
        }
        return .approved(
            ApprovedTVAction(
                device: write.device, platform: write.platform,
                feature: write.feature, value: write.value
            )
        )
    }
}
