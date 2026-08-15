import XCTest

/// Headless tests for the schedule firing rule.
///
/// The whole file exists for one sentence: a wall-clock trigger has to survive
/// sleep. If 22:00 passes while the Mac is asleep the preset applies **once** on
/// wake — not fourteen times as the machine ticks through the evening it missed,
/// and not never because the tick that would have noticed did not run.
///
/// `ScheduleFiring` takes its `Calendar` as an argument, which is what lets every
/// case below be a test instead of an overnight experiment. The calendar is
/// pinned to UTC so a run in another timezone tests the same instants.
///
/// Each test names the mutation it is designed to kill in a trailing comment.
final class PresetScheduleTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A specific instant, spelled the way the test reads.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func schedule(
        at hour: Int, minute: Int = 0,
        days: Set<Int>? = nil,
        enabled: Bool = true,
        armedAt: Date,
        lastFired: Date? = nil
    ) -> PresetSchedule {
        PresetSchedule(
            id: "s", presetID: "p", enabled: enabled,
            trigger: ScheduleTrigger(at: TimeOfDay(hour: hour, minute: minute)!, days: days),
            armedAt: armedAt, lastFired: lastFired
        )
    }

    // MARK: - The sleep case

    /// **The test this feature exists for.** A 22:00 schedule, a Mac asleep from
    /// 21:00 until 07:00 the next morning: on the first tick after wake it fires
    /// once, for the 22:00 that passed, and every tick after that does nothing.
    /// Kills mutation: matching the trigger against `now` exactly (it would never
    /// fire, because no tick happened at 22:00), or recording the wall clock
    /// instead of the occurrence (the next tick would fire it again).
    func testAMissedOccurrenceFiresExactlyOnceOnWake() {
        var schedule = schedule(at: 22, armedAt: date(10, 9))

        // Asleep through 22:00; the first tick is at 07:00 the next day.
        let decision = ScheduleFiring.decide(schedule, now: date(11, 7), calendar: calendar)
        XCTAssertEqual(decision, .fire(occurrence: date(10, 22)))

        schedule = ScheduleFiring.recording(decision.occurrence!, in: schedule)

        // Every later tick that day finds the same occurrence and does nothing.
        for hour in 7...21 {
            XCTAssertEqual(
                ScheduleFiring.decide(schedule, now: date(11, hour, 30), calendar: calendar),
                .skip(.alreadyFired),
                "a repeating tick must not re-fire an occurrence that has been applied"
            )
        }
    }

    /// Having caught up on the missed occurrence, the schedule still fires for
    /// the next one. The catch-up must not consume tomorrow's run.
    /// Kills mutation: recording `now` rather than the occurrence — 07:00 is
    /// after the previous 22:00 but *before* the next one, so the bug would show
    /// as a schedule that fires once and then stops for good if the comparison
    /// were also flipped.
    func testTheNextDaysOccurrenceStillFiresAfterACatchUp() {
        var schedule = schedule(at: 22, armedAt: date(10, 9))
        schedule = ScheduleFiring.recording(date(10, 22), in: schedule)

        XCTAssertEqual(
            ScheduleFiring.decide(schedule, now: date(11, 22, 1), calendar: calendar),
            .fire(occurrence: date(11, 22))
        )
    }

    /// The other half of "once": within the same day, from the instant it is due
    /// until midnight, exactly one tick fires. Driven minute by minute rather
    /// than asserted at two points, because "fires fourteen times" is precisely
    /// what a per-tick check produces.
    /// Kills mutation: firing on "now is past the trigger and we have not fired
    /// today" without recording an occurrence.
    func testASchedulefiresOnceNotOnEveryTickOfTheEvening() {
        var schedule = schedule(at: 22, armedAt: date(10, 9))
        var fires = 0

        for minutesPast in 0...119 {
            let now = date(10, 22).addingTimeInterval(TimeInterval(minutesPast * 60))
            let decision = ScheduleFiring.decide(schedule, now: now, calendar: calendar)
            if let occurrence = decision.occurrence {
                fires += 1
                schedule = ScheduleFiring.recording(occurrence, in: schedule)
            }
        }

        XCTAssertEqual(fires, 1)
    }

    /// An occurrence older than the catch-up window is stale. A Mac that has been
    /// off for days must not apply an evening preset over breakfast; the window
    /// is sized so an overnight sleep still catches up, which is the case the
    /// feature is for.
    /// Kills mutation: dropping the staleness check (a week-old occurrence would
    /// fire at boot), or shrinking the window below an overnight sleep (the
    /// morning-wake case above would stop firing).
    func testAnOccurrenceOlderThanTheCatchUpWindowIsStale() {
        let schedule = schedule(at: 22, armedAt: date(1, 0))

        // Nine hours later: the overnight-wake case, still applied.
        XCTAssertTrue(ScheduleFiring.decide(schedule, now: date(11, 7), calendar: calendar).didFire)
        // Thirteen hours later: past the window.
        XCTAssertEqual(
            ScheduleFiring.decide(schedule, now: date(11, 11), calendar: calendar),
            .skip(.stale)
        )
    }

    /// `lastFired` only ever moves forward. A clock dragged backwards — by the
    /// user, or by NTP after a dead battery — would otherwise make an occurrence
    /// that has already been applied eligible again, and the user would watch
    /// their screens change for no reason they can see.
    /// Kills mutation: assigning `lastFired = occurrence` unconditionally.
    func testRecordingIsMonotonic() {
        let schedule = ScheduleFiring.recording(date(11, 22), in: schedule(at: 22, armedAt: date(1, 0)))

        let rewound = ScheduleFiring.recording(date(5, 22), in: schedule)

        XCTAssertEqual(rewound.lastFired, date(11, 22))
    }

    // MARK: - Arming

    /// A schedule created at 23:00 for 22:00 does not fire the moment it is
    /// saved: that 22:00 belongs to a time the schedule did not exist for.
    /// Kills mutation: dropping the `armedAt` comparison, or making it `>=`
    /// versus `>` in the wrong direction so a schedule armed exactly on its own
    /// trigger fires twice.
    func testASchedulesFirstOccurrenceMustBeAfterItWasArmed() {
        let justCreated = schedule(at: 22, armedAt: date(10, 23))

        XCTAssertEqual(
            ScheduleFiring.decide(justCreated, now: date(10, 23, 1), calendar: calendar),
            .skip(.notArmedYet)
        )
        XCTAssertTrue(
            ScheduleFiring.decide(justCreated, now: date(11, 22, 1), calendar: calendar).didFire,
            "tomorrow's 22:00 is this schedule's to fire"
        )
    }

    /// Re-enabling re-arms, so an occurrence that passed while the schedule was
    /// off does not fire the instant it is switched back on.
    /// Kills mutation: leaving `armedAt` alone on enable, which turns the switch
    /// into a "apply this preset now" button nobody asked for.
    func testRearmingSkipsAnOccurrenceThatPassedWhileDisabled() {
        let wasOff = schedule(at: 22, enabled: false, armedAt: date(1, 0))
        XCTAssertEqual(ScheduleFiring.decide(wasOff, now: date(10, 23), calendar: calendar), .skip(.disabled))

        var enabled = wasOff.rearmed(at: date(10, 23))
        enabled.enabled = true

        XCTAssertEqual(
            ScheduleFiring.decide(enabled, now: date(10, 23, 5), calendar: calendar),
            .skip(.notArmedYet)
        )
    }

    /// A disabled schedule is checked first and never fires, whatever else is
    /// true of it.
    /// Kills mutation: checking `enabled` after the occurrence search, which
    /// costs nothing today but is where an "apply on enable" bug hides.
    func testADisabledScheduleNeverFires() {
        let off = schedule(at: 22, enabled: false, armedAt: date(1, 0))

        XCTAssertEqual(ScheduleFiring.decide(off, now: date(10, 22, 1), calendar: calendar), .skip(.disabled))
    }

    // MARK: - Days of the week

    /// A weekday-restricted schedule fires on its days and not on the others, and
    /// the occurrence it fires for is the most recent *matching* one — not
    /// yesterday's, which the day-by-day search would otherwise return.
    /// Kills mutation: dropping the weekday filter, or applying it to `now`'s
    /// weekday instead of the candidate occurrence's (they differ for exactly the
    /// overnight catch-up this feature is built around).
    func testAWeekdayRestrictedScheduleOnlyFiresOnItsDays() {
        // 2026-03-10 is a Tuesday, so 11 is Wednesday (Calendar weekday 4).
        XCTAssertEqual(calendar.component(.weekday, from: date(11, 12)), 4)

        let wednesdaysOnly = schedule(at: 22, days: [4], armedAt: date(1, 0))

        XCTAssertEqual(
            ScheduleFiring.decide(wednesdaysOnly, now: date(11, 23), calendar: calendar),
            .fire(occurrence: date(11, 22)),
            "Wednesday 22:00 fires"
        )
        // Thursday morning, having already fired for Wednesday: the most recent
        // matching occurrence is still Wednesday's, and it has been applied.
        let fired = ScheduleFiring.recording(date(11, 22), in: wednesdaysOnly)
        XCTAssertEqual(
            ScheduleFiring.decide(fired, now: date(12, 9), calendar: calendar),
            .skip(.alreadyFired)
        )
        // Thursday evening, past its own 22:00: still Wednesday's occurrence,
        // because Thursday is not one of this schedule's days.
        XCTAssertEqual(
            ScheduleFiring.decide(fired, now: date(12, 23), calendar: calendar),
            .skip(.alreadyFired)
        )
    }

    /// An empty day set and an absent one are the same thing: every day. A hand
    /// edit that empties the list must not produce a schedule that can never
    /// fire and gives no reason why.
    /// Kills mutation: treating an empty set as "no days match".
    func testAnEmptyDaySetMeansEveryDay() {
        XCTAssertTrue(ScheduleTrigger(at: TimeOfDay(hour: 1, minute: 0)!, days: []).isEveryDay)
        XCTAssertTrue(ScheduleTrigger(at: TimeOfDay(hour: 1, minute: 0)!, days: nil).isEveryDay)

        let schedule = schedule(at: 22, days: [], armedAt: date(1, 0))
        XCTAssertTrue(ScheduleFiring.decide(schedule, now: date(10, 22, 1), calendar: calendar).didFire)
    }

    /// A schedule whose only day has not come round within the lookback has no
    /// occurrence at all — a distinct answer from "already fired", so a
    /// diagnostic can tell the two apart.
    /// Kills mutation: returning `alreadyFired` (or firing) when the search comes
    /// back empty.
    func testAScheduleWithNoOccurrenceInTheLookbackSaysSo() {
        // A trigger later today, on a day-set that excludes every day in range is
        // impossible to express; the reachable case is a time later today with a
        // lookback that finds nothing — force it by asking before the first
        // matching weekday exists in range.
        var narrowCalendar = calendar
        narrowCalendar.timeZone = TimeZone(identifier: "UTC")!
        let schedule = schedule(at: 22, days: [8], armedAt: date(1, 0))

        XCTAssertEqual(
            ScheduleFiring.decide(schedule, now: date(11, 23), calendar: narrowCalendar),
            .skip(.noOccurrence),
            "weekday 8 does not exist, so nothing in the lookback matches"
        )
    }

    // MARK: - TimeOfDay

    /// The stored form is `"22:00"`, and it round-trips. The file is meant to be
    /// readable in a bug report and editable by hand, which two integers would
    /// not be.
    /// Kills mutation: encoding as an object, or formatting without zero padding
    /// (`7:5` would then be written and `"7:5" != "07:05"` in a diff).
    func testTimeOfDayEncodesAsAPaddedString() throws {
        let time = TimeOfDay(hour: 7, minute: 5)!

        let data = try JSONEncoder().encode(time)

        XCTAssertEqual(String(bytes: data, encoding: .utf8), "\"07:05\"")
        XCTAssertEqual(try JSONDecoder().decode(TimeOfDay.self, from: data), time)
    }

    /// Parsing is forgiving about padding and strict about everything else. A
    /// value out of range is a typo, not a late evening, and clamping it would
    /// leave a schedule firing at a time nobody chose.
    /// Kills mutation: clamping instead of refusing, or accepting a bare hour
    /// (`"22"` would then mean 22:00 in the file and nothing in the UI).
    func testTimeOfDayParsingIsForgivingAboutPaddingAndStrictAboutRange() {
        XCTAssertEqual(TimeOfDay.parse(" 7:5 "), TimeOfDay(hour: 7, minute: 5))
        XCTAssertEqual(TimeOfDay.parse("22:00"), TimeOfDay(hour: 22, minute: 0))

        XCTAssertNil(TimeOfDay.parse("25:00"))
        XCTAssertNil(TimeOfDay.parse("22:60"))
        XCTAssertNil(TimeOfDay.parse("-1:00"))
        XCTAssertNil(TimeOfDay.parse("22"))
        XCTAssertNil(TimeOfDay.parse("22:00:00"))
        XCTAssertNil(TimeOfDay.parse("evening"))
        XCTAssertNil(TimeOfDay(hour: 24, minute: 0))
    }

    /// The occurrence search looks *backwards*. `Calendar.date(bySettingHour:…)`
    /// searches forward from its anchor, so asking it about 22:00 at 23:00 gives
    /// tomorrow — this pins that the search does not do that.
    /// Kills mutation: rewriting `mostRecentOccurrence` with
    /// `date(bySettingHour:minute:second:of:)`.
    func testTheOccurrenceSearchLooksBackwardsNotForwards() {
        let trigger = ScheduleTrigger(at: TimeOfDay(hour: 22, minute: 0)!)

        XCTAssertEqual(
            ScheduleFiring.mostRecentOccurrence(trigger, atOrBefore: date(10, 23), calendar: calendar),
            date(10, 22)
        )
        XCTAssertEqual(
            ScheduleFiring.mostRecentOccurrence(trigger, atOrBefore: date(10, 21), calendar: calendar),
            date(9, 22),
            "before today's trigger, the most recent occurrence is yesterday's"
        )
    }

    // MARK: - Decoding

    /// A hand-written schedule with no `armedAt` behaves like one that has always
    /// existed rather than one that can never fire, and `enabled` defaults to on.
    /// Kills mutation: defaulting `armedAt` to `Date()` (the schedule would never
    /// fire, because every occurrence would predate the moment it was loaded), or
    /// defaulting `enabled` to false.
    func testAHandWrittenScheduleDecodesWithUsableDefaults() throws {
        let json = #"{"id": "s", "presetID": "p", "trigger": {"at": "22:00"}}"#

        let schedule = try JSONDecoder().decode(PresetSchedule.self, from: Data(json.utf8))

        XCTAssertTrue(schedule.enabled)
        XCTAssertNil(schedule.lastFired)
        XCTAssertTrue(ScheduleFiring.decide(schedule, now: date(10, 22, 1), calendar: calendar).didFire)
    }
}
