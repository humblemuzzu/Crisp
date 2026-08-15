import Foundation
import CoreGraphics

/// DDC hardware controls beyond brightness that BetterDisplay users expect:
/// contrast (VCP 0x12), input-source switching (VCP 0x60), plus per-display
/// persistence of DDC brightness/contrast/volume/input with re-application on
/// reconnect.
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

    // MARK: - State (per displayID)

    /// Raw DDC max contrast per display (usually 100), from the probe read.
    private var contrastMax: [CGDirectDisplayID: UInt16] = [:]
    /// Latest pending contrast percent per display; one DDC write in flight each.
    private var pendingContrast: [CGDirectDisplayID: Double] = [:]
    private var contrastPumpActive: Set<CGDirectDisplayID> = []
    /// Quirk row for each connected display, captured on probe. Cached here
    /// because the write pump only has a `CGDirectDisplayID` to work from, and
    /// because the lookup answer cannot change while a display stays connected.
    private var quirksByDisplay: [CGDirectDisplayID: MonitorQuirks] = [:]

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
        contrastMax.removeValue(forKey: displayID)
        pendingContrast.removeValue(forKey: displayID)
        contrastPumpActive.remove(displayID)
        quirksByDisplay.removeValue(forKey: displayID)
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

    /// Raw contrast range to write into, resolved database → probe → MCCS.
    /// The database outranks the probe deliberately: a monitor that misreports
    /// its own maximum is the reason the database exists.
    private func contrastRange(for id: CGDirectDisplayID) -> QuirkRange {
        MonitorQuirkResolver.range(
            .contrast,
            quirks: quirksByDisplay[id],
            probeMax: contrastMax[id],
            standard: .mccsPercent
        ).value
    }

    // MARK: - Contrast

    /// Reads VCP 0x12 once. Success marks the monitor contrast-capable and
    /// adopts its current level; failure leaves the slider hidden. Safe to
    /// re-run on every display refresh (DDCService caches reads for 5s).
    func refreshContrast(for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        let id = display.displayID
        quirks(for: display)
        DDCService.shared.readAsync(displayID: id, command: DDCService.contrastVCP) { result in
            Task { @MainActor in
                guard let result, result.max > 0 else { return }
                self.contrastMax[id] = result.max
                display.contrastSupported = true
                // Adopt hardware level only while our writer is idle, so a stale
                // cached read never fights an in-flight drag.
                if self.pendingContrast[id] == nil, !self.contrastPumpActive.contains(id) {
                    display.contrast = self.contrastRange(for: id).percent(forRaw: result.current)
                }
            }
        }
    }

    /// Sets contrast (0–100). Coalesced like the brightness/volume writers:
    /// latest value wins, writes paced to the MCCS ~50ms spacing so slider
    /// drags don't flood the I2C bus that brightness shares.
    func setContrast(_ percent: Double, for display: DisplayInfo) {
        guard display.contrastSupported else { return }
        let clamped = max(0.0, min(100.0, percent))
        display.contrast = clamped
        persistContrast(clamped, for: display)
        pendingContrast[display.displayID] = clamped
        pumpContrast(for: display.displayID)
    }

    private func persistContrast(_ percent: Double, for display: DisplayInfo) {
        store.update(display.stateUUID) { $0.contrast = percent }
    }

    private func pumpContrast(for id: CGDirectDisplayID) {
        guard !contrastPumpActive.contains(id), let percent = pendingContrast.removeValue(forKey: id) else { return }
        contrastPumpActive.insert(id)
        let raw = contrastRange(for: id).raw(forPercent: percent)
        // Monitors that need more than the MCCS spacing say so in their quirk row.
        let delayMs = MonitorQuirkResolver.writeDelayMs(
            quirks: quirksByDisplay[id], standard: Self.standardWriteDelayMs
        )
        DDCService.shared.writeAsync(displayID: id, command: DDCService.contrastVCP, value: raw) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.writeDelayNanoseconds(delayMs))
                self.contrastPumpActive.remove(id)
                self.pumpContrast(for: id)
            }
        }
    }

    // MARK: - Input source

    /// Reads VCP 0x60 once. Success marks the monitor input-switch-capable
    /// and adopts the current input code.
    func refreshInputSource(for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        let id = display.displayID
        quirks(for: display)
        DDCService.shared.readAsync(displayID: id, command: 0x60) { result in
            Task { @MainActor in
                guard let result, result.max > 0 || result.current > 0 else { return }
                display.inputSourceSupported = true
                display.inputSourceMax = result.max
                display.inputSource = result.current
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
        DDCService.shared.writeAsync(displayID: display.displayID, command: 0x60, value: value) { acked in
            guard acked else { return }
            Task { @MainActor in
                // `inputSource` feeds `MonitorQuirkResolver.input`'s "the monitor
                // is on this right now" tier, so it moves on the same evidence.
                display.inputSource = value
                self.store.update(uuid) { $0.input = value }
            }
        }
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
            userSelectedInput: savedInput(for: display.stateUUID)
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
            userSelectedInput: savedInput(for: display.stateUUID)
        )
    }
}
