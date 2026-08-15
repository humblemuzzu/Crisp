import Foundation

// Display groups and the brightness-sync arithmetic, as data and one pure
// function. No AppKit, no service, no monitor: the whole rule runs in
// `CrispTests` (AGENTS.md §3.6), which is the only way the properties below can
// be *proved* rather than watched for.
//
// ---------------------------------------------------------------------------
// WHY TWO SYNC MODES, AND WHY RELATIVE IS THE DEFAULT
// ---------------------------------------------------------------------------
// "Set both monitors to 40%" sounds like one operation. It is not. DDC
// brightness is a percentage of *that panel's* backlight range, and the ranges
// are not comparable between panels: this fork's own BenQ MA320U sits at roughly
// 59 nits at DDC 0 (`reference/benq-ma320u.md`), which is a normal room
// brightness, while another panel's 0 is nearly dark. Absolute sync on a mixed
// desk therefore does not make two screens look alike — it makes one of them
// wrong, every time the other moves.
//
// Relative sync keeps the *difference the user already dialled in*. The offsets
// are captured once, when sync is armed, and preserved from then on. It is the
// default because it is the mode that respects a setting the user arrived at by
// looking at their own screens.
//
// ---------------------------------------------------------------------------
// OSCILLATION, AND THE THREE THINGS THAT PREVENT IT
// ---------------------------------------------------------------------------
// The failure mode of every sync feature: A moves, B follows, B's change is
// observed as a change, A follows B, and the group hunts. Three separate things
// stop it here, and only the first is a design rather than a patch:
//
//   1. **An origin token.** `targets` refuses to plan anything for a change that
//      is itself a sync (`BrightnessChangeOrigin.groupSync`). A propagation is
//      therefore one level deep by construction, whatever the services above
//      it do with notifications. A pure, exhaustively testable property.
//   2. **Followers are computed from the mover, never from each other.** Every
//      target is `mover + (baseline_member − baseline_mover)`. No follower's
//      value is ever an input, so a member pinned at 0 or 100 by the clamp
//      cannot drag the group towards it — its clamped value is simply never read
//      back.
//   3. **A deadband.** A member already within `deadband` of its target is left
//      alone, which makes a second identical propagation a no-op and keeps the
//      I²C bus free of writes that change nothing.

/// How a group's members follow each other's brightness.
enum BrightnessSyncMode: String, Codable, Sendable, CaseIterable {
    /// Every member lands on the same percentage. Correct for identical panels,
    /// wrong for mixed ones — see the header.
    case absolute
    /// Every member keeps the offset it had when sync was armed.
    case relative

    /// What an unreadable or future mode decodes to. The safe answer is the one
    /// that preserves what the user set rather than flattening it.
    static let fallback: BrightnessSyncMode = .relative
}

/// A named set of displays whose brightness moves together.
///
/// Keyed on `DisplayUUID` throughout (AGENTS.md rule #3): a group built today
/// must still mean the same two physical panels after a reconnect has shuffled
/// every `CGDirectDisplayID`.
struct DisplayGroup: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity, as a string rather than a `UUID` so the JSON is
    /// hand-editable and a `crisp://` link can quote it verbatim.
    var id: String
    var name: String
    /// Order is the user's; duplicates are removed on load (`normalized`).
    var members: [DisplayUUID]
    var syncMode: BrightnessSyncMode
    /// The percentage each member was on when relative sync was armed. Empty
    /// means "never armed", and `targets` then falls back to the live values,
    /// which is the same thing as arming it at the moment of the first move.
    var baselines: [DisplayUUID: Double]

    init(
        id: String = UUID().uuidString,
        name: String,
        members: [DisplayUUID] = [],
        syncMode: BrightnessSyncMode = .relative,
        baselines: [DisplayUUID: Double] = [:]
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.syncMode = syncMode
        self.baselines = baselines
    }

    /// Tolerant decoding, on the same terms as the rest of the document: an
    /// absent `syncMode` (or one a newer build invented) reads as `.relative`
    /// rather than failing the group. `id` and `name` are the two fields a group
    /// cannot be without, so those do throw — and `LossyList` turns that into
    /// "this one entry is dropped", not "the file is corrupt".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.members = try container.decodeIfPresent([DisplayUUID].self, forKey: .members) ?? []
        // `try?` rather than `try`: this has to cover both "absent" and "a mode
        // a newer build invented", which mean the same thing here.
        self.syncMode = (try? container.decodeIfPresent(BrightnessSyncMode.self, forKey: .syncMode))
            ?? BrightnessSyncMode.fallback
        self.baselines = try container.decodeIfPresent([DisplayUUID: Double].self, forKey: .baselines) ?? [:]
    }

    /// A group with the same displays listed twice would double-write one
    /// monitor and make the offsets ambiguous; a baseline for a display that is
    /// not a member is dead weight that survives every rename. Both are repaired
    /// on load rather than guarded against at every read site.
    func normalized() -> DisplayGroup {
        var seen: Set<DisplayUUID> = []
        let members = self.members.filter { seen.insert($0).inserted }
        var copy = self
        copy.members = members
        copy.baselines = baselines.filter { seen.contains($0.key) }
        return copy
    }

    /// Sync does nothing below two members, so the UI can say so instead of
    /// showing a control that cannot act.
    var isActionable: Bool { members.count > 1 }
}

/// Why a brightness value moved.
///
/// The token that makes non-oscillation a property rather than a hope: it is
/// carried from whoever asked for the change into `BrightnessSync.targets`,
/// which plans nothing for a change that is already a sync. A service can add
/// re-entrancy guards on top — `DisplayGroupService` does — but the rule itself
/// does not depend on them.
enum BrightnessChangeOrigin: Equatable, Sendable {
    /// A slider, a brightness key, a preset, a `crisp://` URL — anything whose
    /// root cause is a person or a schedule they set up.
    case user
    /// This value was itself written by a group propagation. Never propagated
    /// again, from any mode, at any depth.
    case groupSync(groupID: String)

    var isUser: Bool { self == .user }
}

/// The sync arithmetic. Pure, total, and the only place that decides what a
/// group member's new brightness is.
enum BrightnessSync {

    /// Brightness is a percentage everywhere above the DDC transport; the raw
    /// range a monitor actually wants is resolved per display far below this.
    static let range: ClosedRange<Double> = 0...100

    /// A member already this close to its target is left alone. Sized to be
    /// below one step of any control the app offers (the sliders and the
    /// brightness keys both move in whole percent), so it can only ever swallow
    /// a change nobody asked for — a rounding difference, or the second half of
    /// a propagation that has already happened.
    static let deadband: Double = 0.5

    /// One member's new brightness, and the origin the write must carry so that
    /// observing it cannot start another round.
    struct Target: Equatable, Sendable {
        let display: DisplayUUID
        let value: Double
        let origin: BrightnessChangeOrigin
    }

    /// The baselines to store when relative sync is armed: whatever each member
    /// is on right now. A member with no live reading is simply not baselined,
    /// and `targets` treats it as "capture at first move".
    static func baselines(
        for members: [DisplayUUID], current: [DisplayUUID: Double]
    ) -> [DisplayUUID: Double] {
        var captured: [DisplayUUID: Double] = [:]
        for member in members {
            guard let value = current[member], value.isFinite else { continue }
            captured[member] = clamp(value)
        }
        return captured
    }

    /// What the other members of `group` should become, now that `movedDisplay`
    /// has been set to `value`.
    ///
    /// - Parameters:
    ///   - origin: why `movedDisplay` moved. Anything but `.user` plans nothing;
    ///     this is the non-oscillation rule and it is checked first.
    ///   - current: the live percentage per display, for the deadband and for
    ///     the un-baselined fallback. A member missing from it is still planned
    ///     for — a display whose value is unknown is not a display to skip.
    ///   - attached: the displays connected right now. A member that is not is a
    ///     no-op, never an error (a group outlives an unplugged monitor).
    ///
    /// The result is ordered by identifier so a test can compare it whole and a
    /// log line reads the same way twice.
    static func targets(
        in group: DisplayGroup,
        movedDisplay: DisplayUUID,
        to value: Double,
        origin: BrightnessChangeOrigin,
        current: [DisplayUUID: Double],
        attached: Set<DisplayUUID>
    ) -> [Target] {
        // 1. The origin rule. First, because no later check can undo a round of
        //    propagation that has already been planned.
        guard origin.isUser else { return [] }
        // 2. `NaN` is not a brightness. Refused before the clamp, because
        //    `min(100, .nan)` is 100 in Swift and a non-number would arrive as
        //    full brightness on every other monitor in the group.
        guard value.isFinite else { return [] }
        guard group.isActionable, group.members.contains(movedDisplay) else { return [] }

        let moved = clamp(value)
        let syncOrigin = BrightnessChangeOrigin.groupSync(groupID: group.id)

        return group.members
            .filter { $0 != movedDisplay && attached.contains($0) }
            .compactMap { member -> Target? in
                let target = clamp(self.target(for: member, movedTo: moved, movedDisplay: movedDisplay,
                                               group: group, current: current))
                // 3. The deadband. A member with no live reading has nothing to
                //    compare against, so it is written rather than assumed.
                if let live = current[member], abs(live - target) < deadband { return nil }
                return Target(display: member, value: target, origin: syncOrigin)
            }
            .sorted { $0.display.rawValue < $1.display.rawValue }
    }

    /// The un-clamped target for one member.
    ///
    /// Every input is either the mover's new value or a *baseline* — never
    /// another member's current value. That is what stops a member the clamp has
    /// pinned at an end from dragging the rest of the group towards it: its
    /// pinned value is never read back into the arithmetic.
    private static func target(
        for member: DisplayUUID,
        movedTo moved: Double,
        movedDisplay: DisplayUUID,
        group: DisplayGroup,
        current: [DisplayUUID: Double]
    ) -> Double {
        switch group.syncMode {
        case .absolute:
            return moved
        case .relative:
            // An offset needs *both* ends. A member with no baseline falls back
            // to its live value — which makes the first move after a group is
            // created behave exactly as if the baselines had been captured a
            // moment earlier — but a member with neither has no offset to
            // preserve at all, and inventing one from the other end's baseline
            // would land it somewhere nobody chose. It follows the mover
            // instead, which is the only defensible answer with no data.
            guard let memberBase = baseline(member, group: group, current: current),
                  let moverBase = baseline(movedDisplay, group: group, current: current) else {
                return moved
            }
            return moved + (memberBase - moverBase)
        }
    }

    private static func baseline(
        _ display: DisplayUUID, group: DisplayGroup, current: [DisplayUUID: Double]
    ) -> Double? {
        if let stored = group.baselines[display], stored.isFinite { return stored }
        guard let live = current[display], live.isFinite else { return nil }
        return live
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
