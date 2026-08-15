import Foundation
import CoreGraphics

/// DDC hardware controls beyond brightness that BetterDisplay users expect:
/// contrast (VCP 0x12), input-source switching (VCP 0x60), plus per-display
/// persistence of DDC brightness/contrast/volume/input with re-application on
/// reconnect.
///
/// **Generic over `DDCFeatureRegistry`, not over four hard-coded features.** The
/// VCP code, the default range, the MCCS access and whether a write is
/// destructive all come from the registry, and the per-feature state below is
/// keyed by `(display, feature)`, so adding a VCP code adds no state, no read
/// path and no write path — only a registry entry. Contrast is the worked
/// example: `refreshContrast` / `setContrast` are four lines of adapter over the
/// generic probe-and-pump, and the only per-feature part left is which
/// `DisplayInfo` property SwiftUI observes.
///
/// What a feature is *allowed* to do is not decided here: `DDCFeatureDiscovery`
/// owns the ladder (user override → quirks database → live probe → capabilities
/// string → MCCS default) and the write gate. **Both** write paths below go
/// through it — `writeFeature` for a raw code, and the percent pump for a
/// slider — and neither can reach the transport without an
/// `ApprovedWrite`, so anything unproven and anything destructive the user did
/// not ask for is refused before it is framed.
///
/// Which is why the contrast adapter takes an `authorization` argument that
/// looks redundant for contrast: VCP 0x0C is percent-shaped *and* destructive,
/// so copying `setContrast` for a colour-temperature slider must not be a way to
/// get a destructive write onto the bus unconfirmed. Copy the shape, thread the
/// authorization from the caller, and the gate does the rest.
///
/// Everything here goes through DDCService's IOKit-only DDC/CI path — the same
/// checksum-validated, retried, quarantine-protected channel used by
/// brightness and volume. No private frameworks, no WindowServer interaction.
///
/// Persistence is keyed by DisplayInfo.displayUUID (stable across reconnects),
/// never by the volatile CGDirectDisplayID (see GammaPersistenceKey, issue #32).
@MainActor
final class DDCFeatureService: ObservableObject {
    static let shared = DDCFeatureService()

    private init() {
        // Persist user-driven external brightness changes (slider, keys,
        // presets) per stable UUID so reconnect reapply can restore them.
        NotificationCenter.default.addObserver(
            forName: .crispExternalManualAdjust, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let displayID = note.userInfo?["displayID"] as? CGDirectDisplayID,
                      let value = note.userInfo?["value"] as? Double,
                      let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID })
                else { return }
                self.persistBrightness(min(value, 100.0), for: display)
            }
        }
    }

    // MARK: - State (per display + feature)

    /// One feature on one display: the key every per-feature dictionary below
    /// uses, so adding a VCP code adds no state of its own.
    private struct FeatureKey: Hashable {
        let display: CGDirectDisplayID
        let feature: DDCFeatureID

        init(_ display: CGDirectDisplayID, _ feature: DDCFeatureID) {
            self.display = display
            self.feature = feature
        }
    }

    /// Raw DDC maximum per display and feature (usually 100), from the probe read.
    private var featureMax: [FeatureKey: UInt16] = [:]
    /// Whether a probe has been attempted and what it said. Distinct from
    /// `featureMax`, which only records successes: "asked and got silence" and
    /// "never asked" are different facts and `DDCFeatureDiscovery` treats them as
    /// such.
    private var probeAnswered: [FeatureKey: Bool] = [:]
    /// One percent-shaped write waiting for the pump.
    ///
    /// It carries the gate's inputs, not just the value: the pump is what
    /// actually reaches the monitor, so it re-runs `DDCFeatureDiscovery.approve`
    /// at the wire with the resolution and the authorization that were true when
    /// the user (or the reconnect) asked. Keeping the resolution rather than the
    /// `DisplayInfo` it came from is deliberate — the pump must not hold a
    /// disconnected display alive, and re-resolving at drain time would judge the
    /// write on evidence the caller never saw.
    private struct PendingPercentWrite {
        let percent: Double
        let resolution: DDCFeatureDiscovery.Resolution
        let authorization: DDCFeatureDiscovery.Authorization
    }

    /// Latest pending percent per display and feature; one DDC write in flight each.
    private var pending: [FeatureKey: PendingPercentWrite] = [:]
    private var pumpActive: Set<FeatureKey> = []
    /// Quirk row for each connected display, captured on probe. Cached here
    /// because the write pump only has a `CGDirectDisplayID` to work from, and
    /// because the lookup answer cannot change while a display stays connected.
    private var quirksByDisplay: [CGDirectDisplayID: MonitorQuirks] = [:]
    /// Parsed capabilities string per display, when one has been read. Never read
    /// on the normal refresh path — see `refreshCapabilities(for:)`.
    private var capabilitiesByDisplay: [CGDirectDisplayID: DDCCapabilities] = [:]

    /// MCCS's recommended spacing between consecutive writes, used unless a
    /// monitor's quirk row says it needs more.
    private static let standardWriteDelayMs = 50

    /// The pump's inter-write pause in nanoseconds, computed without trapping.
    ///
    /// `delayMs` originates in a contributed JSON file, and `UInt64(ms) *
    /// 1_000_000` traps on overflow: a units mix-up in a pull request would take
    /// the app down the first time that monitor's pump ran. Anything that will
    /// not convert degrades to the MCCS spacing instead. Belt and braces — the
    /// decoder already refuses values outside `1...maxWriteDelayMs` — because
    /// only one of the two has to hold for the app to stay up.
    private static func writeDelayNanoseconds(_ delayMs: Int) -> UInt64 {
        let standard = UInt64(standardWriteDelayMs) * 1_000_000
        guard let ms = UInt64(exactly: delayMs) else { return standard }
        let (nanoseconds, overflow) = ms.multipliedReportingOverflow(by: 1_000_000)
        return overflow ? standard : nanoseconds
    }

    // MARK: - Persistence (per displayUUID)

    /// All of it lives in DisplayStateStore's versioned document; this service
    /// only decides *what* is worth remembering, never how it is stored.
    private var store: DisplayStateStore { .shared }

    func savedBrightness(for uuid: DisplayUUID) -> Double? {
        store.state(for: uuid).brightness
    }

    func persistBrightness(_ percent: Double, for display: DisplayInfo) {
        store.update(display.stateUUID) { $0.brightness = max(0.0, min(100.0, percent)) }
    }

    func savedContrast(for uuid: DisplayUUID) -> Double? {
        store.state(for: uuid).contrast
    }

    func savedVolume(for uuid: DisplayUUID) -> Double? {
        store.state(for: uuid).volume
    }

    func savedInput(for uuid: DisplayUUID) -> UInt16? {
        store.state(for: uuid).input
    }

    /// Re-apply saved input source on reconnect. Off by default: an input
    /// switch blanks the screen for a moment and a stale saved code could
    /// point at a port with nothing plugged in.
    func reapplyInputEnabled(for uuid: DisplayUUID) -> Bool {
        store.state(for: uuid).reapplyInputOnReconnect ?? false
    }

    func setReapplyInput(_ enabled: Bool, for display: DisplayInfo) {
        store.update(display.stateUUID) { $0.reapplyInputOnReconnect = enabled }
    }

    /// Persist a user-driven volume change (called from VolumeService.setVolume).
    func persistVolume(_ percent: Double, for display: DisplayInfo) {
        store.update(display.stateUUID) { $0.volume = max(0.0, min(100.0, percent)) }
    }

    /// Drop per-display state for a disconnected display so a reused
    /// displayID cannot inherit it. Saved per-UUID state stays (that's the point).
    func invalidate(for displayID: CGDirectDisplayID) {
        featureMax = featureMax.filter { $0.key.display != displayID }
        probeAnswered = probeAnswered.filter { $0.key.display != displayID }
        pending = pending.filter { $0.key.display != displayID }
        pumpActive = pumpActive.filter { $0.display != displayID }
        quirksByDisplay.removeValue(forKey: displayID)
        capabilitiesByDisplay.removeValue(forKey: displayID)
    }

    // MARK: - Quirks

    /// The shipped quirk row for this monitor, or `nil` for a model nobody has
    /// contributed yet — in which case every call site falls back to what the
    /// monitor reports and then to the MCCS defaults, exactly as before.
    @discardableResult
    private func quirks(for display: DisplayInfo) -> MonitorQuirks? {
        let quirks = MonitorQuirksService.shared.quirks(
            vendor: display.vendorNumber, product: display.modelNumber
        )
        quirksByDisplay[display.displayID] = quirks
        return quirks
    }

    /// Raw range to write into for a percent-shaped feature, resolved database →
    /// probe → MCCS. The database outranks the probe deliberately: a monitor that
    /// misreports its own maximum is the reason the database exists.
    private func range(of feature: DDCFeatureID, for id: CGDirectDisplayID) -> QuirkRange {
        MonitorQuirkResolver.range(
            feature,
            quirks: quirksByDisplay[id],
            probeMax: featureMax[FeatureKey(id, feature)],
            standard: standardRange(of: feature)
        ).value
    }

    /// The MCCS default range for a feature, from its registry entry. Every
    /// continuous feature seeded so far is 0–100, which is what `.mccsPercent`
    /// already meant; taking it from the registry is what makes a future feature
    /// with a different default a data change rather than a code change.
    private func standardRange(of feature: DDCFeatureID) -> QuirkRange {
        guard case .continuous(let defaultMax) = feature.spec.kind,
              let range = QuirkRange(min: 0, max: defaultMax) else { return .mccsPercent }
        return range
    }

    // MARK: - Percent-shaped features (the generic read/write path)

    /// Reads a percent-shaped feature once and adopts what the monitor reports.
    ///
    /// The whole of what used to be `refreshContrast`, with the VCP code, the
    /// default range and the state keys coming from the registry instead of being
    /// spelled out. `markSupported` and `adopt` are the only per-feature parts
    /// left, because `DisplayInfo` publishes one named property per control and
    /// SwiftUI needs it to.
    private func refreshPercentFeature(
        _ feature: DDCFeatureID,
        for display: DisplayInfo,
        markSupported: @escaping @MainActor () -> Void,
        adopt: @escaping @MainActor (Double) -> Void
    ) {
        guard !display.isBuiltin else { return }
        let id = display.displayID
        let key = FeatureKey(id, feature)
        quirks(for: display)
        DDCService.shared.readAsync(displayID: id, command: feature.spec.vcp) { result in
            Task { @MainActor in
                // Recorded whatever the answer was: discovery needs "asked and
                // got silence" to be distinguishable from "never asked".
                self.probeAnswered[key] = result != nil
                guard let result, result.max > 0 else { return }
                self.featureMax[key] = result.max
                markSupported()
                // Adopt hardware level only while our writer is idle, so a stale
                // cached read never fights an in-flight drag.
                if self.pending[key] == nil, !self.pumpActive.contains(key) {
                    adopt(self.range(of: feature, for: id).percent(forRaw: result.current))
                }
            }
        }
    }

    /// Queues a percent for a feature and starts its write pump, subject to the
    /// one gate. Coalesced like the brightness/volume writers: latest value wins,
    /// writes paced to the MCCS ~50ms spacing so slider drags don't flood the I2C
    /// bus brightness shares.
    ///
    /// The authorization is the caller's to supply and cannot be defaulted: a
    /// percent-shaped feature is not the same as a harmless one. VCP 0x0C
    /// (colour temperature) is continuous *and* destructive, so an adapter for it
    /// has to thread `.userConfirmed` down from the app's one confirmation dialog
    /// exactly as `setInputSource` does — passing `.automatic` gets it refused
    /// here rather than putting it on the bus.
    @discardableResult
    private func setPercentFeature(
        _ feature: DDCFeatureID,
        _ percent: Double,
        for display: DisplayInfo,
        authorization: DDCFeatureDiscovery.Authorization
    ) -> DDCFeatureDiscovery.WriteDecision {
        // The one thing the gate below cannot express: a percent adapter is for
        // percent-shaped codes. Driving a non-continuous code through it would
        // scale an enumeration — VCP 0x60's `19` is a port, not 19% of anything.
        // A programmer error, never reachable from monitor or user data.
        precondition(
            feature.spec.kind.isContinuous,
            "\(feature.rawValue) is not percent-shaped; write it with writeFeature(_:raw:for:authorization:)"
        )
        let resolution = availability(of: feature, for: display)
        let decision = DDCFeatureDiscovery.authorize(
            feature.spec, resolution: resolution, authorization: authorization
        )
        guard decision.isAllowed else { return decision }
        pending[FeatureKey(display.displayID, feature)] = PendingPercentWrite(
            percent: percent, resolution: resolution, authorization: authorization
        )
        pump(feature, for: display.displayID)
        return decision
    }

    private func pump(_ feature: DDCFeatureID, for id: CGDirectDisplayID) {
        let key = FeatureKey(id, feature)
        guard !pumpActive.contains(key), let queued = pending.removeValue(forKey: key) else { return }
        let raw = range(of: feature, for: id).raw(forPercent: queued.percent)
        // The gate at the wire, not just at the slider, because this is the code
        // that talks to the monitor: the only value that may go out is the one an
        // approval carries. A refusal here means the queued write no longer holds
        // — drop it, exactly as an unsupported feature's write has always been
        // dropped, and leave the pump idle for the next one.
        guard case .approved(let write) = DDCFeatureDiscovery.approve(
            feature.spec, value: raw,
            resolution: queued.resolution, authorization: queued.authorization
        ) else { return }
        pumpActive.insert(key)
        // Monitors that need more than the MCCS spacing say so in their quirk row.
        let delayMs = MonitorQuirkResolver.writeDelayMs(
            quirks: quirksByDisplay[id], standard: Self.standardWriteDelayMs
        )
        DDCService.shared.writeAsync(displayID: id, command: write.vcp, value: write.value) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.writeDelayNanoseconds(delayMs))
                self.pumpActive.remove(key)
                self.pump(feature, for: id)
            }
        }
    }

    // MARK: - Contrast

    /// Reads VCP 0x12 once. Success marks the monitor contrast-capable and
    /// adopts its current level; failure leaves the slider hidden. Safe to
    /// re-run on every display refresh (DDCService caches reads for 5s).
    func refreshContrast(for display: DisplayInfo) {
        refreshPercentFeature(
            .contrast, for: display,
            markSupported: { display.contrastSupported = true },
            adopt: { display.contrast = $0 }
        )
    }

    /// Sets contrast (0–100).
    ///
    /// `.automatic` covers both callers — the slider and the reconnect reapply —
    /// because VCP 0x12 is not destructive, so the gate asks only that this
    /// monitor is proved to have it (which `display.contrastSupported` already
    /// implies). A destructive percent feature could not share one adapter like
    /// this: it would have to take its authorization from whichever caller it is.
    func setContrast(_ percent: Double, for display: DisplayInfo) {
        guard display.contrastSupported else { return }
        let clamped = max(0.0, min(100.0, percent))
        display.contrast = clamped
        persistContrast(clamped, for: display)
        setPercentFeature(.contrast, clamped, for: display, authorization: .automatic)
    }

    private func persistContrast(_ percent: Double, for display: DisplayInfo) {
        store.update(display.stateUUID) { $0.contrast = percent }
    }

    // MARK: - Input source

    /// Reads VCP 0x60 once. Success marks the monitor input-switch-capable
    /// and adopts the current input code.
    ///
    /// It is also where an interrupted calibration is repaired. This runs at
    /// launch and on every reconnect (see `DisplayManager.refreshDisplays`),
    /// which are exactly the two moments a monitor left on an unconfirmed input
    /// by a crashed or killed app becomes reachable again — so the restore rides
    /// the read that discovers the state it has to repair, rather than needing a
    /// second, separately-scheduled pass.
    func refreshInputSource(for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        let id = display.displayID
        let key = FeatureKey(id, .input)
        quirks(for: display)
        DDCService.shared.readAsync(displayID: id, command: DDCFeatureID.input.spec.vcp) { result in
            Task { @MainActor in
                self.probeAnswered[key] = result != nil
                if let result, result.max > 0 || result.current > 0 {
                    display.inputSourceSupported = true
                    display.inputSourceMax = result.max
                    display.inputSource = result.current
                }
                // Deliberately outside the guard: a read that answered nothing is
                // exactly what a panel sitting on a dead input looks like, and
                // that is the case the repair exists for. `restoreIfInterrupted`
                // is a no-op unless a pending record is on disk for this display.
                InputCalibrationService.shared.restoreIfInterrupted(
                    for: display, currentInput: result?.current
                )
            }
        }
    }

    /// Switches the monitor's input. Raw VCP 0x60 value; labels live in
    /// `resolvedInput(_:for:)`. Not re-applied on reconnect unless the
    /// per-display "reapply input" toggle is on (stale codes blank the screen).
    ///
    /// The confirmation gate is the *caller's* job (see `InputSourceMenuRow`):
    /// this method is also how a confirmed switch is finally performed, so it
    /// cannot refuse unverified codes itself. Saving the code as the user's own
    /// choice is what later promotes it to the user-override tier — a code the
    /// user picked and whose screen came back is the best evidence there is.
    ///
    /// Which is why nothing is recorded until the monitor acks the write. A
    /// transient I²C failure must not promote an unverified code to the
    /// no-confirmation tier for every future selection and for the opt-in
    /// reapply-on-reconnect path: that would be evidence the app invented.
    func setInputSource(_ value: UInt16, for display: DisplayInfo) {
        guard display.inputSourceSupported else { return }
        let uuid = display.stateUUID
        // Through the registry's write gate like every other destructive feature,
        // declared `.userConfirmed` because both callers are the user's own
        // choice: the menu (which asks first for any code the resolver cannot
        // vouch for) and the opt-in reconnect reapply of a code this user picked
        // and whose screen came back.
        writeFeature(.input, raw: value, for: display, authorization: .userConfirmed) { acked in
            guard acked else { return }
            Task { @MainActor in
                // `inputSource` feeds `MonitorQuirkResolver.input`'s "the monitor
                // is on this right now" tier, so it moves on the same evidence.
                display.inputSource = value
                self.store.update(uuid) { $0.input = value }
            }
        }
    }

    // MARK: - Registry features

    /// Reads the monitor's capabilities string and remembers it for this display.
    ///
    /// Never on the display-refresh path: twenty-odd extra I2C transactions on
    /// the bus brightness shares, for information nothing is allowed to act on by
    /// itself (`DDCFeatureDiscovery` lets it widen what is offered, never narrow
    /// it). Called where a human asked — the diagnostics sheet — and by
    /// `crispctl capabilities`.
    @discardableResult
    func refreshCapabilities(for display: DisplayInfo) async -> DDCCapabilities? {
        guard !display.isBuiltin else { return nil }
        let capabilities = await DDCService.shared.capabilities(displayID: display.displayID)
        if let capabilities {
            capabilitiesByDisplay[display.displayID] = capabilities
        }
        return capabilities
    }

    /// The capabilities string already read for this display, if any.
    func capabilities(for display: DisplayInfo) -> DDCCapabilities? {
        capabilitiesByDisplay[display.displayID]
    }

    /// What is known about one registry feature on one display, as evidence.
    ///
    /// The four established features report through the flags the UI already
    /// gates on, so the discovery rule and the panel cannot disagree; everything
    /// else reports through the probe bookkeeping above.
    func evidence(for feature: DDCFeatureID, on display: DisplayInfo) -> DDCFeatureDiscovery.Evidence {
        let key = FeatureKey(display.displayID, feature)
        var answered = probeAnswered[key]
        switch feature {
        case .contrast where display.contrastSupported: answered = true
        case .volume where display.volumeSupported: answered = true
        case .input where display.inputSourceSupported: answered = true
        default: break
        }
        return DDCFeatureDiscovery.Evidence(
            quirk: quirks(for: display)?.feature(feature),
            probeAnswered: answered,
            capabilitiesAdvertises: capabilitiesByDisplay[display.displayID].map {
                $0.advertises(feature.spec.vcp)
            }
        )
    }

    /// Whether this display has the feature, on what evidence, and whether it may
    /// be written. See `DDCFeatureDiscovery` for the rule itself.
    func availability(
        of feature: DDCFeatureID, for display: DisplayInfo
    ) -> DDCFeatureDiscovery.Resolution {
        DDCFeatureDiscovery.resolve(feature.spec, evidence: evidence(for: feature, on: display))
    }

    /// Reads any registry feature once, raw. Reads are always allowed: the write
    /// gate exists because a wrong write costs the user something, and a read
    /// costs one I2C transaction.
    func readFeature(_ feature: DDCFeatureID, for display: DisplayInfo) async -> RawProbe? {
        guard !display.isBuiltin, feature.spec.access.canRead, feature.spec.isKnown else { return nil }
        let key = FeatureKey(display.displayID, feature)
        let displayID = display.displayID
        let vcp = feature.spec.vcp
        let result: (current: UInt16, max: UInt16)? = await withCheckedContinuation { continuation in
            DDCService.shared.readAsync(displayID: displayID, command: vcp) { continuation.resume(returning: $0) }
        }
        probeAnswered[key] = result != nil
        if let result, result.max > 0 { featureMax[key] = result.max }
        return result.map { RawProbe(current: $0.current, max: $0.max) }
    }

    /// Writes any registry feature, subject to the one gate.
    ///
    /// Returns the decision rather than a Bool so a refusal carries its reason to
    /// wherever it needs to be shown. `completion` reports whether the monitor
    /// acked; a refused write never reaches the bus and completes `false`.
    ///
    /// The code and the value handed to the transport come off the approval
    /// token, not off `feature` — see `DDCFeatureDiscovery.ApprovedWrite` for why
    /// both write paths in this file are built that way.
    @discardableResult
    func writeFeature(
        _ feature: DDCFeatureID,
        raw: UInt16,
        for display: DisplayInfo,
        authorization: DDCFeatureDiscovery.Authorization,
        completion: ((Bool) -> Void)? = nil
    ) -> DDCFeatureDiscovery.WriteDecision {
        let approval = DDCFeatureDiscovery.approve(
            feature.spec,
            value: raw,
            resolution: availability(of: feature, for: display),
            authorization: authorization
        )
        guard case .approved(let write) = approval else {
            completion?(false)
            return approval.decision
        }
        DDCService.shared.writeAsync(displayID: display.displayID, command: write.vcp, value: write.value) { acked in
            completion?(acked)
        }
        return approval.decision
    }

    // MARK: - Reconnect re-application

    /// Called after a display (re)connects and DDC has settled. Re-applies
    /// saved brightness/contrast/volume, and input if that toggle is on.
    /// Skips values that are already within a small deadband of the hardware,
    /// so a monitor that remembers its own settings gets no writes at all.
    func reapplyDDCStateIfNeeded(for display: DisplayInfo) {
        guard SettingsService.shared.reapplyDDCOnReconnect, !display.isBuiltin else { return }
        let uuid = display.stateUUID
        if let saved = savedBrightness(for: uuid), abs(saved - display.brightness) >= 1.0 {
            Task { await BrightnessService.shared.setBrightness(saved, for: display) }
        }
        if let saved = savedContrast(for: uuid), display.contrastSupported,
           abs(saved - display.contrast) >= 1.0 {
            setContrast(saved, for: display)
        }
        if let saved = savedVolume(for: uuid), display.volumeSupported,
           abs(saved - display.volume) >= 1.0 {
            VolumeService.shared.setVolume(saved, for: display)
            display.volume = saved
        }
        if reapplyInputEnabled(for: uuid), let saved = savedInput(for: uuid),
           display.inputSourceSupported, saved != display.inputSource {
            setInputSource(saved, for: display)
        }
    }

    // MARK: - Input labels

    /// Resolves one input code for this display: user override → quirks database
    /// → live probe → MCCS table (`MonitorQuirkResolver.input`). The result
    /// carries both the label and whether writing the code needs confirmation.
    func resolvedInput(_ code: UInt16, for display: DisplayInfo) -> ResolvedInput {
        MonitorQuirkResolver.input(
            code: code,
            quirks: quirks(for: display),
            currentInput: display.inputSourceSupported ? display.inputSource : nil,
            userSelectedInput: savedInput(for: display.stateUUID),
            calibrated: InputCalibrationService.shared.calibratedLabels(for: display.stateUUID)
        )
    }

    /// What the panel shows next to "Input Source". A label the database only
    /// has second-hand keeps its question mark — the app never states a guess
    /// as fact.
    func inputLabel(for display: DisplayInfo) -> String {
        resolvedInput(display.inputSource, for: display).displayLabel
    }

    /// The inputs offered in the menu. The current code is always first (always
    /// selectable, since selecting it is a no-op); then whatever the database
    /// knows about this exact model; and only for a monitor nobody has
    /// contributed yet, the common VESA codes as a guess.
    func inputOptions(for display: DisplayInfo) -> [ResolvedInput] {
        MonitorQuirkResolver.inputOptions(
            quirks: quirks(for: display),
            currentInput: display.inputSource,
            userSelectedInput: savedInput(for: display.stateUUID),
            calibrated: InputCalibrationService.shared.calibratedLabels(for: display.stateUUID)
        )
    }
}
