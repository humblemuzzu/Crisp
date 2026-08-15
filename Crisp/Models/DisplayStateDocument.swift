import Foundation

/// The persisted shape of Crisp's per-display state, plus the pure v1 → v2
/// migration. No file or `UserDefaults` access lives here — `DisplayStateStore`
/// owns all I/O — so this half is exercised headlessly from `CrispTests`
/// (same route as `GammaPersistenceKey` / `DDCServiceMatcher`).
///
/// Why a document instead of the flat `crisp.ddcState.<uuid>.<field>` defaults
/// it replaces: flat keys cannot be migrated atomically (a crash between two
/// `set(_:forKey:)` calls leaves half a display's settings behind), cannot be
/// versioned, and cannot be pasted into a bug report. One versioned JSON file
/// fixes all three.

/// Everything Crisp persists about one physical display.
///
/// Every field is optional, for two reasons that both matter:
/// 1. a document written by an older (or newer) build still decodes — missing
///    keys simply stay `nil` instead of failing the whole document; and
/// 2. "never set" stays distinguishable from "set to 0 / false". Reconnect
///    reapply keys off exactly that distinction: a `nil` brightness means *do
///    not touch the monitor*, while `0` means the user really did drag it down.
struct DisplayState: Codable, Equatable, Sendable {
    /// Last DDC brightness the user applied, 0–100 (VCP 0x10).
    var brightness: Double?
    /// Last DDC contrast the user applied, 0–100 (VCP 0x12).
    var contrast: Double?
    /// Last DDC speaker volume the user applied, 0–100 (VCP 0x62).
    var volume: Double?
    /// Raw VCP 0x60 input-source code, as the monitor reports it. Not a VESA
    /// enum: several monitors (the BenQ MA320U among them) use their own codes.
    var input: UInt16?
    /// Opt-in, per display: re-apply `input` when this display reconnects. Off
    /// by default because a stale code can point at a port with nothing in it.
    var reapplyInputOnReconnect: Bool?
    /// Gamma dimming factor (0.05–1.0) for the sub-DDC region of the combined
    /// brightness model. 1.0 means "no software dimming".
    var softwareBrightnessFactor: Double?
    /// True once the monitor has *ever* answered a VCP 0x62 read. Remembered
    /// permanently: DDC probes fail transiently, and without the memory the
    /// volume slider and key routing would vanish for that session.
    var volumeCapable: Bool?
    /// Membership of the brightness-key "selected displays" set, used when
    /// `SettingsService.brightnessKeyTarget == .selected`.
    var brightnessKeySelected: Bool?

    init(
        brightness: Double? = nil,
        contrast: Double? = nil,
        volume: Double? = nil,
        input: UInt16? = nil,
        reapplyInputOnReconnect: Bool? = nil,
        softwareBrightnessFactor: Double? = nil,
        volumeCapable: Bool? = nil,
        brightnessKeySelected: Bool? = nil
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.volume = volume
        self.input = input
        self.reapplyInputOnReconnect = reapplyInputOnReconnect
        self.softwareBrightnessFactor = softwareBrightnessFactor
        self.volumeCapable = volumeCapable
        self.brightnessKeySelected = brightnessKeySelected
    }

    /// Nothing is remembered for this display, so the store can drop the entry
    /// rather than keep an empty object around forever (turning a toggle off
    /// should leave no trace, the same way clearing a `UserDefaults` key did).
    var isEmpty: Bool { self == DisplayState() }
}

/// The whole file: `{ "version": 2, "displays": { "<uuid>": { … } } }`.
struct DisplayStateDocument: Codable, Equatable, Sendable {
    /// v1 was the flat `UserDefaults` layout this replaces; v2 is this document.
    static let currentVersion = 2

    var version: Int
    var displays: [DisplayUUID: DisplayState]

    init(version: Int = DisplayStateDocument.currentVersion, displays: [DisplayUUID: DisplayState] = [:]) {
        self.version = version
        self.displays = displays
    }

    /// Tolerant decoding: both members default rather than throw, so a
    /// hand-edited or half-written-by-an-older-build document still loads.
    /// A document stamped with a *newer* version is read on the same terms —
    /// fields this build does not know are dropped on the next save, which is
    /// the accepted cost of rolling back (the v1 defaults are kept as a second
    /// rollback path; see `DisplayStateMigration`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.displays = try container.decodeIfPresent([DisplayUUID: DisplayState].self, forKey: .displays) ?? [:]
    }

    /// Decodes without ever throwing at the caller: unreadable or corrupt JSON
    /// degrades to an empty document (AGENTS.md rule #4 — nothing about
    /// persistence may take the app down). The failure is returned rather than
    /// swallowed so the I/O layer can log it.
    static func decoding(_ data: Data) -> (document: DisplayStateDocument, failure: Error?) {
        do {
            return (try JSONDecoder().decode(DisplayStateDocument.self, from: data), nil)
        } catch {
            return (DisplayStateDocument(), error)
        }
    }
}

/// One value read out of the v1 `UserDefaults` layout.
///
/// `UserDefaults` erases `Bool` to an `NSNumber`, so a reader that inspects the
/// stored value cannot tell a flag from a number. Interpretation is therefore
/// per key and lives here, not at the read site: `.number` and `.flag` are
/// mutually convertible on purpose.
enum LegacyDefaultsValue: Equatable, Sendable {
    case number(Double)
    case flag(Bool)
    case list([String])

    var numberValue: Double? {
        switch self {
        case .number(let value): return value
        case .flag(let flag): return flag ? 1 : 0
        case .list: return nil
        }
    }

    var flagValue: Bool? {
        switch self {
        case .number(let value): return value != 0
        case .flag(let flag): return flag
        case .list: return nil
        }
    }

    var listValue: [String]? {
        switch self {
        case .list(let items): return items
        case .number, .flag: return nil
        }
    }
}

/// Pure v1 → v2 migration: flat `UserDefaults` keys in, one document out.
///
/// The legacy keys are deliberately **not** deleted by the caller. Leaving them
/// lets a user roll back to the pre-store build and find their settings intact;
/// they cost a few hundred bytes and are ignored from here on. A later phase can
/// drop them once this build has shipped for a while.
enum DisplayStateMigration {
    static let ddcStatePrefix = "crisp.ddcState."
    static let softwareBrightnessPrefix = "crisp.softBrightness.uuid."
    static let volumeCapableKey = "crisp.volumeCapableDisplays"
    static let brightnessKeySelectedKey = "crisp.brightnessKeySelectedDisplays"

    /// Which `UserDefaults` keys the caller has to hand over. Keeps key
    /// knowledge in one place: the store just filters its snapshot with this.
    ///
    /// `crisp.softBrightness_<displayID>` is absent on purpose. It is keyed by
    /// the volatile `CGDirectDisplayID`, so mapping it to a UUID requires the
    /// display to be online — that is `BrightnessService`'s
    /// `migrateLegacySoftBrightnessIfNeeded`, which runs per display refresh.
    /// Guessing here is exactly the bug issue #32 fixed.
    static func isLegacyKey(_ key: String) -> Bool {
        key.hasPrefix(ddcStatePrefix)
            || key.hasPrefix(softwareBrightnessPrefix)
            || key == volumeCapableKey
            || key == brightnessKeySelectedKey
    }

    /// Folds the legacy values into `document`.
    ///
    /// Idempotent in the strong sense: an existing non-`nil` field always wins,
    /// so re-running over a document that already holds newer state cannot
    /// resurrect a stale v1 value (same rule as `AppDelegate`'s `fd.*` → `crisp.*`
    /// namespace migration).
    static func migrated(
        legacy: [String: LegacyDefaultsValue],
        into document: DisplayStateDocument
    ) -> DisplayStateDocument {
        var result = document
        result.version = DisplayStateDocument.currentVersion

        for (key, value) in legacy {
            if let (uuid, field) = ddcStateField(from: key) {
                apply(value, field: field, to: &result.displays[uuid, default: DisplayState()])
            } else if key.hasPrefix(softwareBrightnessPrefix) {
                let uuid = DisplayUUID(String(key.dropFirst(softwareBrightnessPrefix.count)))
                fill(&result.displays[uuid, default: DisplayState()].softwareBrightnessFactor, with: value.numberValue)
            } else if key == volumeCapableKey {
                for uuid in value.listValue ?? [] {
                    fill(&result.displays[DisplayUUID(uuid), default: DisplayState()].volumeCapable, with: true)
                }
            } else if key == brightnessKeySelectedKey {
                for uuid in value.listValue ?? [] {
                    fill(&result.displays[DisplayUUID(uuid), default: DisplayState()].brightnessKeySelected, with: true)
                }
            }
        }

        // A malformed key (e.g. "crisp.ddcState..brightness") can mint an entry
        // that ends up holding nothing; don't carry it into the document.
        result.displays = result.displays.filter { !$0.value.isEmpty }
        return result
    }

    private static func apply(_ value: LegacyDefaultsValue, field: String, to state: inout DisplayState) {
        switch field {
        case "brightness": fill(&state.brightness, with: value.numberValue)
        case "contrast": fill(&state.contrast, with: value.numberValue)
        case "volume": fill(&state.volume, with: value.numberValue)
        case "input": fill(&state.input, with: value.numberValue.map(inputCode(from:)))
        case "reapplyInput": fill(&state.reapplyInputOnReconnect, with: value.flagValue)
        default: break  // an unknown field is a key we no longer write; ignore it
        }
    }

    /// `UInt16(someDouble)` traps outside 0…65535, and the v1 reader did exactly
    /// that on a value it never validated. Clamping keeps a garbage default from
    /// crashing the app at launch, one line after the document that was supposed
    /// to make persistence unable to do that.
    private static func inputCode(from value: Double) -> UInt16 {
        UInt16(max(0, min(Double(UInt16.max), value.rounded())))
    }

    /// Existing state wins; only an unset field takes the legacy value.
    private static func fill<T>(_ target: inout T?, with value: T?) {
        guard target == nil, let value else { return }
        target = value
    }

    private static func ddcStateField(from key: String) -> (uuid: DisplayUUID, field: String)? {
        guard key.hasPrefix(ddcStatePrefix) else { return nil }
        // UUID strings (and the vendor/model/serial fallback) never contain a
        // dot, so the last dot always separates the uuid from the field name.
        let rest = key.dropFirst(ddcStatePrefix.count)
        guard let separator = rest.lastIndex(of: "."), separator > rest.startIndex else { return nil }
        let field = String(rest[rest.index(after: separator)...])
        guard !field.isEmpty else { return nil }
        return (DisplayUUID(String(rest[..<separator])), field)
    }
}
