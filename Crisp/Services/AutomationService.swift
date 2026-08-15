import AppKit
import CoreGraphics
import os.log

private let automationLog = Logger(subsystem: "com.crisp.app", category: "AutomationService")

/// The one door every automation surface goes through: the `crisp://` URL
/// scheme, the Shortcuts intents, and anything added later.
///
/// It owns two things and deliberately no others.
///
/// **1. Resolving a display by its stable UUID.** Automation names a display the
/// only way that survives a reconnect (AGENTS.md §3.3). A UUID nothing is
/// attached to is a no-op with a reason, never an error and never a write to
/// whichever display happened to be first.
///
/// **2. The destructive-write confirmation.** `AutomationRequest.plan` has
/// already decided that a destructive feature cannot be applied by an automation
/// surface on its own; this file is where "unless the user says so" is
/// implemented, and it is implemented once:
///
///   - `confirm(...)` is the only function in the app that can produce a
///     `UserConsent`, whose initialiser is `fileprivate`. Nothing outside this
///     file can mint one, and every destructive path below demands one as an
///     argument. Skipping the dialog is not a discipline here, it is a value a
///     caller cannot obtain — the same shape `DDCFeatureDiscovery.ApprovedWrite`
///     uses for the DDC write gate, and for the same reason: the first version
///     of that gate was a rule people were supposed to remember.
///   - There is no parameter, preference or URL field that skips it. A URL
///     carrying anything the grammar does not define is refused whole
///     (`CrispURL`), so a `?confirmed=true` cannot even be quietly ignored.
///   - Beneath both of those, `DDCFeatureService` re-runs
///     `DDCFeatureDiscovery.approve` at the wire and refuses a destructive write
///     whose authorization does not carry a `UserConfirmation` — which the gate
///     will only mint from this same `UserConsent`. Three layers, of which the
///     bottom one is the one that actually touches the I2C bus, and one token
///     spanning all three rather than a fresh assertion at each.
///
/// No private frameworks anywhere in it (AGENTS.md §3.1): everything goes
/// through the same `BrightnessService` / `DDCFeatureService` / `VolumeService`
/// calls the panel's own sliders use, so automation cannot reach a code path the
/// UI does not.
@MainActor
final class AutomationService {
    static let shared = AutomationService()
    private init() {}

    /// Proof that a human was shown a hazard and agreed to it.
    ///
    /// `fileprivate init` is the whole design: `confirm(...)` below is the only
    /// thing that can construct one, so a destructive apply cannot be reached by
    /// a future caller passing `true`.
    ///
    /// It conforms to `DestructiveWriteConsent` so that the same value travels
    /// all the way down to the DDC gate. Before that, this token stopped at
    /// `applyDestructive` and the gate was told `.userConfirmed` by the service
    /// underneath, on behalf of whoever called it — one unforgeable proof and
    /// then a claim.
    struct UserConsent: DestructiveWriteConsent {
        let consentSite = "you allowed it when Crisp asked"

        fileprivate init() {}
    }

    /// What an automation request did.
    enum Outcome: Equatable, Sendable {
        /// The change was applied (or handed to the coalescing writer).
        case applied(String)
        /// Understood, and deliberately not done — no such display, the monitor
        /// does not have the feature, the user cancelled the confirmation, or the
        /// DDC gate refused it.
        case refused(reason: String)
        /// Not understood. Malformed URLs land here and nothing happens at all.
        case ignored(reason: String)

        var didApply: Bool {
            if case .applied = self { return true }
            return false
        }

        /// The sentence to log or hand back to Shortcuts.
        var message: String {
            switch self {
            case .applied(let what): return what
            case .refused(let reason): return reason
            case .ignored(let reason): return reason
            }
        }
    }

    // MARK: - URL entry point

    /// Handles one `crisp://` URL. Parsing is `CrispURL`'s job and is pure; this
    /// only performs what came out of it.
    @discardableResult
    func handle(_ url: URL) async -> Outcome {
        let outcome: Outcome
        switch CrispURL.command(for: url) {
        case .ignored(let reason):
            outcome = .ignored(reason: reason)
        case .refreshDisplays:
            outcome = refreshDisplays()
        case .write(let request):
            outcome = await perform(request)
        case .tvAction(let request):
            outcome = await performTV(request)
        case .applyPreset(let id, let origin):
            outcome = await applyPreset(id: id, origin: origin)
        }
        // The scheme is a surface anything on the machine can reach, so every
        // arrival is logged whether or not it did anything. The URL itself is
        // `.private`: it carries a display UUID, which identifies one physical
        // unit (see the diagnostics report's own opt-in for the same field).
        automationLog.info(
            "crisp:// \(url.absoluteString, privacy: .private) -> \(outcome.message, privacy: .public)"
        )
        return outcome
    }

    // MARK: - Requests

    /// Applies one request, or explains why it did not.
    ///
    /// Every branch that writes takes its value from the plan's
    /// `AutomationWrite`, never from the request: the plan is what clamped it.
    @discardableResult
    func perform(_ request: AutomationRequest) async -> Outcome {
        let attached = Set(displays.map(\.stateUUID))
        switch request.plan(attached: attached) {
        case .rejected(let reason):
            return .refused(reason: reason)

        case .ready(let write):
            guard let display = display(for: write.display) else { return noSuchDisplay(write.display) }
            return await apply(write, to: display)

        case .needsConfirmation(let write, let hazard):
            // The plan already checked that the display is attached; this is the
            // race where it went away between the two, and it must not become a
            // dialog about a monitor that is no longer there.
            guard let display = display(for: write.display) else { return noSuchDisplay(write.display) }
            guard let consent = confirm(write, hazard: hazard, on: display, origin: request.origin) else {
                return .refused(reason: "\(display.name): the change was not confirmed")
            }
            return applyDestructive(write, to: display, consent: consent)
        }
    }

    // MARK: - Smart TVs

    /// Applies one TV action, or explains why it did not.
    ///
    /// Deliberately the same three-step shape as `perform` above: plan, confirm
    /// if the plan says so, then hand the *approved* value to the service. The
    /// consent is the same `UserConsent` a destructive DDC write needs, minted by
    /// the same dialog, and it travels into `TVWriteGate.approve` as a
    /// `DDCFeatureDiscovery.Authorization` — so switching a television to a dead
    /// input from a `crisp://` link is gated by exactly the machinery that gates
    /// VCP 0x60, with no new consent type and no second policy.
    @discardableResult
    func performTV(_ request: TVActionRequest) async -> Outcome {
        let service = TVDeviceService.shared
        switch request.plan(known: service.knownPlatforms) {
        case .rejected(let reason):
            return .refused(reason: reason)

        case .ready(let write):
            guard case .approved(let approved) = TVWriteGate.approve(write, authorization: .automatic) else {
                return .refused(reason: "\(write.feature.rawValue) is not allowed on this TV")
            }
            return outcome(await service.perform(approved))

        case .needsConfirmation(let write, let hazard):
            guard let device = service.device(id: write.device) else {
                return .refused(reason: "no paired TV has the identifier \(write.device.rawValue)")
            }
            guard let consent = confirmTV(write, hazard: hazard, on: device, origin: request.origin) else {
                return .refused(reason: "\(device.name): the change was not confirmed")
            }
            guard case .approved(let approved) = TVWriteGate.approve(
                write, authorization: .confirmed(by: consent)
            ) else {
                return .refused(reason: "\(device.name): \(write.feature.rawValue) is not allowed on this TV")
            }
            return outcome(await service.perform(approved))
        }
    }

    private func outcome(_ result: TVDeviceService.Outcome) -> Outcome {
        switch result {
        case .applied(let what): return .applied(what)
        case .refused(let reason): return .refused(reason: reason)
        }
    }

    /// The TV half of the one confirmation.
    ///
    /// It is the same dialog with the same default (Cancel), the same re-entrancy
    /// refusal, and the same hazard-verbatim wording — and crucially it is in this
    /// file, so it mints the *existing* `UserConsent` rather than introducing a
    /// fourth `DestructiveWriteConsent` conformer. AGENTS.md names that as the
    /// remaining escape hatch in the design; smart-TV support did not need it.
    private func confirmTV(
        _ write: TVWrite, hazard: String, on device: TVDevice, origin: AutomationOrigin
    ) -> UserConsent? {
        guard !isConfirming else { return nil }
        isConfirming = true
        defer { isConfirming = false }

        let source = Self.label(for: origin)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Allow \(source) to change \(device.name)?")
        let value: String
        switch write.value {
        case .percent(let percent): value = "\(Self.wholePercent(percent))%"
        case .flag(let flag): value = flag ? String(localized: "on") : String(localized: "off")
        case .code(let code): value = code
        }
        let asked = String(
            localized: "\(source) asked Crisp to set \(write.feature.spec.title.lowercased()) to \(value)."
        )
        alert.informativeText = asked + "\n\n" + hazard
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return UserConsent()
    }

    /// Applies a stored preset.
    ///
    /// It adds no permission of its own: `DDCPresetService` turns the preset into
    /// one `AutomationRequest` per setting and sends each back through `perform`
    /// above, so a preset can only ever do what a URL naming the same feature
    /// directly could do. A preset cannot carry a destructive feature at all
    /// (`DDCPreset`'s header says why), and if one ever did, its plan would come
    /// back `needsConfirmation` like any other.
    ///
    /// A display the preset names but that is not attached is skipped rather than
    /// failing the run — the same rule `AutomationRequest.plan` applies to a
    /// single write, reported here as a count instead of an error.
    @discardableResult
    func applyPreset(id: String, origin: AutomationOrigin) async -> Outcome {
        guard let preset = DDCPresetService.shared.presets.first(where: { $0.id == id }) else {
            return .refused(reason: "no preset has the identifier \(id)")
        }
        let outcome = await DDCPresetService.shared.apply(preset, origin: origin)
        guard outcome.didAnything else {
            return .refused(
                reason: outcome.refused.first
                    ?? "\(preset.name) has nothing to apply to the displays attached right now"
            )
        }
        let absent = outcome.missingDisplays.isEmpty
            ? ""
            : String(localized: " (\(outcome.missingDisplays.count) display(s) not connected)")
        return .applied(String(localized: "applied preset \(preset.name)") + absent)
    }

    /// Re-enumerates displays and re-probes their DDC features.
    ///
    /// A notification rather than a direct call because `DisplayManager` is owned
    /// by `AppDelegate` (one instance, injected into the view tree) and reaching
    /// it from here would mean a second global handle on it.
    @discardableResult
    func refreshDisplays() -> Outcome {
        NotificationCenter.default.post(name: .crispAutomationRefreshDisplays, object: nil)
        return .applied("refreshing displays")
    }

    /// The attached display with this UUID, or nil. The lookup every surface
    /// shares, so "which display" means the same thing in a URL and in a shortcut.
    func display(for uuid: DisplayUUID) -> DisplayInfo? {
        DisplayManagerAccessor.shared.displays.first { $0.stateUUID == uuid }
    }

    /// Every attached display, for the Shortcuts entity query.
    var displays: [DisplayInfo] { DisplayManagerAccessor.shared.displays }

    private func noSuchDisplay(_ uuid: DisplayUUID) -> Outcome {
        .refused(reason: "no attached display has the identifier \(uuid.rawValue)")
    }

    // MARK: - Applying

    /// The non-destructive features, each through the same service call the
    /// panel's own control uses — so a shortcut and a slider cannot drift apart,
    /// and neither can reach the transport without the DDC gate's approval.
    private func apply(_ write: AutomationWrite, to display: DisplayInfo) async -> Outcome {
        guard let percent = write.percent else {
            // A non-continuous, non-destructive feature. None exists in
            // `DDCFeatureRegistry.established`, which is all `plan` allows, so
            // this is unreachable rather than merely unlikely — and it refuses
            // instead of guessing a raw write.
            return .refused(reason: "\(write.feature.rawValue) has no automation control")
        }
        let rounded = Self.wholePercent(percent)
        switch write.feature {
        case .brightness:
            await BrightnessService.shared.setBrightness(percent, for: display)
            return .applied("\(display.name): brightness \(rounded)%")
        case .contrast:
            guard display.contrastSupported else { return unsupported(write.feature, on: display) }
            DDCFeatureService.shared.setContrast(percent, for: display)
            return .applied("\(display.name): contrast \(rounded)%")
        case .volume:
            guard display.volumeSupported else { return unsupported(write.feature, on: display) }
            VolumeService.shared.setVolume(percent, for: display)
            return .applied("\(display.name): volume \(rounded)%")
        default:
            return .refused(reason: "\(write.feature.rawValue) has no automation control")
        }
    }

    /// The destructive features. Unreachable without a `UserConsent`, which only
    /// `confirm` can produce.
    ///
    /// `consent` is not a flag this function checks; it is the value the write
    /// itself is made of. `setInputSource` takes a `DestructiveWriteConsent` and
    /// hands it to the DDC gate, so the dialog that produced this token is what
    /// authorises the frame that reaches the monitor — one proof, all the way
    /// down, rather than a proof here and an assertion there.
    private func applyDestructive(
        _ write: AutomationWrite, to display: DisplayInfo, consent: UserConsent
    ) -> Outcome {
        guard let raw = write.raw else {
            return .refused(reason: "\(write.feature.rawValue) has no automation control")
        }
        switch write.feature {
        case .input:
            guard display.inputSourceSupported else { return unsupported(write.feature, on: display) }
            DDCFeatureService.shared.setInputSource(raw, for: display, confirmedBy: consent)
            return .applied("\(display.name): input source \(raw)")
        default:
            return .refused(reason: "\(write.feature.rawValue) has no automation control")
        }
    }

    private func unsupported(_ feature: DDCFeatureID, on display: DisplayInfo) -> Outcome {
        .refused(
            reason: "\(display.name) has not answered a \(feature.spec.title.lowercased()) read, "
                + "so Crisp does not drive VCP \(feature.spec.vcpText) on it"
        )
    }

    /// A percentage as a whole number, for the sentence a surface reports back
    /// and for the value the confirmation dialog shows.
    ///
    /// Clamps *before* converting, because `Int(_:)` traps — not returns
    /// garbage, traps — on a finite `Double` outside `Int`'s range, and a trap
    /// here is the app disappearing while the user reads a web page.
    /// `AutomationRequest.plan` clamps percent-shaped values to `percentRange`
    /// and refuses non-finite ones before anything gets this far, so nothing has
    /// ever reached that trap. But that invariant lives in another file, one
    /// registry entry away from moving: VCP 0x0C is percent-shaped *and*
    /// destructive, so the day something gives colour temperature a control, the
    /// second call site below runs on a path `plan` did not shape. A conversion
    /// that is correct on its own does not depend on which file the clamp is in.
    private static func wholePercent(_ percent: Double) -> Int {
        guard percent.isFinite else { return 0 }
        let range = AutomationRequest.percentRange
        return Int(min(max(percent, range.lowerBound), range.upperBound).rounded())
    }

    // MARK: - The confirmation

    /// True while a confirmation is on screen.
    ///
    /// A page can open `crisp://` URLs in a loop, and a queue of modal alerts is
    /// its own denial of service. The second and later destructive requests are
    /// refused outright rather than stacked: refusing is always the safe answer,
    /// and the user can repeat the one they meant.
    private var isConfirming = false

    /// Asks the user, and returns consent only if they agreed.
    ///
    /// The wording is the registry's `hazard` verbatim — the same sentence the
    /// panel's own input dialog shows — because "are you sure?" tells a user
    /// nothing while "if nothing is attached to that port the screen goes blank
    /// and only the monitor's buttons can bring it back" tells them exactly what
    /// they are deciding. It also names the surface that asked, because a dialog
    /// that appears while the user is reading a web page must say why.
    ///
    /// An `NSAlert` rather than the panel's SwiftUI `destructiveDDCWriteConfirmation`
    /// modifier for one reason: a URL can arrive with the panel closed, and a
    /// dialog attached to a view that is not on screen is not a dialog. The
    /// *decision* is unchanged — same hazard text, same refusal by default, and
    /// the same `DDCFeatureDiscovery` gate underneath both.
    private func confirm(
        _ write: AutomationWrite, hazard: String, on display: DisplayInfo, origin: AutomationOrigin
    ) -> UserConsent? {
        guard !isConfirming else { return nil }
        isConfirming = true
        defer { isConfirming = false }

        let source = Self.label(for: origin)
        let value = write.raw.map(String.init) ?? write.percent.map { "\(Self.wholePercent($0))%" } ?? ""
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Allow \(source) to change \(display.name)?")
        // The hazard is appended rather than interpolated: it is the registry's
        // own sentence, already written for a human, and folding it into a format
        // string would make one catalog key per feature out of it.
        let asked = String(
            localized: "\(source) asked Crisp to set \(write.feature.spec.title.lowercased()) to \(value)."
        )
        alert.informativeText = asked + "\n\n" + hazard
        // Cancel is added second and made the default: the safe answer is the one
        // a stray Return key presses.
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        // A menu-bar-only app is not frontmost when a link fires; without this the
        // alert can open behind the browser the URL came from.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return UserConsent()
    }

    /// How the dialog names the surface that asked. A confirmation that appears
    /// while the user is reading a web page has to say where it came from, or the
    /// only sensible answer to it is Cancel.
    private static func label(for origin: AutomationOrigin) -> String {
        switch origin {
        case .url: return String(localized: "a crisp:// link")
        case .appIntent: return String(localized: "a shortcut")
        case .hotkey: return String(localized: "a keyboard shortcut")
        case .panel: return String(localized: "a preset")
        case .schedule: return String(localized: "a scheduled preset")
        }
    }
}

extension Notification.Name {
    /// Posted by `AutomationService.refreshDisplays()`; `AppDelegate` owns the
    /// `DisplayManager` that answers it.
    static let crispAutomationRefreshDisplays = Notification.Name("crisp.automationRefreshDisplays")
}
