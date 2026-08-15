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

    // MARK: - Persistence (per displayUUID)

    private func key(_ uuid: String, _ field: String) -> String { "crisp.ddcState.\(uuid).\(field)" }

    func savedBrightness(for uuid: String) -> Double? {
        let k = key(uuid, "brightness")
        guard UserDefaults.standard.object(forKey: k) != nil else { return nil }
        return UserDefaults.standard.double(forKey: k)
    }

    func persistBrightness(_ percent: Double, for display: DisplayInfo) {
        UserDefaults.standard.set(max(0.0, min(100.0, percent)), forKey: key(display.displayUUID, "brightness"))
    }

    func savedContrast(for uuid: String) -> Double? {
        let k = key(uuid, "contrast")
        guard UserDefaults.standard.object(forKey: k) != nil else { return nil }
        return UserDefaults.standard.double(forKey: k)
    }

    func savedVolume(for uuid: String) -> Double? {
        let k = key(uuid, "volume")
        guard UserDefaults.standard.object(forKey: k) != nil else { return nil }
        return UserDefaults.standard.double(forKey: k)
    }

    func savedInput(for uuid: String) -> UInt16? {
        let k = key(uuid, "input")
        guard UserDefaults.standard.object(forKey: k) != nil else { return nil }
        return UInt16(UserDefaults.standard.double(forKey: k))
    }

    /// Re-apply saved input source on reconnect. Off by default: an input
    /// switch blanks the screen for a moment and a stale saved code could
    /// point at a port with nothing plugged in.
    func reapplyInputEnabled(for uuid: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(uuid, "reapplyInput"))
    }

    func setReapplyInput(_ enabled: Bool, for display: DisplayInfo) {
        UserDefaults.standard.set(enabled, forKey: key(display.displayUUID, "reapplyInput"))
    }

    /// Persist a user-driven volume change (called from VolumeService.setVolume).
    func persistVolume(_ percent: Double, for display: DisplayInfo) {
        UserDefaults.standard.set(max(0.0, min(100.0, percent)), forKey: key(display.displayUUID, "volume"))
    }

    /// Drop per-display state for a disconnected display so a reused
    /// displayID cannot inherit it. Saved per-UUID state stays (that's the point).
    func invalidate(for displayID: CGDirectDisplayID) {
        contrastMax.removeValue(forKey: displayID)
        pendingContrast.removeValue(forKey: displayID)
        contrastPumpActive.remove(displayID)
    }

    // MARK: - Contrast

    /// Reads VCP 0x12 once. Success marks the monitor contrast-capable and
    /// adopts its current level; failure leaves the slider hidden. Safe to
    /// re-run on every display refresh (DDCService caches reads for 5s).
    func refreshContrast(for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        let id = display.displayID
        DDCService.shared.readAsync(displayID: id, command: DDCService.contrastVCP) { result in
            Task { @MainActor in
                guard let result, result.max > 0 else { return }
                self.contrastMax[id] = result.max
                display.contrastSupported = true
                // Adopt hardware level only while our writer is idle, so a stale
                // cached read never fights an in-flight drag.
                if self.pendingContrast[id] == nil, !self.contrastPumpActive.contains(id) {
                    display.contrast = Double(result.current) / Double(result.max) * 100.0
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
        UserDefaults.standard.set(percent, forKey: key(display.displayUUID, "contrast"))
    }

    private func pumpContrast(for id: CGDirectDisplayID) {
        guard !contrastPumpActive.contains(id), let percent = pendingContrast.removeValue(forKey: id) else { return }
        contrastPumpActive.insert(id)
        let raw = UInt16((percent / 100.0 * Double(contrastMax[id] ?? 100)).rounded())
        DDCService.shared.writeAsync(displayID: id, command: DDCService.contrastVCP, value: raw) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)  // MCCS write spacing
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
    /// inputLabel(for:). Not re-applied on reconnect unless the per-display
    /// "reapply input" toggle is on (stale codes blank the screen).
    func setInputSource(_ value: UInt16, for display: DisplayInfo) {
        guard display.inputSourceSupported else { return }
        display.inputSource = value
        UserDefaults.standard.set(Double(value), forKey: key(display.displayUUID, "input"))
        DDCService.shared.writeAsync(displayID: display.displayID, command: 0x60, value: value)
    }

    // MARK: - Reconnect re-application

    /// Called after a display (re)connects and DDC has settled. Re-applies
    /// saved brightness/contrast/volume, and input if that toggle is on.
    /// Skips values that are already within a small deadband of the hardware,
    /// so a monitor that remembers its own settings gets no writes at all.
    func reapplyDDCStateIfNeeded(for display: DisplayInfo) {
        guard SettingsService.shared.reapplyDDCOnReconnect, !display.isBuiltin else { return }
        let uuid = display.displayUUID
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

    // MARK: - Input labels (VESA MCCS 0x60 value table)

    static func inputLabel(for value: UInt16) -> String {
        switch value {
        case 0x01: return "VGA-1"
        case 0x02: return "VGA-2"
        case 0x03: return "DVI-1"
        case 0x04: return "DVI-2"
        case 0x05: return "Composite-1"
        case 0x06: return "Composite-2"
        case 0x07: return "S-Video-1"
        case 0x08: return "S-Video-2"
        case 0x09: return "Tuner-1"
        case 0x0A: return "Tuner-2"
        case 0x0B: return "Tuner-3"
        case 0x0C...0x13: return "DVI-\(value - 0x0C + 3)"
        case 0x14...0x1D: return "DisplayPort-\(value - 0x14 + 1)"
        case 0x20...0x2F: return "HDMI-\(value - 0x20 + 1)"
        case 0x30...0x3F: return "USB-C-\(value - 0x30 + 1)"
        default: return String(value)
        }
    }

    /// The common inputs shown in the menu. The current code is always listed
    /// first with its label so a monitor with a nonstandard code (several
    /// BenQ models use their own numbering) is still selectable.
    static func inputMenuItems(current: UInt16) -> [(value: UInt16, label: String)] {
        var items: [(UInt16, String)] = [(current, inputLabel(for: current))]
        let common: [UInt16] = [0x14, 0x15, 0x16, 0x17, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31]
        for v in common where v != current {
            items.append((v, inputLabel(for: v)))
        }
        return items
    }
}
