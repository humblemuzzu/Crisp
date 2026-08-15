import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics
// For CGDisplayCreateUUIDFromDisplayID (ApplicationServices, not CoreGraphics).
import AppKit

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// DisplayServices private framework, built-in panel brightness on Apple Silicon,
// where IODisplayConnect no longer exists (CoreDisplay_Display_SetUserBrightness
// is also a no-op there). Loaded via dlsym, same pattern as AutoBrightnessService.
private let _DSSetBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
}()
private let _DSGetBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()

// DisplayServices brightness-change notifications: push updates so the UI tracks the
// built-in panel live (native keys, auto-brightness, Night Shift/TrueTone) instead of
// only refreshing on panel-open/wake/reconfigure. Signatures verified against SketchyBar
// (src/misc/extern.h + src/display.c): register(did, passthrough, callback) plus a 5-arg
// callback (passthrough, did, name, sender, info); brightness is not passed, it's read
// back via DisplayServicesGetBrightness.
private typealias DSBrightnessChangeHandler = @convention(c) (
    UnsafeMutableRawPointer?, CGDirectDisplayID,
    UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
) -> Void

private let _DSRegisterBrightnessChange: (@convention(c) (CGDirectDisplayID, UInt32, DSBrightnessChangeHandler) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesRegisterForBrightnessChangeNotifications") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UInt32, DSBrightnessChangeHandler) -> Int32).self)
}()
private let _DSUnregisterBrightnessChange: (@convention(c) (CGDirectDisplayID, UInt32) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesUnregisterForBrightnessChangeNotifications") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UInt32) -> Int32).self)
}()

/// C callback fired when a display's brightness changes from any source. Brightness is
/// not a parameter (per the reverse-engineered API), so we read it back and push it onto
/// the matching DisplayInfo on the main actor. Must be a capture-free top-level function
/// to be usable as a @convention(c) pointer.
private func _crispBuiltinBrightnessChanged(
    _ passthrough: UnsafeMutableRawPointer?,
    _ did: CGDirectDisplayID,
    _ name: UnsafeMutableRawPointer?,
    _ sender: UnsafeRawPointer?,
    _ info: UnsafeRawPointer?
) {
    guard let get = _DSGetBrightness else { return }
    var v: Float = 0
    guard get(did, &v) == 0 else { return }
    let value = Double(v) * 100.0
    Task { @MainActor in
        guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == did })
        else { return }
        guard display.brightness <= 100.0 else { return }
        // Skip sub-0.5% jitter to avoid redundant @Published churn.
        guard abs(display.brightness - value) >= 0.5 else { return }
        display.brightness = value
        // Drive auto-brightness off this live change so external displays follow the
        // built-in immediately instead of trailing its 2s poll. (issue #12 follow-up)
        NotificationCenter.default.post(name: .crispBuiltinBrightnessDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted when the built-in display's brightness changes (keys, ambient auto-brightness).
    static let crispBuiltinBrightnessDidChange = Notification.Name("crisp.builtinBrightnessDidChange")
    /// Posted when the user manually changes an EXTERNAL display's brightness (slider, keys,
    /// preset). userInfo: "displayID" (CGDirectDisplayID), "value" (Double, 0–100).
    static let crispExternalManualAdjust = Notification.Name("crisp.externalManualAdjust")
    /// Posted when the user manually changes the BUILT-IN display's brightness from Crisp.
    /// Distinguishes a deliberate built-in change from the ambient signal auto-brightness follows.
    static let crispBuiltinManualAdjust = Notification.Name("crisp.builtinManualAdjust")
}

// MARK: - BrightnessAnimator

/// Manages smooth brightness transitions for a single display.
/// Cancels any in-progress animation when a new one starts, so rapid presses stay responsive.
/// All methods must be called on the main thread.
final class BrightnessAnimator: @unchecked Sendable {
    private var timer: Timer?
    private var currentStep: Int = 0
    private var totalSteps: Int = 0
    private var startValue: Double = 0
    private var targetValue: Double = 0
    private var stepHandler: ((Double, Bool) -> Void)?

    /// Cancel any running animation immediately.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Animate from `from` to `to` over `duration` seconds using `steps` discrete steps.
    /// `handler(value, isLast)` is called once per step on the main thread.
    /// Calling this cancels any previously running animation.
    func animate(
        from: Double,
        to: Double,
        steps: Int,
        duration: TimeInterval,
        handler: @escaping (Double, Bool) -> Void
    ) {
        cancel()

        // If from ≈ to, no animation needed, just apply final value.
        guard abs(to - from) > 0.001, steps > 1 else {
            handler(to, true)
            return
        }

        let clampedSteps = max(2, steps)
        currentStep = 0
        totalSteps = clampedSteps
        startValue = from
        targetValue = to
        stepHandler = handler
        let interval = duration / Double(clampedSteps)

        // .common mode keeps the timer firing during event tracking (menu panel
        // open, scrolling); in .default mode it stalls and the fade looks ~10fps.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.currentStep += 1
            let progress = Double(self.currentStep) / Double(self.totalSteps)
            // Ease-out curve: smoother deceleration at the end
            let eased = 1.0 - pow(1.0 - progress, 2.0)
            let value = self.startValue + (self.targetValue - self.startValue) * eased
            let isLast = self.currentStep >= self.totalSteps
            if isLast {
                t.invalidate()
                self.timer = nil
            }
            // Always pass the exact target on the last step to avoid floating-point drift.
            self.stepHandler?(isLast ? self.targetValue : value, isLast)
            if isLast { self.stepHandler = nil }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

// MARK: - BrightnessService

final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()
    private init() {}

    private let queue = DispatchQueue(label: "com.crisp.brightness", qos: .userInitiated)

    // MARK: - Per-display Animators (main thread only)

    /// One animator per display. Accessed only on the main thread.
    private var animators: [CGDirectDisplayID: BrightnessAnimator] = [:]

    private func animator(for displayID: CGDirectDisplayID) -> BrightnessAnimator {
        if let existing = animators[displayID] { return existing }
        let a = BrightnessAnimator()
        animators[displayID] = a
        return a
    }

    /// Cancel any running brightness animation for a display.
    /// Call this before starting an instant (non-animated) change.
    @MainActor
    func cancelAnimation(for displayID: CGDirectDisplayID) {
        animators[displayID]?.cancel()
    }

    // MARK: - Manual Adjust Cooldown

    /// Set when the user manually adjusts any display's brightness. The menu panel's
    /// external poll skips for a few seconds after this so it doesn't fight a live drag.
    private(set) var lastManualAdjustDate: Date? = nil
    private let manualAdjustLock = NSLock()

    // MARK: - Software Brightness Factors

    /// Stores the current software brightness factor per display (0.01–1.0).
    private var softwareBrightnessFactors: [CGDirectDisplayID: Double] = [:]
    private let softwareBrightnessLock = NSLock()

    /// UUID-keyed like GammaPersistenceKey (issue #32): displayIDs are reused
    /// across reconnects and reboots, so the old raw-ID key could hand this
    /// display's dimming factor to a different physical display later.
    /// nil when the display just went offline and CG can no longer name it.
    private func softBrightnessUUID(for displayID: CGDirectDisplayID) -> DisplayUUID? {
        Self.displayUUIDString(for: displayID).map(DisplayUUID.init)
    }

    private static func legacySoftBrightnessKey(for displayID: CGDirectDisplayID) -> String {
        "crisp.softBrightness_\(displayID)"
    }

    /// Same primary path as DisplayInfo.displayUUID (CG UUID of an online
    /// display), so both produce identical key strings.
    private static func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String?
    }

    /// Moves any legacy, displayID-keyed software-brightness factor onto the
    /// stable UUID key, for every display currently online. Same rules as
    /// GammaService.migrateLegacyStateIfNeeded: repeated calls are no-ops, an
    /// existing UUID entry is never overwritten, and a legacy key with no live
    /// display is left alone (guessing which physical display it belonged to
    /// is exactly the bug being fixed).
    @MainActor
    func migrateLegacySoftBrightnessIfNeeded(for displays: [DisplayInfo]) {
        let defaults = UserDefaults.standard
        for display in displays {
            let legacyKey = Self.legacySoftBrightnessKey(for: display.displayID)
            guard defaults.object(forKey: legacyKey) != nil else { continue }
            let legacyFactor = defaults.double(forKey: legacyKey)
            DisplayStateStore.shared.update(display.stateUUID) { state in
                if state.softwareBrightnessFactor == nil { state.softwareBrightnessFactor = legacyFactor }
            }
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private func saveSoftwareBrightness(factor: Double, for displayID: CGDirectDisplayID) {
        guard let uuid = softBrightnessUUID(for: displayID) else {
            // The display went offline mid-write. Rule #3 forbids keying the
            // store on the volatile displayID, so this one degenerate case still
            // lands in the legacy displayID default — which
            // migrateLegacySoftBrightnessIfNeeded folds into the store under the
            // right UUID the next time the display is online.
            UserDefaults.standard.set(factor, forKey: Self.legacySoftBrightnessKey(for: displayID))
            return
        }
        DisplayStateStore.shared.update(uuid) { $0.softwareBrightnessFactor = factor }
    }

    private func loadSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        guard let uuid = softBrightnessUUID(for: displayID) else {
            let key = Self.legacySoftBrightnessKey(for: displayID)
            guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
            return UserDefaults.standard.double(forKey: key)
        }
        return DisplayStateStore.shared.state(for: uuid).softwareBrightnessFactor
    }

    /// Returns the current software brightness factor for a display, or nil if not set.
    func currentSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
    }

    // MARK: - DDC Availability Cache

    /// Tracks whether hardware DDC is available for each external display.
    /// nil  = not yet determined
    /// true = DDC write succeeded at least once
    /// false = DDC write has failed; use software (gamma) fallback
    private var ddcAvailable: [CGDirectDisplayID: Bool] = [:]
    private let ddcAvailableLock = NSLock()

    /// Per-display DDC max brightness value reported by the monitor.
    /// Used to denormalize 0–100% into the display's native DDC range.
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]

    /// Displays whose transfer-table write CoreGraphics rejected, i.e. where the
    /// gamma rung does not exist either. Guarded by ddcAvailableLock, alongside
    /// the other per-display capability facts the rung is derived from.
    private var gammaRejected: Set<CGDirectDisplayID> = []

    /// What this service currently believes about DDC on one display, for the
    /// diagnostics report: nil = unproven, true = proven, false = given up.
    ///
    /// Read-only, and deliberately the *same* stored value `refreshRung` feeds to
    /// `BrightnessRung.resolve`, so the report cannot disagree with the badge the
    /// user sees on the slider. Also the reason the report can say "unproven"
    /// rather than flattening it to "no": nothing has failed on such a display,
    /// nothing has been tried.
    func ddcAvailability(for displayID: CGDirectDisplayID) -> Bool? {
        ddcAvailableLock.withLock { ddcAvailable[displayID] }
    }

    /// The raw DDC brightness maximum the monitor reported, or nil if no read has
    /// answered yet. Diagnostics only; the write path reads the same dictionary
    /// under the same lock (see `setDDCBrightness`).
    func ddcBrightnessMax(for displayID: CGDirectDisplayID) -> UInt16? {
        ddcAvailableLock.withLock { ddcMaxBrightness[displayID] }
    }

    // MARK: - Brightness Rung (the fallback ladder)

    /// Resolves which rung of the ladder a display is on, records it on the
    /// DisplayInfo (the UI badge observes it), and returns it so the caller can
    /// route its write to the matching mechanism.
    ///
    /// Every input comes from state this service (or the display itself) already
    /// owns, so the badge cannot disagree with what the write path actually does.
    @discardableResult
    @MainActor
    func refreshRung(for display: DisplayInfo) -> BrightnessRung {
        let displayID = display.displayID
        let (available, hdrDimmed, gammaOK) = ddcAvailableLock.withLock {
            (ddcAvailable[displayID], hdrDimmedDisplays.contains(displayID), !gammaRejected.contains(displayID))
        }
        let rung = BrightnessRung.resolve(
            BrightnessRung.Capabilities(
                isOnline: CGDisplayIsOnline(displayID) != 0,
                isBuiltin: display.isBuiltin,
                isVirtual: VirtualDisplayService.shared.isVirtualDisplay(displayID),
                ddcAvailable: available,
                hdrSoftwareDimmed: hdrDimmed,
                gammaWritable: gammaOK,
                hasScreen: NSScreen.screen(for: displayID) != nil
            )
        )
        if display.brightnessRung != rung { display.brightnessRung = rung }
        // A display that climbed back off the overlay rung (HDR off, DDC proven,
        // virtual display destroyed) must not keep a black window over it.
        if case .overlay = rung {} else {
            BrightnessOverlayManager.shared.removeOverlay(for: displayID)
        }
        return rung
    }

    /// Re-resolves the rung from a background callback (DDC write result, gamma
    /// write result), where the DisplayInfo can only be reached on the main actor.
    private func scheduleRungRefresh(for displayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self,
                  let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID })
            else { return }
            self.refreshRung(for: display)
        }
    }

    /// Records whether CoreGraphics accepted a transfer-table write, so a display
    /// that rejects gamma drops to the overlay rung instead of silently doing
    /// nothing. Only a change is published; the write path calls this at drag rate.
    private func noteGammaWriteResult(_ error: CGError, for displayID: CGDirectDisplayID) {
        let rejected = error != .success
        let changed = ddcAvailableLock.withLock { () -> Bool in
            let wasRejected = gammaRejected.contains(displayID)
            guard wasRejected != rejected else { return false }
            if rejected { gammaRejected.insert(displayID) } else { gammaRejected.remove(displayID) }
            return true
        }
        if changed { scheduleRungRefresh(for: displayID) }
    }

    // MARK: - Public API

    /// `animated: true` glides the built-in slider to the freshly-read value
    /// instead of snapping, used by the ~1s poll so an ambient-sensor auto-adjust
    /// reads as smooth motion. Instant (default) on load/wake where the slider
    /// should show the real value immediately.
    @MainActor
    func refreshBrightness(for display: DisplayInfo, animated: Bool = false) async {
        // Recompute the ladder rung on every refresh (panel open, wake,
        // reconfigure), so the badge tracks reality without a poll of its own.
        let rung = refreshRung(for: display)
        // While boosted above 100 the hardware pins at max and reads back ~100;
        // adopting that would snap the slider out of the boost region. Crisp
        // owns the value while Extra Brightness is engaged.
        if display.brightness > 100.0 { return }
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        if isBuiltin {
            let brightness = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    continuation.resume(returning: self?.getInternalBrightness())
                }
            }
            if let b = brightness {
                // macOS already moved the backlight; only the displayed value needs
                // to catch up. Glide it (no hardware write) so the knob doesn't jump
                // between polls. Deadband avoids a perpetual timer on sensor
                // jitter; sub-0.5% moves are imperceptible, so just set them.
                if animated, abs(b - display.brightness) >= 0.5 {
                    animator(for: displayID).animate(
                        from: display.brightness, to: b,
                        steps: max(8, Int(1.0 / 0.008)), duration: 1.0
                    ) { [weak display] value, _ in
                        display?.brightness = value
                    }
                } else {
                    display.brightness = b
                }
            }
        } else {
            switch rung {
            case .gammaTable, .overlay, .unavailable:
                // Nothing to read back: gamma and the overlay have no register to
                // report a value, and probing DDC on a display that has no channel
                // (or none that works) only burns I2C timeouts. Leave the value as is.
                return
            case .ddcHardware:
                break
            }

            DDCService.shared.readAsync(
                displayID: displayID,
                command: DDCService.brightnessVCP
            ) { [weak self] result in
                guard let self else { return }
                if let result = result, result.max > 0 {
                    // A DDC read reports the backlight only. Below the switchover the
                    // backlight is parked at its floor and the gamma table carries the
                    // rest, so the raw read is NOT the value the user sees — adopting it
                    // would snap the slider to the switchover on every refresh. Fold the
                    // current software factor back in to recover the combined value.
                    let hardwarePercent = Double(result.current) / Double(result.max) * 100.0
                    let softwarePercent = (self.currentSoftwareBrightness(for: displayID) ?? 1.0) * 100.0
                    let brightness = CombinedBrightness.combined(
                        hardware: hardwarePercent, software: softwarePercent
                    )
                    self.ddcAvailableLock.lock()
                    let firstRead = self.ddcAvailable[displayID] != true
                    self.ddcAvailable[displayID] = true
                    self.ddcMaxBrightness[displayID] = result.max
                    self.ddcAvailableLock.unlock()
                    // A first successful read is what promotes an unproven display
                    // to a *proven* hardware rung; nothing else observes this.
                    if firstRead { self.scheduleRungRefresh(for: displayID) }
                    Task { @MainActor in
                        // DDC reads quantize (many panels expose a coarser internal
                        // scale than they accept), so a value we just set can read back
                        // 1-2% off and twitch the slider on every open. Adopt the read
                        // only on the first seed, or when it differs enough to be a real
                        // external change (the monitor's own buttons), not read noise.
                        if firstRead || abs(brightness - display.brightness) > 3.0 {
                            display.brightness = brightness
                        }
                    }
                }
                // A failed/ignored read does NOT mean DDC is unavailable: many monitors
                // accept brightness *writes* but never answer *reads* (they ack the I2C
                // transaction with stale/null bytes, now rejected by DDCService). Leaving
                // availability undetermined lets the write path decide, marking it false
                // here would wrongly force the gamma/software fallback on a display whose
                // hardware backlight control works fine, just showing a stale slider value.
            }
        }
    }

    /// The built-in display we currently observe for brightness changes.
    private var observedBuiltinID: CGDirectDisplayID?

    /// Subscribes to the built-in panel's brightness-change notifications so the slider
    /// tracks live (native keys, auto-brightness, Night Shift/TrueTone) rather than only
    /// refreshing on panel-open/wake/reconfigure. Idempotent: re-points at the current
    /// built-in (or drops the observer if none) and no-ops when nothing changed, so it's
    /// safe to call on every display reconfiguration.
    @MainActor
    func startObservingBuiltinBrightness() {
        let builtin = builtinDisplayID()
        guard observedBuiltinID != builtin else { return }
        if let old = observedBuiltinID {
            _ = _DSUnregisterBrightnessChange?(old, old)
            observedBuiltinID = nil
        }
        guard let builtin, let register = _DSRegisterBrightnessChange else { return }
        _ = register(builtin, builtin, _crispBuiltinBrightnessChanged)
        observedBuiltinID = builtin
    }

    @MainActor
    func setBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) async {
        let clamped = max(0.0, min(display.maxBrightness, brightness))
        // Hardware only ever sees 0...100; the region above is the EDR overlay's.
        let hardware = min(clamped, 100.0)
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        // A direct manual write wins over any in-flight glide (click fade,
        // step-button glide, refresh catch-up); without this the animator
        // keeps writing stale interpolated values against the drag.
        if !isAutoAdjust {
            cancelAnimation(for: displayID)
        }

        // Record manual adjust time so auto-brightness can honour the cooldown period.
        if !isAutoAdjust {
            manualAdjustLock.withLock {
                lastManualAdjustDate = Date()
            }
            PresetService.shared.noteManualChange()
            noteManualBrightnessChange(displayID: displayID, isBuiltin: isBuiltin, value: clamped)
        }

        if isBuiltin {
            let value = Float(hardware / 100.0)
            display.brightness = clamped
            queue.async { [weak self] in
                self?.setInternalBrightness(value)
            }
        } else {
            display.brightness = clamped
            // In the boost region the external's transfer table belongs to the
            // boost sync below (factor > 1.0); writing the pinned-at-100 dim
            // here too would race it with an identity table on every tick. The
            // monitor is in HDR mode up there anyway, so there is no hardware
            // write to make.
            if clamped <= 100 {
                // One choke point for "which mechanism dims this display": the
                // same resolution the badge shows, so the two can never diverge.
                switch refreshRung(for: display) {
                case .ddcHardware:
                    writeDDCBrightnessCoalesced(percent: hardware, for: displayID)
                case .gammaTable:
                    queue.async { [weak self] in
                        self?.setSoftwareBrightness(hardware, for: displayID)
                    }
                case .overlay:
                    BrightnessOverlayManager.shared.setBrightness(hardware, for: displayID)
                case .unavailable:
                    // Nothing can dim this display. The slider is disabled in the
                    // UI; a stray key press must not pretend otherwise either.
                    break
                }
            }
        }
        BrightnessBoostService.shared.syncOverlay(for: display)
    }

    /// Broadcasts a manual (user-initiated) brightness change so auto-brightness can react:
    /// an external change re-pins that display's offset; a built-in change re-pins all offsets
    /// (externals hold; the offset absorbs it) instead of dragging the externals along.
    private func noteManualBrightnessChange(displayID: CGDirectDisplayID, isBuiltin: Bool, value: Double) {
        if isBuiltin {
            NotificationCenter.default.post(name: .crispBuiltinManualAdjust, object: nil)
        } else {
            NotificationCenter.default.post(
                name: .crispExternalManualAdjust,
                object: nil,
                userInfo: ["displayID": displayID, "value": value]
            )
        }
    }

    // MARK: - Coalescing DDC Writer

    /// Latest pending brightness percent per display. Only one DDC write is in flight
    /// per display and intermediate targets are dropped (latest wins), so a fast
    /// slider drag can never build a queue of stale writes behind the slow I2C bus.
    private var pendingDDCPercent: [CGDirectDisplayID: Double] = [:]
    private var ddcPumpActive: Set<CGDirectDisplayID> = []
    private var ddcFailStreak: [CGDirectDisplayID: Int] = [:]
    /// Timestamp of the last DDC brightness write per display, used to pace writes.
    private var lastDDCWriteInstant: [CGDirectDisplayID: DispatchTime] = [:]
    private let ddcPumpLock = NSLock()

    /// Minimum spacing between consecutive DDC brightness writes to one display.
    /// The DDC/CI (MCCS) spec asks hosts to wait ~50ms after a "Set VCP Feature"
    /// before the next message; writing faster (a fast slider drag fires ~60/sec)
    /// floods the I2C bus and makes many panels visibly flicker. The coalescing
    /// pump still applies the latest value, this just caps the cadence at ~20/sec.
    private let minDDCWriteInterval: TimeInterval = 0.05

    // Brightness is split across the backlight and the gamma table by CombinedBrightness:
    // below its switchover the backlight parks at its floor and gamma dims, above it gamma
    // is off and the backlight ramps. See that type for why, and for the evidence that a
    // monitor's DDC 0 is a normal room brightness rather than anything close to dark.

    /// Externals currently in HDR mode. A DisplayHDR monitor manages its own
    /// luminance and silently discards DDC brightness writes (they still ack,
    /// so failure detection never fires), leaving 15-100% of the slider dead.
    /// While a display is in this set its whole 0-100 range dims in software
    /// instead. Maintained by BrightnessBoostService (HDR toggle, boost's
    /// auto-switch, and reconfiguration sync). Guarded by ddcAvailableLock.
    private var hdrDimmedDisplays: Set<CGDirectDisplayID> = []

    func setHDRSoftwareDimming(_ on: Bool, for displayID: CGDirectDisplayID) {
        let changed = ddcAvailableLock.withLock { () -> Bool in
            let was = hdrDimmedDisplays.contains(displayID)
            guard was != on else { return false }
            if on { hdrDimmedDisplays.insert(displayID) } else { hdrDimmedDisplays.remove(displayID) }
            return true
        }
        // Entering/leaving HDR moves the display between the hardware and gamma
        // rungs, which the badge has to follow.
        if changed { scheduleRungRefresh(for: displayID) }
    }

    private func writeDDCBrightnessCoalesced(percent: Double, for displayID: CGDirectDisplayID) {
        // Single choke point for every DDC brightness write (direct sets and
        // glide ticks both land here), so this one check routes the full
        // range to gamma while the monitor is in HDR mode. DDC control
        // resumes automatically when HDR goes off: the first hardware write's
        // gamma reset below clears the leftover software dim.
        let hdrDimmed = ddcAvailableLock.withLock { hdrDimmedDisplays.contains(displayID) }
        if hdrDimmed {
            queue.async { [weak self] in
                self?.setSoftwareBrightness(percent, for: displayID)
            }
            return
        }
        // Split the single user-facing value across the two dimmers. Exactly one of them
        // moves in each region, which is the whole point: driving both at once multiplies
        // them, and that is what made emitted light quadratic near the bottom.
        let split = CombinedBrightness.split(combined: percent)

        ddcPumpLock.lock()
        pendingDDCPercent[displayID] = split.hardware
        let alreadyPumping = ddcPumpActive.contains(displayID)
        if !alreadyPumping { ddcPumpActive.insert(displayID) }
        ddcPumpLock.unlock()
        if !alreadyPumping { pumpDDCWrite(for: displayID) }

        queue.async { [weak self] in
            guard let self else { return }
            if split.software < 100.0 {
                self.setSoftwareBrightness(split.software, for: displayID)
            } else if let f = self.currentSoftwareBrightness(for: displayID), f < 1.0 {
                // Only clear a software dim once DDC has actually succeeded on
                // this display. While it is still unproven (nil), a display
                // whose writes all fail (Dell without a DDC channel) would
                // otherwise flash to full on every attempt, fighting the gamma
                // fallback that is actually doing the dimming.
                let proven = self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] == true }
                if proven {
                    self.setSoftwareBrightness(100.0, for: displayID)
                }
            }
        }
    }

    private func pumpDDCWrite(for displayID: CGDirectDisplayID) {
        ddcPumpLock.lock()
        // Peek (don't consume yet): if we must wait to honour the pacing floor,
        // a newer drag value may arrive during the wait and should supersede this
        // one. Consuming only after the wait keeps "latest wins" intact.
        guard pendingDDCPercent[displayID] != nil else {
            ddcPumpActive.remove(displayID)
            ddcPumpLock.unlock()
            return
        }
        let last = lastDDCWriteInstant[displayID]
        ddcPumpLock.unlock()

        // Pace writes: if the previous write was under minDDCWriteInterval ago,
        // wait out the remainder before issuing the next one. Without this the
        // recursive pump fires writes back-to-back and floods the DDC/CI bus.
        if let last {
            let now = DispatchTime.now()
            let elapsed = now.uptimeNanoseconds >= last.uptimeNanoseconds
                ? Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
                : minDDCWriteInterval
            let remaining = minDDCWriteInterval - elapsed
            if remaining > 0 {
                queue.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.pumpDDCWrite(for: displayID)
                }
                return
            }
        }

        // Now consume the latest pending value (drops any intermediate drag steps).
        ddcPumpLock.lock()
        guard let percent = pendingDDCPercent.removeValue(forKey: displayID) else {
            ddcPumpActive.remove(displayID)
            ddcPumpLock.unlock()
            return
        }
        lastDDCWriteInstant[displayID] = .now()
        ddcPumpLock.unlock()

        // Denormalize percentage to display's native DDC range.
        // If max is unknown, default to 100 (safe for most monitors).
        let knownMax: UInt16 = ddcAvailableLock.withLock {
            ddcMaxBrightness[displayID] ?? 100
        }
        let ddcValue = UInt16((percent / 100.0) * Double(knownMax))

        DDCService.shared.writeAsync(
            displayID: displayID,
            command: DDCService.brightnessVCP,
            value: ddcValue
        ) { [weak self] success in
            guard let self else { return }
            if success {
                let proved = self.ddcAvailableLock.withLock { () -> Bool in
                    let was = self.ddcAvailable[displayID]
                    self.ddcAvailable[displayID] = true
                    return was != true
                }
                // Only on the transition: this closure runs on every write.
                if proved { self.scheduleRungRefresh(for: displayID) }
                self.ddcPumpLock.withLock { self.ddcFailStreak[displayID] = 0 }
            } else {
                let streak = self.ddcPumpLock.withLock { () -> Int in
                    let s = (self.ddcFailStreak[displayID] ?? 0) + 1
                    self.ddcFailStreak[displayID] = s
                    return s
                }
                // A single flaky I2C write must not flip the display into gamma mode
                // mid-drag (DDC + gamma dimming stack up and later "reset" visibly).
                // Only give up on DDC after 3 consecutive failures.
                if streak >= 3 {
                    self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = false }
                    // The display just fell off the hardware rung; the badge says so.
                    self.scheduleRungRefresh(for: displayID)
                    DispatchQueue.main.async { [weak self] in
                        self?.setSoftwareBrightness(percent, for: displayID)
                    }
                }
            }
            self.pumpDDCWrite(for: displayID)
        }
    }

    // MARK: - Smooth Brightness Transitions

    /// Animate brightness from the display's current value to `targetBrightness` smoothly.
    ///
    /// - For DDC displays: sends 5 DDC commands spaced ~40ms apart (200ms total).
    ///   DDC I2C commands are inherently slow (~40–50ms each), so 5 steps at 40ms intervals
    ///   fills the 200ms window without flooding the bus.
    /// - For software (gamma) brightness: 8 gamma table updates over 200ms give a visibly
    ///   smooth fade without perceptible frame drops.
    /// - For built-in displays: 8 IOKit writes over 200ms mirror the software path.
    ///
    /// Cancels any previously running animation for the same display, so rapid key presses
    /// always feel responsive, the animation re-targets from wherever it currently is.
    @MainActor
    func setBrightnessSmooth(
        _ targetBrightness: Double,
        for display: DisplayInfo,
        isAutoAdjust: Bool = false,
        duration: TimeInterval = 0.20
    ) {
        let clamped = max(0.0, min(display.maxBrightness, targetBrightness))
        let displayID = display.displayID
        let fromBrightness = display.brightness

        if !isAutoAdjust {
            manualAdjustLock.withLock {
                lastManualAdjustDate = Date()
            }
            PresetService.shared.noteManualChange()
            noteManualBrightnessChange(displayID: displayID, isBuiltin: display.isBuiltin, value: clamped)
        }

        let anim = animator(for: displayID)

        // Step at ~125Hz (matches the 120Hz built-in panel) on every path:
        // display.brightness drives the UI slider, and NSSlider renders value
        // changes discretely (no interpolation), so the step rate IS the
        // knob's frame rate. Hardware paces itself: gamma and IOKit writes are
        // cheap; DDC goes through the coalescing writer, which drops steps the
        // ~45ms-per-write I2C bus can't take.
        let smoothSteps = max(8, Int(duration / 0.008))

        if display.isBuiltin {
            anim.animate(from: fromBrightness, to: clamped, steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                guard let self, let display else { return }
                display.brightness = value
                let floatVal = Float(min(value, 100.0) / 100.0)
                self.queue.async { self.setInternalBrightness(floatVal) }
                BrightnessBoostService.shared.syncOverlay(for: display)
            }
        } else {
            // Resolve the rung once, up front: the per-step closure runs at
            // ~125Hz and must not re-derive it (nor touch the main actor's
            // VirtualDisplayService) on every tick.
            let rung = refreshRung(for: display)
            // One animation, one per-step writer chosen by the rung. Above 100
            // the boost sync owns the transfer table (see setBrightness), which
            // is why every writer below is gated on value <= 100.
            let applyStep: (Double) -> Void
            switch rung {
            case .ddcHardware:
                // Routed through the coalescing writer so steps that outpace the
                // I2C bus are dropped instead of queued.
                applyStep = { [weak self] value in
                    self?.writeDDCBrightnessCoalesced(percent: value, for: displayID)
                }
            case .gammaTable:
                // The transfer-table write is a synchronous WindowServer call, so
                // it goes to the background queue like the built-in path's IOKit
                // write; at 125 steps/s it would otherwise stall the main thread.
                applyStep = { [weak self] value in
                    guard let self else { return }
                    self.queue.async { self.setSoftwareBrightness(value, for: displayID) }
                }
            case .overlay:
                // A layer opacity change, cheap enough to do inline on the main
                // thread the animator already ticks on.
                applyStep = { value in
                    MainActor.assumeIsolated {
                        BrightnessOverlayManager.shared.setBrightness(value, for: displayID)
                    }
                }
            case .unavailable:
                // Nothing to glide to. Don't move the slider either: a value that
                // changes while the screen does not is exactly the lie the ladder exists to stop.
                return
            }

            anim.animate(from: fromBrightness, to: clamped,
                         steps: smoothSteps, duration: duration) { [weak display] value, _ in
                guard let display else { return }
                display.brightness = value
                if value <= 100 { applyStep(value) }
                BrightnessBoostService.shared.syncOverlay(for: display)
            }
        }
    }

    // MARK: - Software Brightness (Gamma Table Fallback)

    // MARK: - Baseline (ColorSync) gamma

    /// The transfer table ColorSync installed for each display, captured before Crisp writes
    /// one of its own. Software dimming SCALES this rather than replacing it.
    ///
    /// This matters more than it looks. A monitor ships with a calibrated tone curve, which
    /// macOS loads from the display's colour profile into the video card gamma table. Writing
    /// a synthetic straight-line ramp — which this code used to do at every brightness level,
    /// including a factor of 1.0 — discards that curve wholesale: blacks lift, the colour cast
    /// the panel was calibrated for disappears, and everything reads flat and washed out even
    /// at a comfortable brightness.
    private var baselineGamma: [CGDirectDisplayID: GammaTable] = [:]
    private let baselineGammaLock = NSLock()
    /// ColorSync is restored once per app run before the first baseline capture, so the
    /// baseline can never be a table Crisp itself left behind in an earlier session.
    private var didRestoreColorSyncForBaseline = false

    struct GammaTable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
        var count: Int { red.count }

        /// A straight-line ramp, used only when the display refuses to report its table.
        static func linear(count: Int) -> GammaTable {
            let values = (0..<count).map { CGGammaValue(Float($0) / Float(max(count - 1, 1))) }
            return GammaTable(red: values, green: values, blue: values)
        }
    }

    /// The display's own table, captured once. Must run before any Crisp gamma write for that
    /// display, which it does: every write path builds its output from this.
    private func baselineGammaTable(for displayID: CGDirectDisplayID) -> GammaTable {
        if let cached = baselineGammaLock.withLock({ baselineGamma[displayID] }) { return cached }

        // Undo anything a previous session left in the table before reading it. Guarded so a
        // multi-display setup only takes the one restore.
        let needsRestore = baselineGammaLock.withLock { () -> Bool in
            guard !didRestoreColorSyncForBaseline else { return false }
            didRestoreColorSyncForBaseline = true
            return true
        }
        if needsRestore {
            CGDisplayRestoreColorSyncSettings()
        }

        let capacity = 256
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var sampleCount: UInt32 = 0
        let err = CGGetDisplayTransferByTable(
            displayID, UInt32(capacity), &red, &green, &blue, &sampleCount
        )

        let table: GammaTable
        if err == .success, sampleCount > 1 {
            let n = Int(sampleCount)
            table = GammaTable(
                red: Array(red[0..<n]), green: Array(green[0..<n]), blue: Array(blue[0..<n])
            )
        } else {
            // Reading failed: fall back to a straight ramp so dimming still works. Colour
            // fidelity is lost, but a dead brightness control would be worse.
            table = .linear(count: capacity)
        }

        baselineGammaLock.withLock { baselineGamma[displayID] = table }
        return table
    }

    /// Applies brightness by scaling the display's own transfer table, for the region below
    /// CombinedBrightness's switchover and for displays where DDC is unavailable.
    /// brightness: 0–100 (percentage); never reaches 0 so the screen cannot go fully black.
    /// Above 100 (external boost region, monitor in HDR mode) the same scaling continues past
    /// 1.0, pushing SDR content into the HDR wire range; the monitor tone-maps the result.
    ///
    /// Scaling the baseline rather than writing a fresh ramp is what preserves the monitor's
    /// calibrated colour at every level, and makes a factor of 1.0 an exact restoration.
    ///
    /// If GammaService has an active adjustment for this display, it delegates to GammaService
    /// so the two do not overwrite each other's CGSetDisplayTransfer* call.
    func setSoftwareBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let factor = max(0.05, brightness / 100.0)
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = factor }
        saveSoftwareBrightness(factor: factor, for: displayID)

        // If GammaService has an active adjustment, let it re-apply (it will incorporate the factor).
        if GammaService.shared.hasActiveAdjustment(for: displayID) {
            GammaService.shared.reapply(for: displayID)
            return
        }

        let baseline = baselineGammaTable(for: displayID)

        // Exact restoration at 1.0: write the captured table back untouched rather than a
        // recomputed one, so no float rounding creeps into the colour curve.
        if abs(factor - 1.0) < 0.0001 {
            var red = baseline.red
            var green = baseline.green
            var blue = baseline.blue
            // The return value is the only evidence that this rung works at all:
            // a display that rejects the table drops to the overlay rung.
            noteGammaWriteResult(
                CGSetDisplayTransferByTable(displayID, UInt32(baseline.count), &red, &green, &blue),
                for: displayID
            )
            return
        }

        let floatFactor = Float(factor)
        var red = baseline.red.map { CGGammaValue($0 * floatFactor) }
        var green = baseline.green.map { CGGammaValue($0 * floatFactor) }
        var blue = baseline.blue.map { CGGammaValue($0 * floatFactor) }

        noteGammaWriteResult(
            CGSetDisplayTransferByTable(displayID, UInt32(baseline.count), &red, &green, &blue),
            for: displayID
        )
    }

    /// External boost region: BrightnessBoostService drives the transfer table
    /// above 1.0 through here, on the same serial queue as the dim path, so
    /// slider motion above and below 100 is always one writer, one table.
    func setBoostFactor(_ factor: Double, for displayID: CGDirectDisplayID) {
        queue.async { [weak self] in
            self?.setSoftwareBrightness(factor * 100.0, for: displayID)
        }
    }

    /// Restores the display's own transfer table, undoing any software dimming.
    /// Writes the captured ColorSync baseline rather than a straight ramp, so the monitor's
    /// calibrated colour comes back rather than being flattened.
    func resetSoftwareBrightness(for displayID: CGDirectDisplayID) {
        let baseline = baselineGammaTable(for: displayID)
        var red = baseline.red
        var green = baseline.green
        var blue = baseline.blue
        CGSetDisplayTransferByTable(displayID, UInt32(baseline.count), &red, &green, &blue)
    }

    /// Returns whether DDC is available for the given display.
    /// nil means not yet determined (first use).
    func isDDCAvailable(for displayID: CGDirectDisplayID) -> Bool? {
        ddcAvailableLock.withLock { ddcAvailable[displayID] }
    }

    /// Clears all per-display state for a disconnected display.
    /// Call this when a display is removed so stale state cannot pollute a reconnect.
    @MainActor
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        ddcAvailableLock.withLock {
            ddcAvailable.removeValue(forKey: displayID)
            ddcMaxBrightness.removeValue(forKey: displayID)
            // Display IDs are reused: without this, a disconnected HDR
            // display's software-dimming routing would stick to whatever
            // display inherits its ID next.
            hdrDimmedDisplays.remove(displayID)
            // Same reuse hazard for the rung's gamma input: a reconnecting
            // display must start unproven, not inherit a verdict.
            gammaRejected.remove(displayID)
        }
        // A disconnect must leave nothing behind that could cover a screen that
        // comes back on this ID (AGENTS.md rule #4).
        BrightnessOverlayManager.shared.removeOverlay(for: displayID)
        // Same ID-reuse hazard for the rest: reapplySoftwareBrightnessIfNeeded
        // reads the in-memory factor first, so a display inheriting this ID
        // would silently get the departed display's dimming factor.
        animators[displayID]?.cancel()
        animators.removeValue(forKey: displayID)
        softwareBrightnessLock.withLock {
            _ = softwareBrightnessFactors.removeValue(forKey: displayID)
        }
        ddcPumpLock.withLock {
            pendingDDCPercent.removeValue(forKey: displayID)
            ddcFailStreak.removeValue(forKey: displayID)
            lastDDCWriteInstant.removeValue(forKey: displayID)
            // ddcPumpActive stays: the pump owns it and removes itself once it
            // sees no pending value.
        }
    }

    /// Re-applies the software brightness for a display after wake from sleep or hot-plug.
    /// Checks in-memory factor first; falls back to UserDefaults so restart is handled too.
    /// No-op if no saved factor < 1.0 exists.
    func reapplySoftwareBrightnessIfNeeded(for display: DisplayInfo) {
        let displayID = display.displayID
        let inMemory = softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
        let factor = inMemory ?? loadSoftwareBrightness(for: displayID)
        guard let f = factor, f < 1.0 else { return }
        // Populate in-memory cache if loaded from disk
        if inMemory == nil {
            softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = f }
        }
        setSoftwareBrightness(f * 100.0, for: displayID)
    }

    // MARK: - Internal Display (IODisplayGetFloatParameter)

    private static nonisolated(unsafe) let ioDisplayBrightnessKey = "brightness" as CFString

    /// Returns the io_service_t for the built-in display using CGDisplayIOServicePort.
    /// Falls back to iterating IODisplayConnect services if CGDisplayIOServicePort returns null.
    /// Caller does NOT need to release, CGDisplayIOServicePort returns a non-retained port.
    private func builtinIOService() -> io_service_t? {
        // Find the built-in CGDirectDisplayID
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        guard let builtinID = (0..<Int(displayCount))
            .map({ displayIDs[$0] })
            .first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        // CGDisplayIOServicePort returns a non-retained service port (do not release)
        let servicePort = CGDisplayIOServicePort(builtinID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            return servicePort
        }

        return nil
    }

    /// Returns the CGDirectDisplayID of the built-in display, if any.
    private func builtinDisplayID() -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        return (0..<Int(displayCount)).map { displayIDs[$0] }.first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func getInternalBrightness() -> Double? {
        // Primary: DisplayServices (works on Apple Silicon, where IODisplayConnect is gone)
        if let get = _DSGetBrightness, let id = builtinDisplayID() {
            var v: Float = 0
            if get(id, &v) == 0 {
                return Double(v) * 100.0
            }
        }

        // Fallback: use CGDisplayIOServicePort to get the specific builtin display service
        if let servicePort = builtinIOService() {
            var value: Float = 0
            if IODisplayGetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }

        // Fallback: iterate IODisplayConnect but only accept services that
        // correspond to a built-in display (matched via CGDisplayIOServicePort cross-check).
        // Build set of known external service ports to exclude them.
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // Skip services that are known external display ports
            guard !externalPorts.contains(service) else { continue }
            var value: Float = 0
            if IODisplayGetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }
        return nil
    }

    private func setInternalBrightness(_ value: Float) {
        // Primary: DisplayServices (works on Apple Silicon, where IODisplayConnect is gone)
        if let set = _DSSetBrightness, let id = builtinDisplayID() {
            if set(id, value) == 0 {
                return
            }
        }

        // Fallback: use CGDisplayIOServicePort to target only the builtin display service
        if let servicePort = builtinIOService() {
            if IODisplaySetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                return
            }
        }

        // Fallback: iterate IODisplayConnect, skipping known external ports
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            guard !externalPorts.contains(service) else { continue }
            if IODisplaySetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                return
            }
        }
    }
}
