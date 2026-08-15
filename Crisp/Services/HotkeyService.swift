import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os.log

private let hotkeyLog = Logger(subsystem: "com.crisp.app", category: "HotkeyService")

/// Carbon delivers hot-key events to a C callback on the main run loop. The
/// service is a singleton, so the handler reaches it directly rather than
/// carrying a pointer that would have to outlive the event.
private func hotkeyEventCallback(
    handlerRef: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    // Carbon dispatches on the main thread (the run loop the handler is installed
    // on), so this is the same assumption BrightnessKeyService's tap callback
    // makes and is safe for the same reason.
    MainActor.assumeIsolated { HotkeyService.shared.perform(hotKeyIdentifier: hotKeyID.id) }
    return noErr
}

/// User-assignable global keyboard shortcuts for brightness and volume,
/// registered with Carbon's `RegisterEventHotKey`.
///
/// **Why Carbon, and why that matters in this repo specifically.** The F1/F2
/// media keys are captured with a `CGEventTap` (`BrightnessKeyService`), which
/// macOS only grants to a process the user has approved under Privacy &
/// Security › Accessibility. That approval is bound to the app's code signature,
/// so a rebuild, an upgrade or a replaced bundle can leave the toggle switched on
/// over a TCC record that no longer matches — the tap is refused and the keys
/// silently stop working. This app has an entire diagnostic state
/// (`KeyInterceptionState.grantedButRefused`), a status row and a reset button
/// devoted to that failure, because it is the one that looks exactly like
/// success.
///
/// `RegisterEventHotKey` needs **no Accessibility grant at all**: the app asks
/// the window server for one specific combination and is handed that key, rather
/// than watching every event in the session. So these shortcuts keep working in
/// precisely the state that kills the media-key path — a control surface whose
/// failure mode is independent of the one that started this fork. It is a public,
/// documented API (Carbon Event Manager), so §3.1 is untouched: nothing here goes
/// near a private framework.
///
/// **It does not touch `BrightnessKeyService`.** That service's arming, retry and
/// trust-watchdog logic is load-bearing — re-enabling a revoked event tap stalls
/// the window server's input pipeline and freezes clicks system-wide — so this
/// runs alongside it and shares nothing but the settings that decide which
/// displays a key press applies to.
@MainActor
final class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    private init() {}

    /// `'CRSP'`, the four-character signature Carbon tags this app's hot keys
    /// with. Only used to keep our ids distinct from another process's.
    private static let signature: OSType = 0x4352_5350

    /// The registered `EventHotKeyRef` per action, so one can be unregistered
    /// without disturbing the others.
    private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    /// The current set. The single source the recorder UI reads and writes; the
    /// persisted copy lives in `SettingsService`.
    var bindings: HotkeyBindings { SettingsService.shared.hotkeyBindings }

    /// Actions whose combination the OS refused (another process already owns it).
    ///
    /// Published so the recorder can say so instead of showing a shortcut that
    /// looks assigned and never fires — the same "looks like success" failure the
    /// brightness keys taught this project to surface rather than log.
    @Published private(set) var refusedBySystem: Set<HotkeyAction> = []

    // MARK: - Lifecycle

    /// Installs the Carbon handler and registers every persisted shortcut.
    /// Idempotent: a second call re-registers the same set.
    func start() {
        installHandlerIfNeeded()
        applyRegistrations(for: bindings)
    }

    /// Unregisters everything. Not called in normal operation — the app owns
    /// these until it quits — but a service that can only be turned on is one
    /// nobody can test or reason about.
    func stop() {
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        refusedBySystem.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(), hotkeyEventCallback, 1, &spec, nil, &handlerRef
        )
        guard status == noErr else {
            // Nothing to recover: without the handler a registration would fire
            // into nowhere, so the feature is simply absent — the failure mode
            // AGENTS.md §3.1 asks for from anything that can go missing.
            hotkeyLog.error("InstallEventHandler failed (\(status, privacy: .public)) — shortcuts unavailable")
            handlerRef = nil
            return
        }
    }

    // MARK: - Assignment

    /// Assigns a combination to an action, or explains why it cannot be.
    ///
    /// The decision is `HotkeyBindings`' (pure, tested): a combination with no
    /// ⌘/⌥/⌃ is refused because a global hotkey on a bare letter would swallow
    /// that letter everywhere, and one already owned by another action is refused
    /// rather than moved, so a shortcut can never disappear silently.
    ///
    /// Registration is attempted *before* the new set is adopted, so a
    /// combination the OS will not give us never becomes the state the UI shows.
    @discardableResult
    func assign(_ binding: HotkeyBinding, to action: HotkeyAction) -> Result<Void, HotkeyRejection> {
        switch bindings.assigning(binding, to: action) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let next):
            SettingsService.shared.hotkeyBindings = next
            applyRegistrations(for: next)
            return .success(())
        }
    }

    /// Removes an action's shortcut.
    func clear(_ action: HotkeyAction) {
        let next = bindings.clearing(action)
        SettingsService.shared.hotkeyBindings = next
        applyRegistrations(for: next)
    }

    /// Re-registers the whole set: unregister everything, then register what the
    /// set says. Wholesale rather than incremental because the set is at most a
    /// handful of keys and a partial update is the shape that leaves an orphaned
    /// registration nothing can reach to remove.
    private func applyRegistrations(for bindings: HotkeyBindings) {
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        var refused: Set<HotkeyAction> = []
        guard handlerRef != nil else {
            // No handler: register nothing rather than claim keys that could not
            // be delivered anywhere.
            refusedBySystem = Set(bindings.assignments.map(\.action))
            return
        }
        for (action, binding) in bindings.assignments {
            guard let identifier = Self.identifier(for: action) else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                Self.carbonModifiers(binding.modifiers),
                EventHotKeyID(signature: Self.signature, id: identifier),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registered[action] = ref
            } else {
                // The usual cause is another process owning the combination.
                // Recorded, not retried: a retry loop against a key someone else
                // holds is noise, and the user's next move is to pick another one.
                refused.insert(action)
                // One interpolated literal: os.log's message is a literal, not a
                // String, so it cannot be assembled from pieces.
                hotkeyLog.info("RegisterEventHotKey refused \(binding.displayString, privacy: .public) for \(action.rawValue, privacy: .public) (status \(status, privacy: .public))")
            }
        }
        refusedBySystem = refused
    }

    /// Carbon's modifier bits. The one place that has to agree with the framework
    /// — `HotkeyModifiers` keeps its own values so the persisted file does not.
    private static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// The hot-key id an action is registered under: its position in
    /// `allCases`, which is stable for a build and never persisted.
    private static func identifier(for action: HotkeyAction) -> UInt32? {
        HotkeyAction.allCases.firstIndex(of: action).map { UInt32($0) }
    }

    private static func action(forIdentifier identifier: UInt32) -> HotkeyAction? {
        let cases = HotkeyAction.allCases
        guard identifier < UInt32(cases.count) else { return nil }
        return cases[Int(identifier)]
    }

    // MARK: - Performing

    /// Runs the action a pressed hot key maps to. Called from the Carbon handler.
    func perform(hotKeyIdentifier identifier: UInt32) {
        guard let action = Self.action(forIdentifier: identifier) else { return }
        switch action {
        case .brightnessUp: adjustBrightness(up: true)
        case .brightnessDown: adjustBrightness(up: false)
        case .volumeUp: adjustVolume(.up)
        case .volumeDown: adjustVolume(.down)
        case .volumeMute: adjustVolume(.mute)
        }
    }

    /// One step of brightness on whichever displays the user's brightness-key
    /// preference names — the same `SettingsService.brightnessKeyTarget` the F1/F2
    /// path uses, so the two surfaces cannot disagree about what "the display" is.
    ///
    /// The step itself is `CombinedBrightness.stepped`, the same pure ladder,
    /// which is where the sharing ends: `BrightnessKeyService`'s own routing is
    /// entangled with consuming or passing through a `CGEvent`, and that file's
    /// logic is deliberately left untouched.
    private func adjustBrightness(up: Bool) {
        for display in brightnessTargets() {
            let next = Self.nextBrightness(for: display, up: up)
            BrightnessService.shared.setBrightnessSmooth(next, for: display)
            if let screen = NSScreen.screen(for: display.displayID) {
                BrightnessHUDService.shared.show(
                    brightness: next / max(display.maxBrightness, 1) * 100.0, on: screen
                )
            }
        }
    }

    private func brightnessTargets() -> [DisplayInfo] {
        let displays = DisplayManagerAccessor.shared.displays
        switch SettingsService.shared.brightnessKeyTarget {
        case .allDisplays:
            return displays
        case .selected:
            let chosen = SettingsService.shared.brightnessKeySelectedDisplayUUIDs
            let selected = displays.filter { chosen.contains($0.stateUUID) }
            // None of the chosen displays attached: fall through to the pointer,
            // so the shortcut still does something rather than reading as dead.
            if !selected.isEmpty { return selected }
        case .underCursor:
            break
        }
        return displayUnderCursor().map { [$0] } ?? []
    }

    private func displayUnderCursor() -> DisplayInfo? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return DisplayManagerAccessor.shared.displays.first { $0.displayID == number }
    }

    /// The next brightness for one press, including the EDR boost region above
    /// 100 where the range is linear in headroom rather than perceptual.
    private static func nextBrightness(for display: DisplayInfo, up: Bool) -> Double {
        let current = display.brightness
        if current > 100.0 || (up && current >= 100.0) {
            let step = 100.0 / CombinedBrightness.stepsPerRange
            return max(0.0, min(display.maxBrightness, current + (up ? step : -step)))
        }
        return CombinedBrightness.stepped(from: current, up: up)
    }

    private enum VolumeChange { case up, down, mute }

    /// Volume goes to whichever monitor owns the default audio output, exactly as
    /// the volume keys do (issue #23). No output on a DDC-volume monitor means
    /// the shortcut does nothing: moving a monitor's speakers while the sound is
    /// coming out of somewhere else would be a control acting on the wrong thing.
    private func adjustVolume(_ change: VolumeChange) {
        let service = VolumeService.shared
        guard let target = service.displayForDefaultAudioOutput(in: DisplayManagerAccessor.shared.displays)
        else { return }
        switch change {
        case .mute: service.toggleMute(for: target)
        case .up: service.setVolume(target.volume + Self.volumeStep, for: target)
        case .down: service.setVolume(target.volume - Self.volumeStep, for: target)
        }
        if let screen = NSScreen.screen(for: target.displayID) {
            BrightnessHUDService.shared.show(
                level: target.volume, image: target.volume <= 0 ? .mute : .volume, on: screen
            )
        }
    }

    /// The same 1/16 step macOS's own volume keys use.
    private static let volumeStep: Double = 100.0 / 16.0
}

extension HotkeyModifiers {
    /// The modifiers of a recorded key press.
    ///
    /// Device-independent flags only: the raw event also carries left/right and
    /// numeric-pad bits, and ⌘ on the left is the same shortcut as ⌘ on the
    /// right. Lives here rather than in the model because `NSEvent` is AppKit and
    /// `Crisp/Models` stays headless (AGENTS.md §3.6).
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyModifiers = []
        let mask = flags.intersection(.deviceIndependentFlagsMask)
        if mask.contains(.command) { modifiers.insert(.command) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
