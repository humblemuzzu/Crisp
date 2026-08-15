import Foundation

// The input-source calibration wizard's decision core: which codes are worth
// testing, what happens at each step of one test, and what has to be on disk at
// every instant so an interruption cannot leave the user staring at a black
// screen.
//
// **Why any of this exists.** VCP 0x60 is the one DDC write whose failure the
// user cannot undo from the Mac. Writing a code with nothing attached to it
// blanks the panel — and the app's own UI goes dark with it, including the
// button that would have put it back. The only recovery is the monitor's
// physical buttons. Meanwhile the codes themselves are not reliably standard:
// the VESA MCCS table calls code 19 "DVI-10" and the BenQ MA320U reports 19 on
// a panel with no DVI port at all; the Samsung U32H750 advertises 0x11/0x12/0x0F
// and uses 0x05/0x06/0x0F. So the mapping can only be established by writing a
// code and having a human say whether they can see anything — which is precisely
// the operation that can strand them.
//
// **Why it is pure.** Every safety property here has to hold *without a working
// screen*, so none of it may live in a view: a revert that depends on the user
// clicking something is not a revert. Modelled as a value type with explicit
// events and effects, a whole multi-step session — expire the countdown, kill
// the app, unplug the display, come back — is driveable in `CrispTests` with no
// monitor attached and no 0x60 write ever executed.
//
// The shape is macOS's own display-resolution confirmation ("Keep / Revert",
// 15 seconds), with three additions that the resolution dialog does not need
// because a bad resolution still draws something:
//
// 1. the revert is armed and **persisted before** the switch, not after;
// 2. it fires on an absolute **deadline**, not on a countdown the UI keeps alive;
// 3. it always restores the code the *session* started on, never the previous
//    step of a multi-step session.

// MARK: - Candidate enumeration

enum InputCalibrationPlan {

    /// The codes worth offering, best-known first: whatever the monitor is on
    /// right now, then codes this user has already calibrated, then the quirks
    /// database's entries for this exact model, then the generic VESA codes.
    ///
    /// Unlike `MonitorQuirkResolver.inputOptions`, this deliberately ignores
    /// `complete`. That flag exists so a fully-mapped monitor stops offering
    /// generic codes in the everyday menu; calibration is the act of *finding*
    /// ports nobody has mapped, so suppressing the codes a contributor did not
    /// think to list would defeat the feature. It is also why the wizard never
    /// switches to a code without the countdown armed, `complete` or not.
    static func candidates(
        quirks: MonitorQuirks?,
        currentInput: UInt16?,
        calibrated: [UInt16: String] = [:],
        standardCodes: [UInt16] = MCCSInputTable.commonCodes
    ) -> [UInt16] {
        var codes: [UInt16] = []
        if let currentInput { codes.append(currentInput) }
        // Sorted, not dictionary order: `[UInt16: String]` has no order at all
        // and the wizard's list must not reshuffle itself between launches.
        codes.append(contentsOf: calibrated.keys.sorted())
        codes.append(contentsOf: quirks?.inputValues.map(\.code) ?? [])
        codes.append(contentsOf: standardCodes)

        var seen: Set<UInt16> = []
        return codes.filter { seen.insert($0).inserted }
    }
}

// MARK: - Session shape

/// Why a trial stopped waiting for the user and went back to the original code.
enum InputCalibrationRevertReason: Equatable, Sendable {
    /// The countdown expired with no confirmation. The overwhelmingly likely
    /// meaning: the switch worked, the Mac is still rendering, and the user
    /// cannot see any of it.
    case timedOut
    /// The user pressed "Revert" (or closed the wizard) while the trial was open.
    case userCancelled
    /// The monitor never acknowledged the candidate write. Reverting anyway is
    /// deliberate — a missing ack does not prove the write failed to land.
    case writeNotAcknowledged
}

/// Where one calibration session is in its cycle.
enum InputCalibrationPhase: Equatable, Sendable {
    /// Between trials. The monitor is showing something the user can see.
    case choosing
    /// The candidate's 0x60 write is in flight; the countdown is not armed yet.
    case switching(candidate: UInt16)
    /// Written and acknowledged. `deadline` is absolute: whoever ticks next past
    /// it reverts, however late the tick is and whatever the UI is doing.
    case confirming(candidate: UInt16, deadline: Date)
    /// Putting the original code back. `attempt` counts write tries, because a
    /// revert that fails silently is the failure this whole type exists to avoid.
    case reverting(candidate: UInt16, reason: InputCalibrationRevertReason, attempt: Int)
    /// Every revert attempt failed. The pending record is deliberately kept, so
    /// the next successful DDC read of this display retries the restore.
    case revertFailed(candidate: UInt16)
    /// The user confirmed they can see the screen and is naming the port.
    case naming(candidate: UInt16)
    /// The display went away mid-trial. Nothing can be written to it; the
    /// pending record stays on disk so reconnect (or relaunch) repairs it.
    case interrupted
    case finished
}

/// Something the world outside has to do, emitted by a transition.
///
/// Ordering within one transition is meaningful and asserted in tests:
/// `persistPending` always precedes the `writeInput` it protects, so a crash
/// between the two leaves a record for a switch that never happened (harmless —
/// the recovery decision sees the monitor already on the original) rather than a
/// switch with no record (a black screen nobody knows how to undo).
enum InputCalibrationEffect: Equatable, Sendable {
    /// Write the crash-recovery record and flush it to disk *now*, before the
    /// write it protects.
    case persistPending(PendingInputCalibration)
    /// Perform a VCP 0x60 write.
    case writeInput(UInt16)
    /// The monitor is back on a code the user can see; drop the recovery record.
    case clearPending
    /// A human physically confirmed this code. The only route to `verified`.
    case persistConfirmed(CalibratedInput)
    /// Start ticking towards this absolute deadline.
    case armDeadline(Date)
    /// Stop ticking. Emitted with, never instead of, whatever ends the trial.
    case cancelDeadline
}

/// What the wizard is told about the world.
enum InputCalibrationEvent: Equatable, Sendable {
    /// Try this code. Ignored unless the session is between trials, so a
    /// double-click cannot stack two switches.
    case test(UInt16)
    /// The candidate write came back from `DDCService` (`true` = monitor acked).
    case writeCompleted(acknowledged: Bool)
    /// The clock moved. The only thing that can expire a countdown.
    case tick(Date)
    /// "Yes, I can see this." The only route to a confirmed mapping.
    case keep
    /// "Revert now", or the wizard being closed mid-trial.
    case cancel
    /// The revert write came back.
    case revertCompleted(acknowledged: Bool)
    /// The port's name, from the user.
    case named(String)
    /// This display is no longer attached.
    case displayDisconnected
    /// The user is done with the wizard.
    case finish
}

/// One calibration session for one display.
///
/// `originalCode` is `let` on purpose and it is the single most important line in
/// this file: a revert restores the code the **session** began on, never the
/// previous step. In a multi-step session — confirm HDMI, then probe an unknown
/// code that turns out to be dead — reverting to "the last thing that worked"
/// would still be safe by luck, but reverting to a code proven live at the moment
/// the user could still see the UI is safe by construction, and it is the one
/// rule that stays true no matter how many steps have run.
struct InputCalibrationSession: Equatable, Sendable {

    /// How long the user gets to say "I can see this".
    ///
    /// macOS's resolution dialog uses 15 seconds and users already recognise the
    /// pattern. Long enough to look up at a monitor that has just resynced (a
    /// panel can take several seconds to lock a new input), short enough that a
    /// user who walked away is not left on a dead port.
    static let defaultConfirmWindow: TimeInterval = 15

    /// A window outside this band is a programming error, not a preference: too
    /// short and a slow panel has not even resynced before the revert fires, too
    /// long and "walked away" becomes indistinguishable from "stranded".
    static let confirmWindowBounds: ClosedRange<TimeInterval> = 5...120

    /// Revert writes to attempt before giving up and leaving the record for the
    /// recovery path. Three matches `DDCProtocolEngine`'s own write retry: past
    /// that the bus is wedged and hammering it will not help.
    static let maxRevertAttempts = 3

    /// Persistence keys on the stable UUID, never `CGDirectDisplayID`
    /// (AGENTS.md §3.3): a reconnect mid-session reassigns the ID, and this
    /// record has to survive exactly that.
    let displayUUID: DisplayUUID
    /// The code the monitor was on when the session opened — proven live, because
    /// the user was looking at the wizard on it.
    let originalCode: UInt16
    let candidates: [UInt16]
    let confirmWindow: TimeInterval

    private(set) var phase: InputCalibrationPhase = .choosing
    /// Ports a human physically confirmed during this session, in confirm order.
    private(set) var confirmed: [CalibratedInput] = []

    init(
        displayUUID: DisplayUUID,
        originalCode: UInt16,
        candidates: [UInt16],
        confirmWindow: TimeInterval = InputCalibrationSession.defaultConfirmWindow
    ) {
        self.displayUUID = displayUUID
        self.originalCode = originalCode
        self.candidates = candidates
        self.confirmWindow = min(
            max(confirmWindow, Self.confirmWindowBounds.lowerBound),
            Self.confirmWindowBounds.upperBound
        )
    }

    /// The code currently under test, if any. Everything the UI needs to know
    /// about "is a trial open" derives from this rather than from the phase, so
    /// adding a phase cannot silently change what the wizard renders.
    var candidateUnderTest: UInt16? {
        switch phase {
        case .switching(let code), .confirming(let code, _), .naming(let code),
             .revertFailed(let code):
            return code
        case .reverting(let code, _, _):
            return code
        case .choosing, .interrupted, .finished:
            return nil
        }
    }

    /// When the open trial reverts itself. `nil` when no countdown is running.
    var deadline: Date? {
        if case .confirming(_, let deadline) = phase { return deadline }
        return nil
    }

    /// Whether an unconfirmed code is on the panel right now, i.e. whether the
    /// user might currently be looking at nothing.
    var isTrialOpen: Bool {
        switch phase {
        case .switching, .confirming, .reverting, .revertFailed: return true
        case .choosing, .naming, .interrupted, .finished: return false
        }
    }

    /// The label used when the user confirms a code but does not name the port.
    ///
    /// `Input-<code>` rather than the MCCS name, matching
    /// `QuirkEntryGenerator.inputFeature`'s rule and for the same reason: the
    /// user has verified that this code shows a live picture, which is a fact
    /// about the code, not about the specification's name for it. Writing
    /// "DVI-10" here would promote a table lookup to a measurement.
    static func defaultLabel(for code: UInt16) -> String { "Input-\(code)" }

    // MARK: - Transitions

    /// Applies one event and returns what the outside world must do about it.
    ///
    /// Total by construction: every event is legal in every phase, and the ones
    /// that make no sense there are no-ops returning `[]`. That is not laziness —
    /// it is the property that matters most here. A "Keep" click that arrives one
    /// millisecond after the countdown expired must not un-revert; a second
    /// "Test" while a trial is open must not stack a second switch; a tick during
    /// naming must not blank a screen the user is looking at.
    @discardableResult
    mutating func apply(_ event: InputCalibrationEvent, now: Date) -> [InputCalibrationEffect] {
        switch event {
        case .test(let code):
            return startTrial(code: code, now: now)
        case .writeCompleted(let acknowledged):
            return candidateWriteCompleted(acknowledged: acknowledged, now: now)
        case .tick(let instant):
            return tick(now: instant)
        case .keep:
            return keep()
        case .cancel:
            return cancel()
        case .revertCompleted(let acknowledged):
            return revertCompleted(acknowledged: acknowledged)
        case .named(let label):
            return named(label, now: now)
        case .displayDisconnected:
            return displayDisconnected()
        case .finish:
            return finish()
        }
    }

    private mutating func startTrial(code: UInt16, now: Date) -> [InputCalibrationEffect] {
        guard case .choosing = phase else { return [] }
        phase = .switching(candidate: code)
        let pending = PendingInputCalibration(
            originalCode: originalCode, candidateCode: code, startedAt: now
        )
        // Record first, switch second. The reverse order has a window in which a
        // crash leaves the panel on an untested code with nothing on disk saying
        // what to put back.
        return [.persistPending(pending), .writeInput(code)]
    }

    private mutating func candidateWriteCompleted(
        acknowledged: Bool, now: Date
    ) -> [InputCalibrationEffect] {
        guard case .switching(let code) = phase else { return [] }
        guard acknowledged else {
            // A missing ack is not proof the write did not land: DDC/CI replies
            // get lost, and several monitors switch input and then never answer
            // because the link is renegotiating. Treating "no ack" as "no switch"
            // would skip the revert in exactly the case where the screen is
            // already black. So revert, and say why.
            return beginRevert(candidate: code, reason: .writeNotAcknowledged)
        }
        let deadline = now.addingTimeInterval(confirmWindow)
        phase = .confirming(candidate: code, deadline: deadline)
        return [.armDeadline(deadline)]
    }

    private mutating func tick(now: Date) -> [InputCalibrationEffect] {
        guard case .confirming(let code, let deadline) = phase else { return [] }
        // `>=` against an absolute deadline, not a decremented counter: a tick
        // that arrives late (a busy main actor, a machine that slept) still
        // reverts on its first delivery instead of restarting the countdown.
        guard now >= deadline else { return [] }
        return beginRevert(candidate: code, reason: .timedOut)
    }

    private mutating func keep() -> [InputCalibrationEffect] {
        guard case .confirming(let code, _) = phase else { return [] }
        phase = .naming(candidate: code)
        // The user is looking at a working picture on this code, so there is
        // nothing left to recover from and the record must go — otherwise a
        // later crash would "restore" a screen that was never lost.
        return [.cancelDeadline, .clearPending]
    }

    private mutating func cancel() -> [InputCalibrationEffect] {
        guard case .confirming(let code, _) = phase else { return [] }
        return beginRevert(candidate: code, reason: .userCancelled)
    }

    private mutating func beginRevert(
        candidate: UInt16, reason: InputCalibrationRevertReason
    ) -> [InputCalibrationEffect] {
        phase = .reverting(candidate: candidate, reason: reason, attempt: 1)
        return [.cancelDeadline, .writeInput(originalCode)]
    }

    private mutating func revertCompleted(acknowledged: Bool) -> [InputCalibrationEffect] {
        guard case .reverting(let code, let reason, let attempt) = phase else { return [] }
        if acknowledged {
            phase = .choosing
            return [.clearPending]
        }
        guard attempt < Self.maxRevertAttempts else {
            // Out of attempts. The record stays on disk on purpose: the next
            // successful 0x60 read — next launch, next reconnect — retries it.
            phase = .revertFailed(candidate: code)
            return []
        }
        phase = .reverting(candidate: code, reason: reason, attempt: attempt + 1)
        return [.writeInput(originalCode)]
    }

    private mutating func named(_ label: String, now: Date) -> [InputCalibrationEffect] {
        guard case .naming(let code) = phase else { return [] }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = CalibratedInput(
            code: code,
            label: trimmed.isEmpty ? Self.defaultLabel(for: code) : trimmed,
            confirmedAt: now
        )
        // Last write wins if the same code is confirmed twice in one session
        // (the user renaming a port they just named).
        confirmed.removeAll { $0.code == code }
        confirmed.append(entry)
        phase = .choosing
        return [.persistConfirmed(entry)]
    }

    private mutating func displayDisconnected() -> [InputCalibrationEffect] {
        if isTrialOpen {
            // Nothing can be written to a display that is not there, and the
            // panel may well be sitting on the untested code. Leave the pending
            // record exactly where it is: `InputCalibrationRecovery` picks it up
            // the moment the display answers a read again.
            phase = .interrupted
            return []
        }
        phase = .finished
        return []
    }

    private mutating func finish() -> [InputCalibrationEffect] {
        switch phase {
        case .confirming:
            // Closing the wizard mid-trial must not abandon an untested code on
            // the panel, so it means "revert", not "stop caring".
            return cancel()
        case .switching, .reverting:
            // A 0x60 write is in flight and its result still has to be acted on.
            // Ignoring it here would drop the revert on the floor; the caller
            // re-sends `.finish` once the phase settles.
            return []
        case .choosing, .naming, .interrupted, .revertFailed, .finished:
            // `.revertFailed` ends the session on purpose: the wizard has nothing
            // left to try, and the pending record it leaves behind is what the
            // recovery path acts on. Trapping the user in a window that cannot
            // fix it would help nobody.
            phase = .finished
            return []
        }
    }
}

// MARK: - Crash / quit recovery

/// What to do at startup (or on reconnect) about a calibration that never
/// finished.
///
/// The case this exists for: the app is killed, or the Mac panics, while an
/// untested code is on the panel. The countdown died with the process, so the
/// only thing that can put the monitor back is a record written to disk *before*
/// the switch — which is what `InputCalibrationEffect.persistPending` is.
///
/// Writing 0x60 unprompted at launch is normally forbidden (`quirks/README.md`:
/// "anything the app writes to VCP 0x60 without asking must be provable"). The
/// restore qualifies under that rule's second clause: `originalCode` is the code
/// the monitor was *on* when the session started, recorded from a live read, not
/// inferred from a table.
enum InputCalibrationRecovery {

    /// How long a pending record is still evidence about the present.
    ///
    /// The evidence "this code was live" decays: a user who re-cabled the monitor
    /// in the meantime would be sent to a port that no longer has anything on it —
    /// this repair turning into the exact accident it exists to undo. A day is
    /// far beyond the real case (crash, reboot, relaunch) and well short of
    /// "long enough to have rearranged the desk". Anything older is dropped
    /// without writing, which is safe for a reason worth stating: a user who was
    /// actually stranded could not have launched anything, so a record this old
    /// belongs to a session that ended fine.
    static let maxPendingAge: TimeInterval = 24 * 60 * 60

    /// Why a record is being dropped without touching the monitor. A sibling of
    /// `Decision` rather than a case's payload type so the enum stays one level
    /// deep and the reason can be logged on its own.
    enum ClearReason: Equatable, Sendable {
        /// The monitor is already on the original code.
        case alreadyRestored
        /// The record is older than `maxPendingAge`.
        case expired
    }

    enum Decision: Equatable, Sendable {
        /// No record; nothing to do.
        case none
        /// Drop the record without touching the monitor.
        case clear(reason: ClearReason)
        /// Write this code back, then clear the record once it is acknowledged.
        case restore(UInt16)
    }

    /// - Parameter currentInput: what VCP 0x60 answers now, or `nil` if the read
    ///   failed. A failed read resolves to `restore`, not to "leave it": an
    ///   unreadable monitor is exactly the state a wedged, freshly-switched panel
    ///   is in, and re-writing a code the monitor is already on is a no-op.
    static func decide(
        pending: PendingInputCalibration?,
        currentInput: UInt16?,
        now: Date
    ) -> Decision {
        guard let pending else { return .none }
        guard now.timeIntervalSince(pending.startedAt) <= maxPendingAge else {
            return .clear(reason: .expired)
        }
        if let currentInput, currentInput == pending.originalCode {
            return .clear(reason: .alreadyRestored)
        }
        return .restore(pending.originalCode)
    }
}
