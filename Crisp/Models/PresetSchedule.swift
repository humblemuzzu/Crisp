import Foundation

// Time-triggered presets: the data, and the one decision that is hard to get
// right. Foundation only — `Calendar` is injected — so the whole rule runs in
// `CrispTests` without waiting for 22:00 (AGENTS.md §3.6).
//
// ---------------------------------------------------------------------------
// THE FAILURE MODE THIS FILE IS SHAPED AROUND: SLEEP
// ---------------------------------------------------------------------------
// A wall-clock trigger written the obvious way — "every minute, is it 22:00?" —
// has two bugs and they are opposites. If the Mac is asleep at 22:00 the tick
// never happens and the schedule **never** fires. If the check is loosened to
// "is it past 22:00 and have we not fired today", a repeating timer fires it
// **every tick** until midnight.
//
// Both come from recording the wrong thing. The fix is to record the
// *occurrence* — the exact 22:00 that was satisfied — rather than the wall clock
// at which the app noticed. Then:
//
//   - waking at 07:00 finds the most recent occurrence (yesterday 22:00), sees it
//     is newer than the one on record, fires **once**, and records it;
//   - the next tick finds the same occurrence, which is no longer newer, and does
//     nothing;
//   - tomorrow's 22:00 is a different occurrence and fires again.
//
// Three guards sit around that, each for a real case:
//
//   - `armedAt` — the occurrence must be *after* the schedule existed. Creating a
//     "22:00" schedule at 23:00 must not fire it immediately for a 22:00 the user
//     was never around for.
//   - `catchUpWindow` — an occurrence older than this is stale. A Mac that has
//     been off for a week should not apply last Tuesday's Night preset the
//     instant it boots. Twelve hours is chosen so an overnight sleep still
//     catches up on the morning wake, which is the case the feature exists for.
//   - monotonic recording — `lastFired` only ever moves forward (`recording`
//     below). A clock dragged backwards, by the user or by NTP, must not make an
//     already-applied occurrence eligible again.

/// A time of day, to the minute, in the user's own calendar.
///
/// Encoded as `"22:00"` rather than as two numbers because `displays.json` is
/// meant to be readable in a bug report and hand-editable — the same argument
/// that made `DisplayUUID` encode as a bare string.
struct TimeOfDay: Codable, Equatable, Comparable, Sendable, CustomStringConvertible {
    let hour: Int
    let minute: Int

    /// Failable rather than clamping: `25:00` is not a late evening, it is a
    /// typo, and a schedule that silently became 23:59 would fire at a time
    /// nobody chose.
    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// `"22:00"`, `"7:5"`, `" 08:30 "`. Strict about the shape (two fields, both
    /// numbers, both in range) and forgiving only about padding, because this
    /// string comes out of a file a human may have edited.
    static func parse(_ text: String) -> TimeOfDay? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let minute = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return TimeOfDay(hour: hour, minute: minute)
    }

    var description: String { String(format: "%02d:%02d", hour, minute) }

    /// Minutes since midnight — the ordering, and what a picker binds to.
    var minutesSinceMidnight: Int { hour * 60 + minute }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = TimeOfDay.parse(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "'\(text)' is not an HH:mm time of day")
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// When a schedule wants to run.
///
/// Deliberately only two things. Sunrise/sunset would need location permission,
/// and "when I connect a monitor" would need this app to become a rules engine;
/// neither is worth what it costs a menu-bar utility, and `docs/automation.md`'s
/// argument about not shipping a local socket is the same argument.
struct ScheduleTrigger: Codable, Equatable, Sendable {
    var at: TimeOfDay
    /// `Calendar`'s own weekday numbering (1 = Sunday … 7 = Saturday). `nil` or
    /// empty means every day — the two are the same thing, so a hand edit that
    /// empties the list does not produce a schedule that can never fire.
    var days: Set<Int>?

    init(at: TimeOfDay, days: Set<Int>? = nil) {
        self.at = at
        self.days = days
    }

    var isEveryDay: Bool { (days ?? []).isEmpty }

    func matches(weekday: Int) -> Bool {
        isEveryDay || (days ?? []).contains(weekday)
    }
}

/// One preset, applied at one time.
struct PresetSchedule: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// The `DDCPreset.id` to apply. A schedule whose preset has been deleted
    /// simply applies nothing — it is not an error and it is not deleted for the
    /// user, because a dangling schedule is usually a preset about to come back.
    var presetID: String
    var enabled: Bool
    var trigger: ScheduleTrigger
    /// When this schedule became live — created, or re-enabled. Occurrences at or
    /// before it belong to a time the schedule did not exist for.
    var armedAt: Date
    /// The **occurrence** last applied, never the wall clock at which it was
    /// noticed. That distinction is the whole sleep/wake fix; see the header.
    var lastFired: Date?

    init(
        id: String = UUID().uuidString,
        presetID: String,
        enabled: Bool = true,
        trigger: ScheduleTrigger,
        armedAt: Date,
        lastFired: Date? = nil
    ) {
        self.id = id
        self.presetID = presetID
        self.enabled = enabled
        self.trigger = trigger
        self.armedAt = armedAt
        self.lastFired = lastFired
    }

    /// Tolerant on `enabled` and `armedAt`, strict on the three a schedule
    /// cannot mean anything without. A schedule with no `armedAt` on disk (a
    /// hand-written one) is treated as armed at the epoch, so it behaves like a
    /// schedule that has always existed rather than one that never fires.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.presetID = try container.decode(String.self, forKey: .presetID)
        self.trigger = try container.decode(ScheduleTrigger.self, forKey: .trigger)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.armedAt = try container.decodeIfPresent(Date.self, forKey: .armedAt) ?? Date(timeIntervalSince1970: 0)
        self.lastFired = try container.decodeIfPresent(Date.self, forKey: .lastFired)
    }

    /// Re-arming on enable is what stops a schedule that was off all afternoon
    /// from firing the moment it is switched back on.
    func rearmed(at date: Date) -> PresetSchedule {
        var copy = self
        copy.armedAt = date
        return copy
    }
}

/// Whether a schedule is due. Pure, total, and injected with its `Calendar` so
/// every case in the header is a test rather than an afternoon of waiting.
enum ScheduleFiring {

    /// How far back a missed occurrence may still be applied. Twelve hours:
    /// long enough that an overnight sleep still catches up when the Mac wakes
    /// the next morning (the case the feature exists for), short enough that a
    /// machine which has been off for days does not apply an evening preset over
    /// breakfast.
    static let catchUpWindow: TimeInterval = 12 * 60 * 60

    /// How many days back to look for an occurrence. A weekly schedule needs
    /// seven; the eighth is slack so a DST day cannot make the seventh fall just
    /// outside. Anything found beyond `catchUpWindow` is refused anyway.
    static let lookbackDays = 8

    enum Decision: Equatable, Sendable {
        /// Apply the preset, and record this exact occurrence as `lastFired`.
        case fire(occurrence: Date)
        case skip(SkipReason)

        var occurrence: Date? {
            guard case .fire(let occurrence) = self else { return nil }
            return occurrence
        }

        var didFire: Bool { occurrence != nil }
    }

    /// Why nothing happened. A named reason rather than a `false` so a test can
    /// distinguish "already fired" from "stale" — two skips that would otherwise
    /// look identical and mean opposite bugs.
    enum SkipReason: String, Equatable, Sendable {
        case disabled
        /// No matching time of day within the lookback — a weekday-restricted
        /// schedule that has not come round yet.
        case noOccurrence
        /// The occurrence predates the schedule.
        case notArmedYet
        /// Already applied. The repeating-timer case.
        case alreadyFired
        /// Older than `catchUpWindow`. The Mac-was-off-for-a-week case.
        case stale
    }

    static func decide(_ schedule: PresetSchedule, now: Date, calendar: Calendar) -> Decision {
        guard schedule.enabled else { return .skip(.disabled) }
        guard let occurrence = mostRecentOccurrence(schedule.trigger, atOrBefore: now, calendar: calendar) else {
            return .skip(.noOccurrence)
        }
        guard occurrence > schedule.armedAt else { return .skip(.notArmedYet) }
        if let last = schedule.lastFired, occurrence <= last { return .skip(.alreadyFired) }
        guard now.timeIntervalSince(occurrence) <= catchUpWindow else { return .skip(.stale) }
        return .fire(occurrence: occurrence)
    }

    /// The schedule with this occurrence recorded.
    ///
    /// Monotonic on purpose: `lastFired` only ever moves forward. A clock pulled
    /// backwards — by the user, by NTP after a dead battery — would otherwise
    /// make an occurrence that was already applied eligible again, and the user
    /// would watch their screens change for no reason they can see.
    static func recording(_ occurrence: Date, in schedule: PresetSchedule) -> PresetSchedule {
        var copy = schedule
        copy.lastFired = max(schedule.lastFired ?? .distantPast, occurrence)
        return copy
    }

    /// The latest instant at or before `now` that matches the trigger.
    ///
    /// Built from date components rather than `Calendar.date(bySettingHour:…)`,
    /// which searches *forward* from its anchor and so answers "tomorrow 22:00"
    /// when asked about 22:00 from 23:00 today. Components are exact, and
    /// `date(from:)` resolves the one hour that does not exist on a DST spring
    /// forward instead of returning nil.
    static func mostRecentOccurrence(
        _ trigger: ScheduleTrigger, atOrBefore now: Date, calendar: Calendar
    ) -> Date? {
        for daysBack in 0..<lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = trigger.at.hour
            components.minute = trigger.at.minute
            components.second = 0
            guard let candidate = calendar.date(from: components), candidate <= now else { continue }
            guard trigger.matches(weekday: calendar.component(.weekday, from: candidate)) else { continue }
            return candidate
        }
        return nil
    }
}
