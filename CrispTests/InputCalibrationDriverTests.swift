import XCTest
import CoreGraphics

/// Headless tests for the calibration wizard's *glue* — `InputCalibrationDriver`.
///
/// The state machine in `InputCalibration.swift` was already covered by
/// `InputCalibrationTests`. This file covers the layer around it, which is where
/// the close request, the recovery ownership and the in-flight restores live —
/// state the pure machine cannot see, and therefore state it cannot protect.
/// Three shipped bugs lived here precisely because nothing compiled this code
/// into a test target.
///
/// Everything impure is injected through `InputCalibrationEnvironment` (the clock,
/// the 0x60 write, the tick source, the store, the display list), so a whole
/// session runs here **with no display attached and without ever executing a VCP
/// 0x60 write** — the same guarantee `InputCalibrationTests` makes, extended to
/// the code that would have done the writing.
///
/// Each test names the mutation it is designed to kill in a trailing comment.
@MainActor
final class InputCalibrationDriverTests: XCTestCase {

    private let uuid = DisplayUUID("CAL-DRIVER-UUID")
    /// The BenQ MA320U's real code. Proven live: the user is looking at the
    /// wizard on it when the session opens.
    private let original: UInt16 = 19
    private let candidate: UInt16 = 0x21

    // MARK: - Finding 1: closing mid-write must revert, not re-arm

    /// Close pressed while the candidate write is still in flight. When the ack
    /// lands, the machine arms a fresh full-length countdown — one nobody is
    /// watching, because the window has already gone. The driver has to notice
    /// and re-send `.finish`, which in `.confirming` means "revert now".
    /// Kills mutation: leaving `.confirming` in `finishIfSettled`'s wait list
    /// (its shipped state), which strands the panel on an unconfirmed input for
    /// up to the whole confirm window — up to 120 s — with no UI to undo it.
    func testClosingDuringTheCandidateWriteRevertsAsSoonAsItIsAcknowledged() {
        let harness = Harness(uuid: uuid)
        XCTAssertTrue(harness.beginSession(original: original))

        harness.driver.test(candidate)
        XCTAssertEqual(harness.pendingWrites.map(\.code), [candidate])

        // `.switching`: `finish` is a deliberate no-op, so the close is deferred.
        harness.driver.close()
        XCTAssertEqual(harness.driver.session?.phase, .switching(candidate: candidate))
        XCTAssertEqual(harness.pendingWrites.count, 1, "close must not stack a second write")

        harness.completeNextWrite(acknowledged: true)

        XCTAssertEqual(
            harness.driver.session?.phase,
            .reverting(candidate: candidate, reason: .userCancelled, attempt: 1),
            "the deferred close must revert, not arm a countdown"
        )
        XCTAssertEqual(harness.writtenCodes, [candidate, original])
        XCTAssertFalse(harness.isTicking, "a countdown nobody can see must not be left running")
    }

    /// …and once the revert is acknowledged the session actually ends, so the
    /// window the user closed goes away instead of sitting there empty.
    /// Kills mutation: honouring the close by dropping `closeRequested` when the
    /// revert starts, which reverts correctly and then never finishes.
    func testTheDeferredCloseEndsTheSessionOnceTheRevertIsAcknowledged() {
        let harness = Harness(uuid: uuid)
        harness.beginSession(original: original)
        harness.driver.test(candidate)
        harness.driver.close()
        harness.completeNextWrite(acknowledged: true)   // candidate acked → deferred revert
        harness.completeNextWrite(acknowledged: true)   // revert acked

        XCTAssertNil(harness.driver.session, "the close request must be honoured once the panel is safe")
        XCTAssertNil(harness.pending, "a monitor back on its original code keeps no recovery record")
        XCTAssertFalse(harness.isTicking)
    }

    /// The wait list still has to hold for the phases that genuinely own a write.
    /// Kills mutation: adding `.switching` or `.reverting` to the resend list,
    /// which drops the in-flight write's result on the floor — closing the wizard
    /// would then abandon the panel on the untested code.
    func testClosingDuringTheRevertWaitsForItRatherThanEndingTheSession() {
        let harness = Harness(uuid: uuid)
        harness.beginSession(original: original)
        harness.driver.test(candidate)
        harness.completeNextWrite(acknowledged: true)
        harness.driver.revertNow()
        XCTAssertEqual(
            harness.driver.session?.phase,
            .reverting(candidate: candidate, reason: .userCancelled, attempt: 1)
        )

        harness.driver.close()

        XCTAssertNotNil(harness.driver.session, "the session may not end with a 0x60 write outstanding")
        XCTAssertEqual(harness.writtenCodes, [candidate, original], "and must not issue a third write")
    }

    // MARK: - Finding 2: reconnect must repair a session that has given up

    /// The display is unplugged mid-trial, so the session parks in `.interrupted`
    /// and the pending record stays on disk. When the display comes back, the
    /// reconnect read has to be able to repair it **even though the wizard window
    /// is still open** — on a single-external-display Mac the user may have no
    /// screen with which to close it.
    /// Kills mutation: gating `restoreIfInterrupted` on `session != nil` (its
    /// shipped state), which makes the reconnect path a no-op in exactly the
    /// phase whose documented recovery route is the reconnect path.
    func testReconnectRepairsADisplayLeftInterruptedWhileTheWizardIsStillOpen() {
        let harness = Harness(uuid: uuid)
        harness.beginSession(original: original)
        harness.driver.test(candidate)
        harness.completeNextWrite(acknowledged: true)

        harness.detachDisplay()
        harness.driver.checkDisplayStillAttached()
        XCTAssertEqual(harness.driver.session?.phase, .interrupted)
        XCTAssertEqual(harness.pending?.originalCode, original, "the record must survive the disconnect")

        // Reconnect: a fresh CGDirectDisplayID, as macOS hands out (AGENTS.md §3.3).
        harness.attachDisplay(id: 42)
        harness.driver.restoreIfInterrupted(uuid: uuid, displayID: 42, currentInput: candidate)

        XCTAssertEqual(harness.pendingWrites.map(\.code), [original], "the repair must write the original back")
        XCTAssertEqual(harness.pendingWrites.first?.displayID, 42, "on the display's new ID")
        harness.completeNextWrite(acknowledged: true)
        XCTAssertNil(harness.pending, "an acknowledged restore clears the record")
        XCTAssertNotNil(harness.driver.session, "repairing the panel does not require closing the wizard")
    }

    /// Same for `.revertFailed`: three revert writes went unacknowledged, the
    /// session gave up on purpose and left the record for the recovery path.
    /// Kills mutation: treating `.revertFailed` as "a session owns this display",
    /// which makes the record it deliberately left behind unusable.
    func testReconnectRepairsADisplayWhoseRevertsAllFailed() {
        let harness = Harness(uuid: uuid)
        harness.beginSession(original: original)
        harness.driver.test(candidate)
        harness.completeNextWrite(acknowledged: true)
        harness.driver.revertNow()
        for _ in 0..<InputCalibrationSession.maxRevertAttempts {
            harness.completeNextWrite(acknowledged: false)
        }
        XCTAssertEqual(harness.driver.session?.phase, .revertFailed(candidate: candidate))
        XCTAssertNotNil(harness.pending, "a failed revert keeps the record on purpose")

        harness.driver.restoreIfInterrupted(uuid: uuid, displayID: harness.displayID, currentInput: nil)

        XCTAssertEqual(harness.pendingWrites.map(\.code), [original])
        harness.completeNextWrite(acknowledged: true)
        XCTAssertNil(harness.pending)
    }

    /// The other half of the same rule: a session that *is* mid-trial owns its own
    /// revert, and a reconnect read must not race it with a second 0x60 write.
    /// Kills mutation: dropping the ownership guard entirely, which lets the
    /// reconnect path write the original back underneath a live countdown — the
    /// user's screen changes twice and the session's own revert follows.
    func testReconnectNeverTouchesADisplayWhoseSessionIsMidTrial() {
        let harness = Harness(uuid: uuid)
        harness.beginSession(original: original)
        harness.driver.test(candidate)
        harness.completeNextWrite(acknowledged: true)
        XCTAssertEqual(harness.driver.session?.phase.isConfirming, true)

        harness.driver.restoreIfInterrupted(uuid: uuid, displayID: harness.displayID, currentInput: candidate)

        XCTAssertTrue(harness.pendingWrites.isEmpty, "the live session's countdown owns this revert")
        XCTAssertNotNil(harness.pending, "and its record must stay until that revert lands")
    }

    // MARK: - Finding 3: a new session may not adopt an unproven code

    /// After a crash mid-trial the reconnect read adopts the *untested* code as
    /// `display.inputSource` and starts the repair. A session opened in that
    /// window would take that code as its `originalCode` — making every revert in
    /// the new session restore a code that may show nothing.
    /// Kills mutation: dropping `begin`'s pending-record guard, which lets an
    /// unproven candidate become the session's entire safety net.
    func testBeginRefusesWhileAnUnresolvedPendingRecordIsOnDisk() {
        let harness = Harness(uuid: uuid)
        harness.pending = PendingInputCalibration(
            originalCode: original, candidateCode: candidate, startedAt: harness.now
        )

        XCTAssertFalse(harness.beginSession(original: candidate))
        XCTAssertNil(harness.driver.session)
        XCTAssertTrue(harness.pendingWrites.isEmpty, "a refused session writes nothing")
    }

    /// Same invariant, the other trigger: the recovery restore's 0x60 write is
    /// still in flight, so the code the monitor reports is the one being undone.
    /// The record is cleared here by hand to isolate the in-flight guard from the
    /// pending-record guard — only the former can refuse this.
    /// Kills mutation: dropping `begin`'s `restoresInFlight` guard.
    func testBeginRefusesWhileARecoveryRestoreIsStillInFlight() {
        let harness = Harness(uuid: uuid)
        harness.pending = PendingInputCalibration(
            originalCode: original, candidateCode: candidate, startedAt: harness.now
        )
        harness.driver.restoreIfInterrupted(uuid: uuid, displayID: harness.displayID, currentInput: candidate)
        XCTAssertEqual(harness.pendingWrites.map(\.code), [original], "the restore is in flight")
        harness.pending = nil

        XCTAssertFalse(harness.beginSession(original: candidate))
        XCTAssertNil(harness.driver.session)
    }

    /// The refusal is a wait, not a ban: once the restore is acknowledged and the
    /// record is gone, calibration opens normally on the now-proven code.
    /// Kills mutation: latching the refusal (e.g. a `hasEverRestored` flag), which
    /// would make the wizard permanently unusable after one interrupted session.
    func testBeginSucceedsOnceTheRestoreIsAcknowledgedAndTheRecordIsGone() {
        let harness = Harness(uuid: uuid)
        harness.pending = PendingInputCalibration(
            originalCode: original, candidateCode: candidate, startedAt: harness.now
        )
        harness.driver.restoreIfInterrupted(uuid: uuid, displayID: harness.displayID, currentInput: candidate)
        harness.completeNextWrite(acknowledged: true)

        XCTAssertNil(harness.pending)
        XCTAssertTrue(harness.beginSession(original: original))
        XCTAssertEqual(harness.driver.session?.originalCode, original)
    }

    /// And a second session may not open on top of a live one: two panels being
    /// switched at once is not a scenario with a safe revert.
    /// Kills mutation: dropping `begin`'s `session == nil` guard.
    func testBeginRefusesWhileASessionIsAlreadyOpen() {
        let harness = Harness(uuid: uuid)
        XCTAssertTrue(harness.beginSession(original: original))
        XCTAssertFalse(harness.beginSession(original: original))
    }

    // MARK: - Countdown wiring

    /// The tick source is armed by `.armDeadline` and stopped by `.cancelDeadline`,
    /// and a tick delivered past the absolute deadline reverts on arrival.
    /// Kills mutation: never wiring `armDeadline` to the tick source (the trial
    /// then never times out at all), or ticking off a decremented counter, which a
    /// late tick would reset instead of firing.
    func testTheCountdownArmsOnConfirmAndALateTickStillReverts() {
        let harness = Harness(uuid: uuid)
        harness.beginSession(original: original, confirmWindow: 15)
        harness.driver.test(candidate)
        harness.completeNextWrite(acknowledged: true)

        XCTAssertTrue(harness.isTicking)
        XCTAssertEqual(harness.driver.secondsRemaining, 15)

        // A machine that slept: the tick arrives a minute late, not on schedule.
        harness.now += 75
        harness.fireTick()

        XCTAssertEqual(
            harness.driver.session?.phase,
            .reverting(candidate: candidate, reason: .timedOut, attempt: 1)
        )
        XCTAssertEqual(harness.writtenCodes, [candidate, original])
        XCTAssertFalse(harness.isTicking)
    }

    /// A write issued for a session that has since ended must not drive the new
    /// one. The generation token is the only thing standing between a slow DDC ack
    /// and a phantom event in an unrelated session.
    /// Kills mutation: dropping the generation check in the write completion.
    func testAWriteCompletionFromAnEndedSessionIsIgnored() {
        let harness = Harness(uuid: uuid)
        harness.beginSession(original: original)
        harness.driver.test(candidate)
        let stale = harness.takeNextWrite()

        harness.detachDisplay()
        harness.driver.checkDisplayStillAttached()
        harness.driver.close()
        XCTAssertNil(harness.driver.session, "an interrupted session closes immediately")

        stale.completion(true)

        XCTAssertNil(harness.driver.session, "a late ack must not resurrect anything")
        XCTAssertTrue(harness.pendingWrites.isEmpty)
    }

}

// MARK: - Harness

/// The injected world: a clock the test moves, a display list it can unplug, a
/// store in a dictionary, and a 0x60 "write" that records the request and hands
/// the test its completion. No monitor, no I2C, no timer.
@MainActor
private final class Harness {

    /// One 0x60 write the driver asked for, still waiting for its answer.
    struct Write {
        let displayID: CGDirectDisplayID
        let code: UInt16
        let completion: (Bool) -> Void
    }

    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var pending: PendingInputCalibration?
    private(set) var confirmed: [CalibratedInput] = []
    private(set) var reportedInputSource: UInt16?
    private(set) var pendingWrites: [Write] = []
    private(set) var writtenCodes: [UInt16] = []
    private(set) var isTicking = false
    private(set) var logs: [String] = []
    private(set) var displayID: CGDirectDisplayID = 7

    private let uuid: DisplayUUID
    private var attachedID: CGDirectDisplayID?
    private var tick: (() -> Void)?

    /// `lazy` so the environment closures can capture a fully-initialised `self`
    /// (`unowned`, because the driver holds them and this holds the driver).
    private(set) lazy var driver = InputCalibrationDriver(environment: InputCalibrationEnvironment(
        now: { [unowned self] in self.now },
        displayID: { [unowned self] requested in requested == self.uuid ? self.attachedID : nil },
        writeInputSource: { [unowned self] id, code, completion in
            self.writtenCodes.append(code)
            self.pendingWrites.append(Write(displayID: id, code: code, completion: completion))
        },
        noteInputSource: { [unowned self] _, code in self.reportedInputSource = code },
        pendingRecord: { [unowned self] _ in self.pending },
        writePendingRecord: { [unowned self] _, record in self.pending = record },
        appendConfirmedInput: { [unowned self] _, entry in self.confirmed.append(entry) },
        startTicking: { [unowned self] _, handler in
            self.isTicking = true
            self.tick = handler
        },
        stopTicking: { [unowned self] in
            self.isTicking = false
            self.tick = nil
        },
        log: { [unowned self] message in self.logs.append(message) }
    ))

    init(uuid: DisplayUUID) {
        self.uuid = uuid
        attachedID = displayID
    }

    @discardableResult
    func beginSession(
        original: UInt16,
        confirmWindow: TimeInterval = InputCalibrationSession.defaultConfirmWindow
    ) -> Bool {
        driver.begin(
            uuid: uuid,
            originalCode: original,
            candidates: [original, 0x21, 0x0F],
            confirmWindow: confirmWindow
        )
    }

    /// Pops the oldest outstanding write without answering it, for tests that
    /// need to answer it after the session has moved on.
    func takeNextWrite() -> Write {
        pendingWrites.removeFirst()
    }

    /// Answers the oldest outstanding write, the way `DDCService` eventually
    /// would. Deliberately not synchronous with the call that issued it: the real
    /// completion always arrives after the transition that queued it has
    /// returned, and re-entering mid-transition would test an ordering that
    /// cannot happen.
    func completeNextWrite(acknowledged: Bool) {
        guard !pendingWrites.isEmpty else { return XCTFail("no 0x60 write was outstanding") }
        pendingWrites.removeFirst().completion(acknowledged)
    }

    func fireTick() { tick?() }

    func detachDisplay() { attachedID = nil }

    func attachDisplay(id: CGDirectDisplayID) {
        displayID = id
        attachedID = id
    }
}

private extension InputCalibrationPhase {
    var isConfirming: Bool {
        if case .confirming = self { return true }
        return false
    }
}
