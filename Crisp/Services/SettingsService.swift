import Foundation
import CoreGraphics
import Combine

/// Which displays the hardware brightness keys act on.
/// Persisted (raw value) via `SettingsService.brightnessKeyTarget`.
enum BrightnessKeyTarget: String, CaseIterable, Codable {
    case underCursor   // only the display under the pointer (current behaviour)
    case allDisplays   // every connected display
    case selected      // only a user-chosen subset (see brightnessKeySelectedDisplays)
}

/// Centralized settings persistence service.
/// Simple settings use UserDefaults via @AppStorage-compatible keys.
/// Complex configurations are stored as JSON in ~/Library/Application Support/Crisp/.
@MainActor
final class SettingsService: ObservableObject, @unchecked Sendable {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard
    /// Shared with DisplayStateStore, which owns the folder's creation and the
    /// one-time move from the pre-rename `FreeDisplay` directory: either service
    /// can be the first to touch it at launch, so that logic can only live in
    /// one place.
    private let supportDir = DisplayStateStore.supportDirectory

    private init() {
        loadAll()
        // Re-sync launch-at-login from the authoritative SMAppService state on every panel
        // open, so toggling Crisp in System Settings > Login Items reflects without a
        // relaunch. No OS notification exists for login-item changes, so panel-open is the
        // cheapest reliable hook. Only the didSet (a UserDefaults write) runs on assignment,
        // never a re-register, so this can't fight the user's own toggle. Singleton -> no teardown.
        NotificationCenter.default.addObserver(
            forName: .crispPanelDidOpen, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let actual = LaunchService.shared.isEnabled
                if self.launchAtLogin != actual { self.launchAtLogin = actual }
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let launchAtLogin          = "crisp.launchAtLogin"
        static let launchAtLoginPrompted  = "crisp.launchAtLogin.prompted"
        static let menuWidth              = "crisp.menuWidth"
        static let showCombinedBrightness = "crisp.showCombinedBrightness"
        static let showVolumeSliders      = "crisp.showVolumeSliders"
        static let ddcCacheTTL            = "crisp.ddcCacheTTL"
        static let colorPickerHistory     = "crisp.colorPickerHistory"
        static let brightnessKeyTarget    = "crisp.brightnessKeyTarget"
        static let hotkeyBindings         = "crisp.hotkeyBindings"
        static let onboardingCompleted    = "crisp.onboarding.completed"
        // Per-display keys use prefix + displayID
        static let brightnessPrefix       = "crisp.brightness_"
        static let contrastPrefix         = "crisp.contrast_"
        static let reapplyDDCOnReconnect  = "crisp.reapplyDDCOnReconnect"
    }

    // MARK: - Published Settings

    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the first-launch "enable Launch at Login?" prompt has been shown.
    @Published var launchAtLoginPrompted: Bool = false {
        didSet { defaults.set(launchAtLoginPrompted, forKey: Keys.launchAtLoginPrompted) }
    }

    /// Whether the first-run guide has been through once — finished or skipped,
    /// which count the same: a guide that reappears after being dismissed is a
    /// nag. App-level, not per-display (AGENTS.md §3.3 is about display state;
    /// plugging in a second monitor does not make someone a new user), and the
    /// only thing that reads it is `OnboardingPlan.shouldPresentAtLaunch`.
    /// Re-opening the guide by hand (Settings › Setup Guide) leaves it set.
    @Published var onboardingCompleted: Bool = false {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    @Published var menuWidth: Double = 320 {
        didSet { defaults.set(menuWidth, forKey: Keys.menuWidth) }
    }

    @Published var showCombinedBrightness: Bool = true {
        didSet { defaults.set(showCombinedBrightness, forKey: Keys.showCombinedBrightness) }
    }

    /// Volume sliders for DDC-volume monitors. Hiding them only affects the
    /// panel; the volume keys keep routing to the monitor.
    @Published var showVolumeSliders: Bool = true {
        didSet { defaults.set(showVolumeSliders, forKey: Keys.showVolumeSliders) }
    }

    @Published var ddcCacheTTL: Double = 5.0 {
        didSet { defaults.set(ddcCacheTTL, forKey: Keys.ddcCacheTTL) }
    }

    /// Recently sampled colors (hex strings, newest first, max 20).
    @Published var colorPickerHistory: [String] = [] {
        didSet {
            defaults.set(colorPickerHistory, forKey: Keys.colorPickerHistory)
        }
    }

    /// Which displays the brightness keys act on. Default: the display under the cursor.
    @Published var brightnessKeyTarget: BrightnessKeyTarget = .underCursor {
        didSet { defaults.set(brightnessKeyTarget.rawValue, forKey: Keys.brightnessKeyTarget) }
    }

    /// Displays chosen for the `.selected` brightness-key mode, stored by stable
    /// DisplayUUID (not the volatile CGDirectDisplayID, which macOS can reassign
    /// across reconnects). Ignored unless brightnessKeyTarget == .selected.
    @Published var brightnessKeySelectedDisplayUUIDs: Set<DisplayUUID> = [] {
        didSet {
            DisplayStateStore.shared.setMembership(\.brightnessKeySelected, to: brightnessKeySelectedDisplayUUIDs)
        }
    }

    /// User-assigned global keyboard shortcuts (`HotkeyService`). Empty by
    /// default: claiming a system-wide combination nobody asked for is how two
    /// apps end up fighting over one.
    ///
    /// App-level rather than per-display, like `brightnessKeyTarget` — a shortcut
    /// is a preference about the keyboard, and AGENTS.md §3.3's UUID rule is
    /// about display state, which this is not. Stored as JSON in a single key so
    /// the whole set is written and read atomically; `HotkeyBindings`' decoder is
    /// what refuses anything a hand edit could have put there.
    @Published var hotkeyBindings: HotkeyBindings = .empty {
        didSet {
            guard let data = try? JSONEncoder().encode(hotkeyBindings),
                  let json = String(data: data, encoding: .utf8) else { return }
            defaults.set(json, forKey: Keys.hotkeyBindings)
        }
    }

    /// Re-apply saved DDC brightness/contrast/volume when a display reconnects
    /// (default on). Input-source re-application is a separate per-display
    /// toggle in DDCFeatureService, off by default.
    @Published var reapplyDDCOnReconnect: Bool = true {
        didSet { defaults.set(reapplyDDCOnReconnect, forKey: Keys.reapplyDDCOnReconnect) }
    }

    // MARK: - Per-Display Settings

    func brightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.brightnessPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.brightnessPrefix + "\(displayID)")
    }

    func contrast(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.contrastPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setContrast(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.contrastPrefix + "\(displayID)")
    }

    // MARK: - Color History

    func addColorToHistory(_ hex: String) {
        var history = colorPickerHistory.filter { $0 != hex }
        history.insert(hex, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        colorPickerHistory = history
    }

    // MARK: - JSON Persistence Helpers

    func save<T: Encodable>(_ value: T, filename: String) {
        let url = supportDir.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            // best-effort persistence; a failed write is non-fatal
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let url = supportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Load All

    private func loadAll() {
        // Sync launch-at-login from the authoritative SMAppService state, not just UserDefaults.
        // This handles the case where the user toggled it externally or after a fresh install.
        launchAtLogin = LaunchService.shared.isEnabled
        launchAtLoginPrompted = defaults.bool(forKey: Keys.launchAtLoginPrompted)
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        menuWidth = defaults.object(forKey: Keys.menuWidth) != nil
            ? defaults.double(forKey: Keys.menuWidth) : 320
        showCombinedBrightness = defaults.object(forKey: Keys.showCombinedBrightness) != nil
            ? defaults.bool(forKey: Keys.showCombinedBrightness) : true
        showVolumeSliders = defaults.object(forKey: Keys.showVolumeSliders) != nil
            ? defaults.bool(forKey: Keys.showVolumeSliders) : true
        ddcCacheTTL = defaults.object(forKey: Keys.ddcCacheTTL) != nil
            ? defaults.double(forKey: Keys.ddcCacheTTL) : 5.0
        colorPickerHistory = defaults.stringArray(forKey: Keys.colorPickerHistory) ?? []
        brightnessKeyTarget = defaults.string(forKey: Keys.brightnessKeyTarget)
            .flatMap(BrightnessKeyTarget.init(rawValue:)) ?? .underCursor
        brightnessKeySelectedDisplayUUIDs = DisplayStateStore.shared.uuids { $0.brightnessKeySelected == true }
        // A corrupt or hand-broken value decodes to nothing rather than throwing:
        // an unreadable shortcut file must cost the user their shortcuts, never
        // their launch.
        hotkeyBindings = defaults.string(forKey: Keys.hotkeyBindings)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(HotkeyBindings.self, from: $0) } ?? .empty
        reapplyDDCOnReconnect = defaults.object(forKey: Keys.reapplyDDCOnReconnect) != nil
            ? defaults.bool(forKey: Keys.reapplyDDCOnReconnect) : true
    }
}
