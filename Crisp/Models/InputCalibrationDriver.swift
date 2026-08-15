import Foundation
import CoreGraphics

// The calibration wizard's *glue*: the part that sits between the pure state
// machine in `InputCalibration.swift` and the world.
//
// It was extracted out of `InputCalibrationService` because that is where the
// bugs were. The state machine had tests and was correct; the glue around it had
// neither, and three of its decisions are safety decisions:
//
// 1. when a close request that had to wait for a write may finally be honoured,
// 2. when a reconnect is allowed to repair a display the wizard has given up on,
// 3. when a new session may adopt the code the monitor is on as its revert target.
//
// None of those need a monitor, a timer or an I2C bus to decide — only to
// *execute*. So the execution is injected (`InputCalibrationEnvironment`) and the
// decisions live here, in `Crisp/Models/`, where `CrispTests` compiles them and
// drives whole sessions with no display attached and no VCP 0x60 write ever
// issued (see `InputCalibrationDriverTests`).

/// Everything the driver cannot do itself, as closures.
///
/// Same shape as `DDCProtocolEngine`'s injected `now`/`sleep` and
/// `DisplayStateStore`'s injected directory: production wires the real thing in
/// `InputCalibrationService`, tests wire fakes. The defaults are all inert
/// (`nil`, no-op, "the write was not acknowledged") so a partially-configured
/// environment fails closed rather than writing 0x60 somewhere unexpected.
struct InputCalibrationEnvironment {
    /// The clock the deadline is compared against. The state machine stores an
    /// absolute deadline, so a test moves time by moving this.
    var now: () -> Date = Date.init

    /// The display's current `CGDirectDisplayID`, or `nil` if it is not attached.
    /// Looked up per use, never cached: macOS reassigns IDs across a reconnect
    /// (AGENTS.md §3.3). `nil` doubles as "this display has gone".
    var displayID: (DisplayUUID) -> CGDirectDisplayID? = { _ in nil }

    /// The one DDC write this feature performs (VCP 0x60). The completion must
    /// be delivered on the main actor; the production wiring does that hop.
    var writeInputSource: (CGDirectDisplayID, UInt16, @escaping (Bool) -> Void) -> Void = { _, _, done in done(false) }

    /// Tell the rest of the app which code the panel is on now, so the everyday
    /// UI does not disagree with the wizard while it moves the input around.
    var noteInputSource: (DisplayUUID, UInt16) -> Void = { _, _ in }

    /// The crash-recovery record on disk for a display.
    var pendingRecord: (DisplayUUID) -> PendingInputCalibration? = { _ in nil }

    /// Write (or clear) that record **and flush it now**. The whole point of the
    /// record is to survive a process that dies in the next instant, so a
    /// debounced save is not good enough.
    var writePendingRecord: (DisplayUUID, PendingInputCalibration?) -> Void = { _, _ in }

    /// Record a port a human physically confirmed.
    var appendConfirmedInput: (DisplayUUID, CalibratedInput) -> Void = { _, _ in }

    /// Start delivering ticks at this spacing. Replaces any tick source already
    /// running. The handler is invoked on the main actor.
    var startTicking: (TimeInterval, @escaping () -> Void) -> Void = { _, _ in }
    var stopTicking: () -> Void = {}

    /// Where the driver's log lines go. A closure rather than `os.log` so
    /// `Crisp/Models/` keeps its Foundation-only dependency profile and a test
    /// can assert on what was said.
    var log: (String) -> Void = { _ in }
}

/// Drives one calibration session: feeds events into `InputCalibrationSession`
/// and executes the effects that come back, in the order they come back.
///
/// Holds every piece of state that is *about* the session but not *in* it — the
/// close request, the generation token, the in-flight recovery restores — which
/// is exactly the state the pure machine cannot see and therefore cannot protect.
@MainActor
final class InputCalibrationDriver {

    /// Tick spacing. Fine enough for a 1-second countdown readout, coarse enough
    /// that a wedged main actor is not handed a backlog of hundreds of events.
    static let tickInterval: TimeInterval = 0.25

    /// The live session, or `nil` when the wizard is closed.
    private(set) var session: InputCalibrationSession?
    /// Whole seconds left on the countdown, for display only. Nothing decides
    /// anything from this: the deadline in the session is the truth.
    private(set) var secondsRemaining: Int = 0
    /// Why the last trial ended, so the wizard can say "that port showed nothing"
    /// instead of silently returning to the list.
    private(set) var lastRevert: InputCalibrationRevertReason?
    /// Codes tried and reverted this session. Outlives the session by one step so
    /// the wizard can still render its summary after `close()`.
    private(set) var revertedCodes: [UInt16] = []

    /// Called after every change to the four properties above, so the
    /// `ObservableObject` wrapper can republish them.
    var onChange: (() -> Void)?

    private let env: InputCalibrationEnvironment

    /// Bumped whenever a session starts or ends, so a DDC completion belonging to
    /// an abandoned session cannot drive the current one.
    private var generation = 0

    /// UUIDs with a recovery restore already in flight, so repeated 0x60 reads
    /// (launch, the 3-second retry, a reconnect storm) cannot stack writes.
    private var restoresInFlight: Set<DisplayUUID> = []

    /// The user asked to close the wizard. Honoured as soon as the monitor is
    /// back on a code they can see, never before.
    private var closeRequested = false

    init(environment: InputCalibrationEnvironment) {
        env = environment
    }

    // MARK: - Session lifecycle

    /// Opens a session, or returns `false` if it must not be started.
    ///
    /// `originalCode` is the entire safety net — every revert in the session goes
    /// back to it — so it has to be a code that is *proven* live, not merely the
    /// one the monitor happens to be showing. Two states break that guarantee and
    /// are refused here:
    ///
    /// - a recovery restore is in flight, so the panel is mid-repair and the code
    ///   currently reported is the one being undone;
    /// - an unresolved pending record exists, meaning some earlier session (or a
    ///   crashed process) left an untested code on the panel that nothing has
    ///   confirmed yet.
    ///
    /// In both cases `display.inputSource` is an *unproven candidate*. Adopting it
    /// would make every revert in the new session restore the very code the user
    /// may not be able to see. Refusing is safe: the recovery path clears the
    /// record as soon as the restore is acknowledged (or ages it out), after which
    /// calibration can start normally.
    @discardableResult
    func begin(
        uuid: DisplayUUID,
        originalCode: UInt16,
        candidates: [UInt16],
        confirmWindow: TimeInterval = InputCalibrationSession.defaultConfirmWindow
    ) -> Bool {
        guard session == nil else { return false }
        guard !restoresInFlight.contains(uuid) else {
            env.log("refusing to open calibration: a recovery restore is still in flight")
            return false
        }
        guard env.pendingRecord(uuid) == nil else {
            env.log("refusing to open calibration: an unresolved pending record is on disk")
            return false
        }

        let started = InputCalibrationSession(
            displayUUID: uuid,
            originalCode: originalCode,
            candidates: candidates,
            confirmWindow: confirmWindow
        )
        generation &+= 1
        revertedCodes = []
        lastRevert = nil
        secondsRemaining = 0
        closeRequested = false
        session = started
        env.log("calibration session opened, original input \(originalCode)")
        onChange?()
        return true
    }

    var isCalibrating: Bool { session != nil }

    func isCalibrating(_ uuid: DisplayUUID) -> Bool { session?.displayUUID == uuid }

    // MARK: - User actions

    func test(_ code: UInt16) { send(.test(code)) }
    func keep() { send(.keep) }
    func revertNow() { send(.cancel) }
    func name(_ label: String) { send(.named(label)) }

    /// Closes the wizard. Mid-trial this reverts first — a window close is not
    /// permission to leave an unconfirmed code on the panel.
    func close() {
        closeRequested = true
        send(.finish)
    }

    // MARK: - Event plumbing

    private func send(_ event: InputCalibrationEvent) {
        guard var current = session else { return }
        let before = current.phase
        let effects = current.apply(event, now: env.now())
        session = current
        notePhaseChange(from: before, to: current.phase)
        updateCountdownReadout()
        perform(effects)
        finishIfSettled()
        onChange?()
    }

    /// Keeps the wizard's summary fields in step with the state machine, so the
    /// view never has to infer "did that trial fail?" from a phase transition it
    /// might miss between renders.
    private func notePhaseChange(from before: InputCalibrationPhase, to after: InputCalibrationPhase) {
        if case .switching = after {
            lastRevert = nil
            return
        }
        // `attempt == 1` and a non-reverting predecessor together mean this is
        // the start of a revert rather than one of its retries.
        guard case .reverting(let code, let reason, let attempt) = after, attempt == 1 else { return }
        if case .reverting = before { return }
        lastRevert = reason
        if !revertedCodes.contains(code) { revertedCodes.append(code) }
    }

    /// Ends the session once it is safe to: the machine reached `.finished`, or
    /// a close request that had to wait for a write can finally be honoured.
    ///
    /// `.confirming` belongs in the *resend* list, not the wait list. Reaching it
    /// with a close pending means the user hit close during `.switching` and the
    /// candidate write has just been acknowledged, so the machine armed a fresh
    /// full-length countdown — a countdown nobody is watching, because the window
    /// is already gone. Re-sending `.finish` maps to `cancel()`, which reverts
    /// immediately. Waiting instead would leave an unconfirmed code on the panel
    /// for up to the whole confirm window.
    private func finishIfSettled() {
        guard let phase = session?.phase else { return }
        if case .finished = phase { endSession(); return }
        guard closeRequested else { return }
        switch phase {
        case .choosing, .naming, .interrupted, .revertFailed, .confirming:
            send(.finish)
        case .switching, .reverting, .finished:
            // A 0x60 write is still in flight and its result has to be acted on.
            // The close waits; `send` re-enters here when the phase settles.
            break
        }
    }

    private func perform(_ effects: [InputCalibrationEffect]) {
        // `writeInput` is always the last effect of a transition, which is what
        // makes it safe for it to re-enter `send` when the display has vanished.
        for effect in effects {
            switch effect {
            case .persistPending(let pending):
                persistPending(pending)
            case .clearPending:
                clearPending()
            case .persistConfirmed(let entry):
                persistConfirmed(entry)
            case .armDeadline:
                armTimer()
            case .cancelDeadline:
                cancelTimer()
            case .writeInput(let code):
                writeInput(code)
            }
        }
    }

    private func persistPending(_ pending: PendingInputCalibration) {
        guard let uuid = session?.displayUUID else { return }
        env.writePendingRecord(uuid, pending)
    }

    private func clearPending() {
        guard let uuid = session?.displayUUID else { return }
        env.writePendingRecord(uuid, nil)
    }

    private func persistConfirmed(_ entry: CalibratedInput) {
        guard let uuid = session?.displayUUID else { return }
        env.appendConfirmedInput(uuid, entry)
        env.log("calibration confirmed input \(entry.code)")
    }

    /// Issues the one DDC write this feature performs, and routes its result back
    /// as the event the current phase is waiting for.
    private func writeInput(_ code: UInt16) {
        guard let session, let displayID = env.displayID(session.displayUUID) else {
            // The display went while an effect was queued. Do not write blind:
            // report it as a disconnect and let the pending record survive for
            // the recovery path.
            send(.displayDisconnected)
            return
        }
        let isRevert = session.isRevertInProgress
        let uuid = session.displayUUID
        let token = generation
        env.writeInputSource(displayID, code) { [weak self] acked in
            guard let self, self.generation == token else { return }
            if acked {
                // Keep the rest of the app's "the monitor is on this right now"
                // tier honest while the wizard moves the input around.
                self.env.noteInputSource(uuid, code)
            }
            self.send(isRevert ? .revertCompleted(acknowledged: acked) : .writeCompleted(acknowledged: acked))
        }
    }

    // MARK: - Countdown

    private func armTimer() {
        env.startTicking(Self.tickInterval) { [weak self] in
            guard let self else { return }
            self.send(.tick(self.env.now()))
        }
        updateCountdownReadout()
    }

    private func cancelTimer() {
        env.stopTicking()
    }

    private func updateCountdownReadout() {
        guard let deadline = session?.deadline else {
            secondsRemaining = 0
            return
        }
        secondsRemaining = max(0, Int(deadline.timeIntervalSince(env.now()).rounded(.up)))
    }

    // MARK: - Disconnect

    /// Called when the screen list changes. A display vanishing mid-trial is a
    /// real case, not a theoretical one: the wizard is used precisely when cables
    /// are being moved around.
    func checkDisplayStillAttached() {
        guard let session else { return }
        guard env.displayID(session.displayUUID) == nil else { return }
        env.log("calibrating display disconnected; leaving the pending record for recovery")
        send(.displayDisconnected)
    }

    private func endSession() {
        cancelTimer()
        generation &+= 1
        closeRequested = false
        session = nil
        secondsRemaining = 0
        onChange?()
    }

    // MARK: - Recovery

    /// Whether the live session is *actively driving* the revert for this display.
    ///
    /// The distinction that matters is "owns the recovery" versus "exists". Only
    /// `.switching`, `.confirming` and `.reverting` own it: in those three the
    /// session has a write in flight or a countdown armed, and a second writer
    /// would race it.
    ///
    /// `.interrupted` and `.revertFailed` explicitly do *not*. They are the two
    /// phases documented as "the pending record stays on disk so reconnect or
    /// relaunch repairs it" — the session has run out of things it can do, and
    /// gating the reconnect repair on the mere existence of a session object is
    /// what left a stuck display unrepairable while the wizard was still open.
    /// `.choosing`, `.naming` and `.finished` do not own it either, and cannot be
    /// harmed by the repair: in all three the record has already been cleared, so
    /// the recovery decision is `.none` and nothing is written.
    private func ownsRecovery(_ uuid: DisplayUUID) -> Bool {
        guard let session, session.displayUUID == uuid else { return false }
        switch session.phase {
        case .switching, .confirming, .reverting:
            return true
        case .choosing, .naming, .interrupted, .revertFailed, .finished:
            return false
        }
    }

    /// Repairs a calibration that never finished. Driven from
    /// `DDCFeatureService.refreshInputSource`, which runs at launch and on every
    /// reconnect — the two moments a stranded monitor can be reached again.
    ///
    /// - Parameter currentInput: what the 0x60 read answered, or `nil` if it
    ///   failed. Both are handled; see `InputCalibrationRecovery.decide`.
    func restoreIfInterrupted(uuid: DisplayUUID, displayID: CGDirectDisplayID, currentInput: UInt16?) {
        // Never fight a session that is mid-trial: the untested code on the panel
        // right now is supposed to be there, and that session's own countdown owns
        // the revert. A session that has given up is a different matter.
        guard !ownsRecovery(uuid), !restoresInFlight.contains(uuid) else { return }
        let pending = env.pendingRecord(uuid)
        switch InputCalibrationRecovery.decide(pending: pending, currentInput: currentInput, now: env.now()) {
        case .none:
            return
        case .clear(let reason):
            env.log("dropping pending input calibration (\(reason))")
            env.writePendingRecord(uuid, nil)
        case .restore(let code):
            env.log("restoring input \(code) after an interrupted calibration")
            restoresInFlight.insert(uuid)
            env.writeInputSource(displayID, code) { [weak self] acked in
                guard let self else { return }
                self.restoresInFlight.remove(uuid)
                guard acked else {
                    // Leave the record: the next read of this display tries
                    // again. A restore that quietly gives up is the failure
                    // this whole path exists to prevent.
                    self.env.log("input restore was not acknowledged; keeping the record for the next attempt")
                    return
                }
                self.env.noteInputSource(uuid, code)
                self.env.writePendingRecord(uuid, nil)
            }
        }
    }
}

extension InputCalibrationSession {
    /// Whether the write currently in flight is the revert rather than the
    /// candidate. Read at issue time, so a completion can be routed to the event
    /// its phase is waiting for.
    var isRevertInProgress: Bool {
        if case .reverting = phase { return true }
        return false
    }
}
