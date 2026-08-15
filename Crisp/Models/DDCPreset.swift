import Foundation

// A named snapshot of DDC settings, and the pure rule that turns one into a list
// of writes. Foundation only, so both live in `CrispTests` (AGENTS.md §3.6).
//
// Distinct from upstream's `DisplayPreset` (`Crisp/Models/DisplayPreset.swift`),
// which snapshots *resolution and arrangement* through CoreGraphics. This one
// only ever touches the monitor's own registers over DDC, and the two are kept
// apart rather than merged because their failure modes have nothing in common: a
// wrong resolution is undone from System Settings, a wrong DDC write may not be
// undoable from the Mac at all.
//
// ---------------------------------------------------------------------------
// WHY A PRESET CANNOT CARRY AN INPUT SOURCE
// ---------------------------------------------------------------------------
// The obvious fourth field is input (VCP 0x60). It is deliberately absent, and
// absent from the *type*, not merely unset — there is no field to fill in, so no
// future call site can populate one by accident.
//
// The registry marks 0x60 destructive because switching to a port with nothing
// attached blanks the screen and only the monitor's own buttons can undo it.
// Every destructive write in this app needs a `DestructiveWriteConsent`, minted
// only at a real confirmation site, and none of the three that exist fits a
// preset:
//
//   - `PanelConfirmation` needs the panel's alert on screen. A preset spanning
//     three displays would need three alerts, one per display, and
//     `AutomationService` refuses a second confirmation while one is up — so all
//     but the first would silently do nothing.
//   - `AutomationService.UserConsent` needs its `NSAlert` answered. A *scheduled*
//     preset firing at 22:00 puts that alert on a machine nobody is sitting at.
//   - `DDCFeatureService.RestoredUserChoice` refuses any value other than the one
//     already on record for that display, so a preset built on it could only ever
//     re-assert the input the monitor is already remembered on: a no-op.
//
// Declaring a fourth conformer would work and is exactly what the note in
// AGENTS.md §6 warns about. The deeper reason not to is that a preset's whole
// value is "one click, no thinking", and input switching is the one write where
// thinking is mandatory. Putting them together does not make presets more
// capable; it turns the one dialog that matters into something the user learns
// to dismiss. So presets carry the three percent-shaped, non-destructive
// controls, and switching an input stays a deliberate, separate act.
//
// `DDCPresetTests` pins that as a property over the whole registry rather than as
// this comment: every feature a preset may carry must be continuous,
// non-destructive and one Crisp drives end to end. Adding a destructive one fails
// the suite.

/// What a preset remembers for one display. Every field optional, on the same
/// terms as `DisplayState`: `nil` means "this preset does not touch it", which
/// stays distinguishable from `0`.
struct DDCPresetSettings: Codable, Equatable, Sendable {
    /// DDC brightness percent (VCP 0x10).
    var brightness: Double?
    /// DDC hardware contrast percent (VCP 0x12).
    var contrast: Double?
    /// DDC speaker volume percent (VCP 0x62).
    var volume: Double?

    init(brightness: Double? = nil, contrast: Double? = nil, volume: Double? = nil) {
        self.brightness = brightness
        self.contrast = contrast
        self.volume = volume
    }

    /// Nothing to apply. Such an entry is dropped rather than carried around,
    /// the same way `DisplayState.isEmpty` lets the store drop a blank display.
    var isEmpty: Bool { self == DDCPresetSettings() }

    /// This preset's value for one feature, or nil. Keyed by the registry's own
    /// identifier so the planner below stays generic over `DDCPresetPlan.features`
    /// instead of repeating a three-way switch per call site.
    func value(for feature: DDCFeatureID) -> Double? {
        switch feature {
        case .brightness: return brightness
        case .contrast: return contrast
        case .volume: return volume
        default: return nil
        }
    }

    mutating func setValue(_ value: Double?, for feature: DDCFeatureID) {
        switch feature {
        case .brightness: brightness = value
        case .contrast: contrast = value
        case .volume: volume = value
        default: break
        }
    }
}

/// A named snapshot of DDC settings across any number of displays.
struct DDCPreset: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity as a string: it is what `crisp://preset/<id>` quotes and
    /// what `crispctl preset apply` takes, so it has to survive a copy-paste.
    var id: String
    var name: String
    /// Per display, keyed by the identity that survives a reconnect
    /// (AGENTS.md rule #3).
    var settings: [DisplayUUID: DDCPresetSettings]

    init(id: String = UUID().uuidString, name: String, settings: [DisplayUUID: DDCPresetSettings] = [:]) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    /// Tolerant on the fields that can be missing, strict on the two it cannot
    /// exist without — and `LossyList` turns that strictness into "drop this
    /// preset", never "the document is corrupt".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.settings = try container.decodeIfPresent(
            [DisplayUUID: DDCPresetSettings].self, forKey: .settings
        ) ?? [:]
    }

    /// Entries that would apply nothing are dropped: they are invisible in the
    /// UI and would otherwise accumulate for every display ever unplugged.
    func normalized() -> DDCPreset {
        var copy = self
        copy.settings = settings.filter { !$0.value.isEmpty }
        return copy
    }

    /// How many displays this preset would touch, for a one-line subtitle.
    var displayCount: Int { normalized().settings.count }
}

/// Turning a preset into the writes it means. Pure, ordered, total.
enum DDCPresetPlan {

    /// The features a preset may carry, in the order they are applied.
    ///
    /// This list is the feature's safety boundary and is asserted against the
    /// registry in `DDCPresetTests`: every entry must be percent-shaped (so a
    /// value cannot be an enumeration in disguise), non-destructive (so applying
    /// a preset can never need a confirmation the user is not present for), and
    /// one Crisp drives end to end (so there is a control that shows what it
    /// did). Adding `.input` here fails that test rather than shipping.
    static let features: [DDCFeatureID] = [.brightness, .contrast, .volume]

    /// One write a preset asks for.
    struct Step: Equatable, Sendable {
        let display: DisplayUUID
        let feature: DDCFeatureID
        /// Clamped to 0…100. A percentage is all a preset can express; the raw
        /// range the monitor wants is resolved per display, far below this.
        let percent: Double
    }

    /// The writes `preset` means right now.
    ///
    /// - Parameter attached: the displays connected at this moment. A display
    ///   that is not attached contributes no steps — **a no-op for that display,
    ///   not an error** — because a preset outlives the desk it was captured on
    ///   and refusing the whole thing would make presets useless on a laptop.
    ///
    /// Ordered by display identifier and then by `features`, so a run is
    /// reproducible and a test can compare the whole list.
    static func steps(for preset: DDCPreset, attached: Set<DisplayUUID>) -> [Step] {
        preset.settings.keys
            .filter { attached.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
            .flatMap { display -> [Step] in
                guard let settings = preset.settings[display] else { return [] }
                return features.compactMap { feature in
                    guard let value = settings.value(for: feature), value.isFinite else { return nil }
                    return Step(display: display, feature: feature, percent: clamp(value))
                }
            }
    }

    /// The displays a preset names that are not attached, so the UI can say
    /// "2 of 3 displays" instead of quietly doing less than it looks like.
    static func missingDisplays(for preset: DDCPreset, attached: Set<DisplayUUID>) -> [DisplayUUID] {
        preset.normalized().settings.keys
            .filter { !attached.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func clamp(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent, 0), 100)
    }
}
