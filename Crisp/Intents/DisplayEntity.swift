import AppIntents
import Foundation

// The display, as Shortcuts sees it.
//
// **The identity is the whole design decision here.** A `CGDirectDisplayID` is
// what every macOS display API hands out, and it is exactly the wrong thing to
// put in a shortcut: macOS reassigns those ids across reconnects (upstream issue
// #32), so a shortcut built today against "display 3" would, next week, dim
// whichever panel inherited the number. `DisplayEntity.id` is therefore the
// `DisplayUUID` — the same stable identity every piece of per-display
// persistence in this app keys on (AGENTS.md §3.3) — and the entity is looked up
// by it on every run.
//
// A shortcut that names a display that is not attached is not an error worth
// stopping an automation over: `entities(for:)` simply returns nothing for it and
// the intent refuses with a sentence saying which identifier it could not find.

/// One attached display, addressable from Shortcuts.
///
/// The DDC values are a snapshot taken when the entity was built. They are what
/// the app last read from the monitor, not a fresh I2C transaction: reading four
/// registers per display every time Shortcuts renders a picker would put the
/// monitor's bus under a UI's refresh rate. `RefreshDisplaysIntent` is the
/// explicit way to re-probe.
struct DisplayEntity: AppEntity, Identifiable {

    /// The stable per-display UUID, as a string. Never a `CGDirectDisplayID`.
    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Brightness")
    var brightness: Double

    @Property(title: "Contrast")
    var contrast: Double

    @Property(title: "Volume")
    var volume: Double

    /// The monitor's raw VCP 0x60 code, not a port name: the BenQ MA320U reports
    /// `19`, which is not a standard VESA value, and inventing a name for it in a
    /// shortcut's output would state a guess as fact (AGENTS.md §6).
    @Property(title: "Input source code")
    var inputSource: Int

    /// The label the panel shows for that code, question mark and all — a "?"
    /// means the database has the name second-hand and nobody has confirmed it on
    /// this model.
    @Property(title: "Input source")
    var inputLabel: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Display")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(Int(brightness.rounded()))% brightness"
        )
    }

    static var defaultQuery: DisplayEntityQuery { DisplayEntityQuery() }

    init(
        id: String, name: String, brightness: Double, contrast: Double,
        volume: Double, inputSource: Int, inputLabel: String
    ) {
        self.id = id
        self.name = name
        self.brightness = brightness
        self.contrast = contrast
        self.volume = volume
        self.inputSource = inputSource
        self.inputLabel = inputLabel
    }

    /// A snapshot of one live display. Main-actor isolated because `DisplayInfo`
    /// is the app's observable model, and everything Shortcuts calls hops there
    /// anyway.
    @MainActor
    init(_ display: DisplayInfo) {
        self.init(
            id: display.stateUUID.rawValue,
            name: display.name,
            brightness: display.brightness,
            contrast: display.contrastSupported ? display.contrast : 0,
            volume: display.volumeSupported ? display.volume : 0,
            inputSource: display.inputSourceSupported ? Int(display.inputSource) : 0,
            inputLabel: display.inputSourceSupported
                ? DDCFeatureService.shared.inputLabel(for: display)
                : ""
        )
    }
}

/// How Shortcuts finds displays: by the UUID a saved shortcut carries, and by
/// asking what is attached right now when the user is picking one.
struct DisplayEntityQuery: EntityQuery {

    /// Resolves the identifiers stored in a saved shortcut. A display that is not
    /// attached simply does not come back — the intent then refuses by name
    /// rather than acting on a different display.
    @MainActor
    func entities(for identifiers: [DisplayEntity.ID]) async throws -> [DisplayEntity] {
        let wanted = Set(identifiers)
        return AutomationService.shared.displays
            .filter { wanted.contains($0.stateUUID.rawValue) }
            .map(DisplayEntity.init)
    }

    /// What the picker offers: the displays attached right now, by name.
    @MainActor
    func suggestedEntities() async throws -> [DisplayEntity] {
        AutomationService.shared.displays.map(DisplayEntity.init)
    }
}
