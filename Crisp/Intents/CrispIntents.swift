import AppIntents
import Foundation

// The Shortcuts surface: set brightness, contrast, volume and input source on a
// named display, read one back, and re-probe the display list.
//
// Every intent does the same three things and nothing else: build an
// `AutomationRequest`, hand it to `AutomationService`, and turn the outcome into
// a result or an error. None of them writes to a monitor, resolves a display,
// clamps a value or decides what a destructive feature may do — that is
// `AutomationRequest.plan` and the DDC write gate beneath it, shared with the
// URL scheme so the two surfaces cannot drift into two policies.
//
// In particular `SwitchInputIntent` is not special-cased here. It is destructive
// in `DDCFeatureRegistry` (VCP 0x60 can switch the panel to a port with nothing
// attached, and only the monitor's own buttons can undo that), so its plan comes
// back as `needsConfirmation` and `AutomationService` asks the user. A shortcut
// is authored by a person, but it can be *triggered* by a time of day, a
// location or another app — none of which is a person watching the screen it is
// about to blank.

/// The failure an intent reports back to Shortcuts.
///
/// One case carrying the reason, rather than a taxonomy: the reasons come from
/// the registry, the discovery ladder and the automation plan, which already
/// explain themselves in sentences ("nothing has proved this monitor supports
/// VCP 0x12 …"). Re-encoding those as error cases would lose exactly the part
/// the user needs.
enum CrispIntentError: Error, CustomLocalizedStringResourceConvertible {
    case refused(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .refused(let reason): return "\(reason)"
        }
    }
}

/// Shared plumbing: run one request and turn a refusal into a thrown error.
private func runAutomation(
    _ display: DisplayEntity, _ feature: DDCFeatureID, _ value: AutomationValue
) async throws {
    let request = AutomationRequest(
        origin: .appIntent, display: DisplayUUID(display.id), feature: feature, value: value
    )
    let outcome = await AutomationService.shared.perform(request)
    guard outcome.didApply else { throw CrispIntentError.refused(outcome.message) }
}

// MARK: - Percent-shaped features

struct SetBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Brightness" }
    static var description: IntentDescription {
        IntentDescription("Sets a display's brightness. Uses the monitor's own backlight over DDC where it answers.")
    }

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(title: "Brightness", inclusiveRange: (0, 100))
    var value: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set brightness of \(\.$display) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runAutomation(display, .brightness, .percent(value))
        return .result()
    }
}

struct SetContrastIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Contrast" }
    static var description: IntentDescription {
        IntentDescription("Sets a display's hardware contrast (VCP 0x12), for monitors that answer a contrast read.")
    }

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(title: "Contrast", inclusiveRange: (0, 100))
    var value: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set contrast of \(\.$display) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runAutomation(display, .contrast, .percent(value))
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Volume" }
    static var description: IntentDescription {
        IntentDescription("Sets the speaker volume of a monitor that exposes DDC volume (VCP 0x62).")
    }

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(title: "Volume", inclusiveRange: (0, 100))
    var value: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set volume of \(\.$display) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runAutomation(display, .volume, .percent(value))
        return .result()
    }
}

// MARK: - Input source (destructive)

/// Switches the monitor's input.
///
/// The value is the monitor's own raw VCP 0x60 code, not a friendly port name,
/// and that is deliberate: input codes are not portable between models (this
/// fork's own BenQ reports `19`, which no VESA table defines), so offering
/// "HDMI 1" in a shortcut would be a guess presented as a fact. `Get Display
/// Info` reports the code the monitor is on, and the panel's calibration wizard
/// is the way to learn the rest without writing 0x60 blind.
///
/// Confirmation is not optional and not implemented here: the plan for a
/// destructive feature can only be `needsConfirmation`, and `AutomationService`
/// is the only thing that can satisfy it.
struct SwitchInputIntent: AppIntent {
    static var title: LocalizedStringResource { "Switch Input Source" }
    static var description: IntentDescription {
        // One literal: IntentDescription takes a LocalizedStringResource, which
        // is a literal type — a concatenation is not one, and splitting it would
        // change the catalog key anyway.
        // swiftlint:disable:next line_length - localized literal
        IntentDescription("Switches a monitor to another input, after asking. Crisp always asks: if nothing is attached to that port the screen goes blank and only the monitor's own buttons can bring it back.")
    }

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(title: "Input source code", inclusiveRange: (0, 65535))
    var code: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Switch \(\.$display) to input code \(\.$code)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // `UInt16(exactly:)` rather than a truncating conversion: a value outside
        // the range must not wrap into a different, valid port code.
        guard let raw = UInt16(exactly: code) else {
            throw CrispIntentError.refused("\(code) is not an input code (0–65535)")
        }
        try await runAutomation(display, .input, .raw(raw))
        return .result()
    }
}

// MARK: - Presets

/// Applies a stored DDC preset by name.
///
/// It takes a preset entity rather than a raw identifier so the shortcut shows
/// the user's own names in the picker, and it adds no capability: the preset is
/// expanded into one `AutomationRequest` per setting, each planned by the same
/// rule this file's other intents go through. A preset carries brightness,
/// contrast and volume and cannot carry an input source — `DDCPreset`'s header
/// sets out why — so "run my Night preset on a timer" can never be the thing
/// that blanks a screen while nobody is watching.
struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource { "Apply Preset" }
    static var description: IntentDescription {
        // One literal, for the same reason `SwitchInputIntent`'s is: an
        // `IntentDescription` takes a `LocalizedStringResource`, which is a
        // literal type, and splitting it would change its catalog key.
        // swiftlint:disable:next line_length - localized literal
        IntentDescription("Applies a saved Crisp preset: brightness, contrast and volume for each display it names. Displays that are not connected are skipped.")
    }

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply preset \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let outcome = await AutomationService.shared.applyPreset(id: preset.id, origin: .appIntent)
        guard outcome.didApply else { throw CrispIntentError.refused(outcome.message) }
        return .result()
    }
}

// MARK: - Reading

struct GetDisplayInfoIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Display Info" }
    static var description: IntentDescription {
        IntentDescription("Returns what Crisp last read from a display: brightness, contrast, volume and input source.")
    }

    @Parameter(title: "Display")
    var display: DisplayEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get info about \(\.$display)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<DisplayEntity> {
        // Re-read from the live display rather than returning the entity the
        // shortcut was authored with: that one is a snapshot from whenever the
        // picker was shown, possibly weeks ago.
        guard let live = AutomationService.shared.display(for: DisplayUUID(display.id)) else {
            throw CrispIntentError.refused("no attached display has the identifier \(display.id)")
        }
        return .result(value: DisplayEntity(live))
    }
}

struct RefreshDisplaysIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh Displays" }
    static var description: IntentDescription {
        IntentDescription("Re-enumerates displays and re-reads their DDC features. Reads only; nothing is written.")
    }

    /// A menu-bar-only app has nothing to bring to the front, and a shortcut that
    /// activated it would steal focus for a refresh the user cannot see.
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        AutomationService.shared.refreshDisplays()
        return .result()
    }
}

// MARK: - Voice / Spotlight shortcuts

/// The one phrase worth offering without the user assembling anything: a
/// refresh. Every other intent needs a display and a value, which a canned
/// phrase cannot supply without guessing at one.
struct CrispAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshDisplaysIntent(),
            phrases: ["Refresh \(.applicationName) displays"],
            shortTitle: "Refresh Displays",
            systemImageName: "arrow.clockwise"
        )
    }
}
