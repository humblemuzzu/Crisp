import AppIntents
import Foundation

// The Shortcuts surface for paired smart TVs.
//
// Same shape as `CrispIntents.swift` and for the same reason: every intent builds
// a `TVActionRequest`, hands it to `AutomationService.performTV`, and turns the
// outcome into a result or an error. None of them opens a socket, resolves a
// device, clamps a value, or decides what a destructive action may do. That is
// `TVActionRequest.plan` and `TVWriteGate` beneath it, shared with the `crisp://`
// grammar so the two surfaces cannot drift into two policies.
//
// `TurnOffTVIntent` and `SwitchTVInputIntent` are not special-cased. Both are
// destructive in `TVFeatureRegistry` — a TV switched to an empty input is a black
// screen, and a TV switched off cannot be switched back on over this protocol at
// all — so their plans come back `needsConfirmation` and `AutomationService` asks
// the user with the same dialog a destructive DDC write gets. A shortcut is
// authored by a person but *triggered* by a time of day, a location or another
// app, none of which is a person watching the screen it is about to blank.

/// One paired TV, addressable from Shortcuts.
///
/// The identity is the TV's own UUID and never its address: a shortcut built
/// today against `192.168.1.40` would, after a DHCP lease expires, be aimed at
/// whatever else took that address. Same argument as `DisplayEntity`'s, one
/// identifier space over.
struct TVDeviceEntity: AppEntity, Identifiable {
    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Platform")
    var platform: String

    @Property(title: "Address")
    var host: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "TV")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(platform)")
    }

    static var defaultQuery: TVDeviceEntityQuery { TVDeviceEntityQuery() }

    init(id: String, name: String, platform: String, host: String) {
        self.id = id
        self.name = name
        self.platform = platform
        self.host = host
    }

    init(_ device: TVDevice) {
        self.init(
            id: device.id.rawValue, name: device.name,
            platform: device.platform.title, host: device.host
        )
    }
}

struct TVDeviceEntityQuery: EntityQuery {
    /// Resolves the identifiers a saved shortcut carries. A TV the user has since
    /// removed simply does not come back, and the intent refuses by name rather
    /// than acting on a different television.
    @MainActor
    func entities(for identifiers: [TVDeviceEntity.ID]) async throws -> [TVDeviceEntity] {
        let wanted = Set(identifiers)
        return TVDeviceService.shared.devices
            .filter { wanted.contains($0.id.rawValue) }
            .map(TVDeviceEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TVDeviceEntity] {
        TVDeviceService.shared.devices.map(TVDeviceEntity.init)
    }
}

/// Shared plumbing: run one TV action and turn a refusal into a thrown error.
private func runTVAutomation(
    _ device: TVDeviceEntity, _ feature: TVFeatureID, _ value: TVActionValue
) async throws {
    let request = TVActionRequest(
        origin: .appIntent, device: TVDeviceID(device.id), feature: feature, value: value
    )
    let outcome = await AutomationService.shared.performTV(request)
    guard outcome.didApply else { throw CrispIntentError.refused(outcome.message) }
}

// MARK: - Non-destructive

struct SetTVBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource { "Set TV Brightness" }
    static var description: IntentDescription {
        // One literal: `IntentDescription` takes a `LocalizedStringResource`,
        // which is a literal type, and splitting it would change the catalog key.
        // swiftlint:disable:next line_length - localized literal
        IntentDescription("Sets a paired LG (webOS) TV's backlight over the network. Samsung (Tizen) TVs expose no brightness command at all, so this refuses with the reason rather than doing nothing.")
    }

    @Parameter(title: "TV")
    var tv: TVDeviceEntity

    @Parameter(title: "Brightness", inclusiveRange: (0, 100))
    var value: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set brightness of \(\.$tv) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runTVAutomation(tv, .brightness, .percent(value))
        return .result()
    }
}

struct SetTVVolumeIntent: AppIntent {
    static var title: LocalizedStringResource { "Set TV Volume" }
    static var description: IntentDescription {
        IntentDescription("Sets a paired TV's volume over the network.")
    }

    @Parameter(title: "TV")
    var tv: TVDeviceEntity

    @Parameter(title: "Volume", inclusiveRange: (0, 100))
    var value: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set volume of \(\.$tv) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runTVAutomation(tv, .volume, .percent(value))
        return .result()
    }
}

struct SetTVMuteIntent: AppIntent {
    static var title: LocalizedStringResource { "Mute TV" }
    static var description: IntentDescription {
        IntentDescription("Mutes or unmutes a paired TV.")
    }

    @Parameter(title: "TV")
    var tv: TVDeviceEntity

    @Parameter(title: "Muted")
    var muted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set mute of \(\.$tv) to \(\.$muted)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runTVAutomation(tv, .mute, .flag(muted))
        return .result()
    }
}

// MARK: - Destructive

/// Turns a TV off. Off only, and that asymmetry is the point.
///
/// The control socket goes down with the television, so nothing on this protocol
/// can turn it back on — that needs Wake-on-LAN, a different mechanism at a
/// different layer, and offering a "turn on" that never works would be worse than
/// offering nothing. Hence a `Turn Off` intent rather than a power toggle.
struct TurnOffTVIntent: AppIntent {
    static var title: LocalizedStringResource { "Turn TV Off" }
    static var description: IntentDescription {
        // swiftlint:disable:next line_length - localized literal
        IntentDescription("Turns a paired TV off, after asking. Crisp always asks: the control connection goes down with the TV, so Crisp cannot turn it back on — only its own remote can.")
    }

    @Parameter(title: "TV")
    var tv: TVDeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Turn off \(\.$tv)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runTVAutomation(tv, .power, .flag(false))
        return .result()
    }
}

/// Switches a TV's input.
///
/// The value is the TV's own identifier — `HDMI_1` on webOS, `KEY_HDMI2` on
/// Tizen — and not a friendly port name, for the same reason `SwitchInputIntent`
/// takes a raw VCP code: the identifiers are not portable between platforms or
/// models, and offering "HDMI 1" would state a guess as fact. The panel's TV
/// section lists the identifiers an LG reports for itself; on a Samsung, where
/// nothing local can be read back, `KEY_SOURCE` opens the source list and lets
/// the user pick.
struct SwitchTVInputIntent: AppIntent {
    static var title: LocalizedStringResource { "Switch TV Input" }
    static var description: IntentDescription {
        // swiftlint:disable:next line_length - localized literal
        IntentDescription("Switches a paired TV to another input, after asking. Crisp always asks: if nothing is attached to that input the screen goes blank, and on Samsung TVs Crisp cannot even read which input it landed on.")
    }

    @Parameter(title: "TV")
    var tv: TVDeviceEntity

    @Parameter(title: "Input identifier")
    var input: String

    static var parameterSummary: some ParameterSummary {
        Summary("Switch \(\.$tv) to input \(\.$input)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runTVAutomation(tv, .input, .code(input))
        return .result()
    }
}
