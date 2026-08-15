import Foundation
import AppKit
import os.log

/// Time-triggered presets: the stored list, the CRUD the panel drives, and the
/// tick that asks `ScheduleFiring` whether anything is due.
///
/// **The decision is not here.** Whether a schedule should fire — including the
/// whole sleep/wake catch-up, which is the part that is easy to get wrong in both
/// directions — is `ScheduleFiring.decide`, pure and injected with its
/// `Calendar`, so every case is a unit test instead of an afternoon of waiting.
/// What is left in this file is when to *ask*:
///
///   - a one-minute repeating timer, with `tolerance` set so macOS may coalesce
///     it with other work rather than waking the CPU on the minute;
///   - `NSWorkspace.didWakeNotification`, because the timer did not run while the
///     Mac was asleep and the whole point is that a missed 22:00 still applies;
///   - and once at launch, for the same reason after a shutdown.
///
/// Asking more often than necessary is free: `decide` is a comparison, and a
/// schedule that has already fired for its occurrence answers `.alreadyFired`.
/// That is why the wake handler can be unconditional rather than trying to work
/// out how long the machine was out.
///
/// No private frameworks: Foundation, `NSWorkspace`'s wake notification, os.log.
@MainActor
final class PresetScheduleService: ObservableObject {
    static let shared = PresetScheduleService()

    private static let log = Logger(subsystem: "com.crisp.app", category: "PresetScheduleService")

    /// One minute. Finer buys nothing — a trigger has minute resolution — and
    /// coarser would delay a schedule by up to its own period.
    private static let tickInterval: TimeInterval = 60

    @Published private(set) var schedules: [PresetSchedule] = []

    private var store: DisplayStateStore { .shared }
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Injected so the tests that drive this service (should any be added) and
    /// the app itself agree on which calendar "22:00" is in: the user's.
    private let calendar: Calendar

    // `.autoupdatingCurrent`, not `.current`. `.current` is a snapshot taken once at init, so a
    // menu-bar app that stays running across a flight would keep firing a 22:00 schedule at the
    // old timezone's 22:00 until it was relaunched. The autoupdating calendar tracks the system,
    // which is the only reading of "22:00" a wall-clock trigger can honestly claim to mean.
    private init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
        schedules = store.schedules
    }

    // MARK: - Lifecycle

    /// Arms the tick. Idempotent — `AppDelegate` calls it at launch and nothing
    /// else has to know whether it already ran.
    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A schedule that lands within a few seconds of its minute is on time;
        // letting macOS coalesce this with other timers keeps a menu-bar utility
        // off the list of things that wake the CPU sixty times an hour.
        timer.tolerance = 15
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Unconditional: the catch-up rule already decides whether the
            // occurrence that passed during sleep is still worth applying.
            MainActor.assumeIsolated { self?.tick() }
        }

        tick()
    }

    // MARK: - CRUD

    @discardableResult
    func add(presetID: String, trigger: ScheduleTrigger, now: Date = Date()) -> PresetSchedule {
        // Armed at creation, so a schedule made at 23:00 for 22:00 waits until
        // tomorrow instead of firing the moment it is saved.
        let schedule = PresetSchedule(presetID: presetID, trigger: trigger, armedAt: now)
        write(schedules + [schedule])
        return schedule
    }

    func delete(_ id: String) {
        write(schedules.filter { $0.id != id })
    }

    /// Turning a schedule on re-arms it: an occurrence that passed while it was
    /// off was not this schedule's to fire.
    func setEnabled(_ id: String, _ enabled: Bool, now: Date = Date()) {
        write(schedules.map { schedule in
            guard schedule.id == id else { return schedule }
            var copy = schedule
            copy.enabled = enabled
            return enabled ? copy.rearmed(at: now) : copy
        })
    }

    func setTrigger(_ id: String, _ trigger: ScheduleTrigger, now: Date = Date()) {
        write(schedules.map { schedule in
            guard schedule.id == id else { return schedule }
            var copy = schedule
            copy.trigger = trigger
            // A changed time is a new intention; re-arm so the *old* time's
            // occurrence cannot fire under the new one's name.
            return copy.rearmed(at: now)
        })
    }

    // MARK: - The tick

    /// Applies every schedule that is due, exactly once each.
    ///
    /// The record is written **before** the preset is applied. If applying were
    /// first and the app died in between, the next tick would find the same
    /// occurrence unrecorded and apply it again — and "fired twice" is the bug
    /// this whole file is shaped around. Applying a preset is idempotent (it
    /// writes absolute values), so losing one to a crash is the cheaper failure.
    func tick(now: Date = Date()) {
        guard !schedules.isEmpty else { return }
        var due: [PresetSchedule] = []
        let updated = schedules.map { schedule -> PresetSchedule in
            let decision = ScheduleFiring.decide(schedule, now: now, calendar: calendar)
            guard let occurrence = decision.occurrence else { return schedule }
            due.append(schedule)
            return ScheduleFiring.recording(occurrence, in: schedule)
        }
        guard !due.isEmpty else { return }
        write(updated)

        for schedule in due {
            Self.log.info("schedule \(schedule.id, privacy: .public) firing preset \(schedule.presetID, privacy: .public)")
            Task { @MainActor in
                await DDCPresetService.shared.apply(id: schedule.presetID, origin: .schedule)
            }
        }
    }

    // MARK: - Plumbing

    /// The preset a schedule names, or nil once it has been deleted — which the
    /// panel shows as "missing" rather than hiding the schedule.
    func preset(for schedule: PresetSchedule) -> DDCPreset? {
        DDCPresetService.shared.presets.first { $0.id == schedule.presetID }
    }

    private func write(_ schedules: [PresetSchedule]) {
        store.setSchedules(schedules)
        self.schedules = store.schedules
    }
}
