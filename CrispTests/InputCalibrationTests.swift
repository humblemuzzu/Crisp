import XCTest

/// Headless tests for the input-source calibration wizard's decision core.
///
/// `InputCalibration`, `InputCalibrationReport`, `MonitorQuirks` and
/// `DisplayStateDocument` are all compiled directly into this target (see
/// `project.yml`), so a whole multi-step session can be driven here — switch,
/// expire the countdown, kill the app, unplug the monitor, come back — **without
/// a monitor attached and without ever executing a VCP 0x60 write**. That is not
/// a convenience. Writing 0x60 is the one DDC operation whose failure the user
/// cannot undo from the Mac, so the properties below have to be checkable
/// somewhere that is not the hardware.
///
/// Each test names the mutation it is designed to kill.
final class InputCalibrationTests: XCTestCase {

    private let uuid = DisplayUUID("CAL-TEST-UUID")
    /// The BenQ MA320U's real code: reported as 19, which the VESA table calls
    /// "DVI-10" on a panel with no DVI port. The whole feature exists for this.
    private let original: UInt16 = 19
    private let candidate: UInt16 = 0x21

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Candidate enumeration

    /// The list has to start where the monitor already is and still reach codes
    /// nobody has written down: the current code is the only one guaranteed
    /// visible, and the generic VESA codes are the only route to an unmapped port.
    /// Kills mutation: dropping either the current input or the standard table
    /// from the candidate list, which would make the wizard unable to calibrate
    /// exactly the monitors it exists for.
    func testCandidatesLeadWithTheCurrentInputAndReachTheStandardTable() {
        let codes = InputCalibrationPlan.candidates(
            quirks: nil, currentInput: original, standardCodes: [0x0F, 0x21]
        )
        XCTAssertEqual(codes.first, original, "the code the monitor is on must be offered first")
        XCTAssertTrue(codes.contains(0x0F))
        XCTAssertTrue(codes.contains(0x21))
    }

    /// `complete` tells the everyday menu to stop offering generic codes for a
    /// fully-mapped model. Calibration is the act of *finding* the codes a
    /// contributor did not list, so it must ignore that flag.
    /// Kills mutation: implementing `candidates` by delegating to
    /// `MonitorQuirkResolver.inputOptions`, which honours `complete` — the wizard
    /// would then be unable to discover anything new about the very models whose
    /// entries somebody was over-confident about.
    func testCandidatesKeepStandardCodesEvenWhenTheDatabaseCallsItsListComplete() {
        let quirks = quirksWithCompleteInputList(code: 0x0F)
        let wizard = InputCalibrationPlan.candidates(
            quirks: quirks, currentInput: original, standardCodes: [0x21]
        )
        let menu = MonitorQuirkResolver.inputOptions(
            quirks: quirks, currentInput: original, userSelectedInput: nil, standardCodes: [0x21]
        ).map(\.code)

        XCTAssertTrue(wizard.contains(0x21), "calibration must still be able to try an unlisted code")
        XCTAssertFalse(menu.contains(0x21), "the everyday menu still honours `complete`")
    }

    /// A code that is current *and* in the database *and* in the VESA table is
    /// still one port.
    /// Kills mutation: dropping the dedup, which offers the same code three times
    /// and invites the user to blank their screen on a port they already tested.
    func testCandidatesDeduplicatePreservingOrder() {
        let codes = InputCalibrationPlan.candidates(
            quirks: quirksWithInput(code: 0x21, confidence: "reported"),
            currentInput: 0x21,
            calibrated: [0x21: "HDMI 1"],
            standardCodes: [0x21, 0x0F, 0x21]
        )
        XCTAssertEqual(codes, [0x21, 0x0F])
    }

    // MARK: - Starting a trial

    /// The crash-recovery record is written *before* the switch it protects.
    /// Kills mutation: emitting `.writeInput` first (or persisting after the ack).
    /// In that order a process that dies between the two leaves the panel on an
    /// untested code with nothing on disk saying what to put back — which is
    /// precisely the stranded state this whole type exists to make impossible.
    func testTestingACandidatePersistsTheRecoveryRecordBeforeWritingIt() {
        var session = makeSession()
        let effects = session.apply(.test(candidate), now: epoch)

        XCTAssertEqual(effects, [
            .persistPending(PendingInputCalibration(
                originalCode: original, candidateCode: candidate, startedAt: epoch
            )),
            .writeInput(candidate)
        ])
        XCTAssertEqual(session.phase, .switching(candidate: candidate))
    }

    /// The countdown is armed on an absolute instant, not a counter.
    /// Kills mutation: storing a remaining-seconds `Int` and decrementing it per
    /// tick, which a delayed or coalesced tick silently extends.
    func testAnAcknowledgedWriteArmsAnAbsoluteDeadline() {
        var session = makeSession()
        session.apply(.test(candidate), now: epoch)
        let effects = session.apply(.writeCompleted(acknowledged: true), now: epoch)

        let deadline = epoch.addingTimeInterval(InputCalibrationSession.defaultConfirmWindow)
        XCTAssertEqual(effects, [.armDeadline(deadline)])
        XCTAssertEqual(session.deadline, deadline)
    }

    /// A confirmation window outside the sane band is a programming error, not a
    /// preference: too short and a panel that takes seconds to lock the new input
    /// reverts before it has drawn anything; too long and "walked away" becomes
    /// indistinguishable from "stranded".
    /// Kills mutation: dropping the clamp, e.g. a zero window that reverts before
    /// the user can possibly answer.
    func testTheConfirmationWindowIsClamped() {
        XCTAssertEqual(makeSession(window: 0).confirmWindow, InputCalibrationSession.confirmWindowBounds.lowerBound)
        XCTAssertEqual(makeSession(window: 9999).confirmWindow, InputCalibrationSession.confirmWindowBounds.upperBound)
        XCTAssertEqual(makeSession(window: 20).confirmWindow, 20)
    }

    // MARK: - Timeout always reverts

    /// The headline property. The likely reality when the user says nothing is
    /// that the switch worked, the Mac is still rendering, and they can see none
    /// of it — so silence must undo the switch.
    /// Kills mutation: treating an expired countdown as anything other than a
    /// revert (leaving the trial open, or "keeping" it because the write acked).
    func testCountdownExpiryRevertsToTheOriginalCode() {
        var session = openTrial()
        let effects = session.apply(.tick(epoch.addingTimeInterval(15)), now: epoch)

        XCTAssertEqual(effects, [.cancelDeadline, .writeInput(original)])
        XCTAssertEqual(session.phase, .reverting(candidate: candidate, reason: .timedOut, attempt: 1))
    }

    /// Ticking is not the same as expiring.
    /// Kills mutation: reverting on any tick, which makes the confirmation window
    /// a quarter of a second long and the feature unusable.
    func testATickBeforeTheDeadlineChangesNothing() {
        var session = openTrial()
        let effects = session.apply(.tick(epoch.addingTimeInterval(14.9)), now: epoch)

        XCTAssertEqual(effects, [])
        XCTAssertEqual(session.phase, .confirming(
            candidate: candidate, deadline: epoch.addingTimeInterval(15)
        ))
    }

    /// The main actor can be busy, and a Mac can sleep. The first tick after the
    /// deadline must still revert however late it is.
    /// Kills mutation: comparing `now == deadline`, or restarting the countdown
    /// when a tick arrives outside the expected cadence — a stranded user would
    /// then wait forever.
    func testAVeryLateTickStillReverts() {
        var session = openTrial()
        let effects = session.apply(.tick(epoch.addingTimeInterval(600)), now: epoch)

        XCTAssertEqual(effects, [.cancelDeadline, .writeInput(original)])
    }

    /// "Keep" arriving after the revert has begun must not resurrect the trial.
    /// Kills mutation: handling `.keep` from any phase. The user cannot have seen
    /// anything — the countdown already proved that — so accepting a late click
    /// (a queued event, a stuck key) would both strand them and mint `verified`
    /// data out of nothing.
    func testKeepAfterTheDeadlineCannotUndoTheRevert() {
        var session = openTrial()
        session.apply(.tick(epoch.addingTimeInterval(15)), now: epoch)

        let effects = session.apply(.keep, now: epoch)

        XCTAssertEqual(effects, [])
        XCTAssertEqual(session.phase, .reverting(candidate: candidate, reason: .timedOut, attempt: 1))
        XCTAssertTrue(session.confirmed.isEmpty, "a late Keep must not confirm anything")
    }

    /// A missing DDC acknowledgement does not prove the write failed to land:
    /// replies get lost and several monitors go quiet while the link renegotiates.
    /// Kills mutation: treating "not acked" as "nothing happened" and returning to
    /// the candidate list — skipping the revert in exactly the case where the
    /// screen is most likely already black.
    func testAnUnacknowledgedCandidateWriteStillReverts() {
        var session = makeSession()
        session.apply(.test(candidate), now: epoch)
        let effects = session.apply(.writeCompleted(acknowledged: false), now: epoch)

        XCTAssertEqual(effects, [.cancelDeadline, .writeInput(original)])
        XCTAssertEqual(
            session.phase,
            .reverting(candidate: candidate, reason: .writeNotAcknowledged, attempt: 1)
        )
    }

    // MARK: - Revert restores the ORIGINAL

    /// The property the task's multi-step case is about. After confirming and
    /// naming one port, the monitor is sitting on that port — but the session's
    /// original is still the code the user could see when the wizard opened, and
    /// that is what a later failed trial has to restore.
    /// Kills mutation: tracking a mutable "last known good" code and reverting to
    /// it. That is safe by luck in the two-step case and wrong in general; the
    /// original is safe by construction, because the user was demonstrably
    /// looking at the wizard on it.
    func testRevertRestoresTheSessionOriginalNotThePreviousCandidate() {
        var session = makeSession()

        // Step 1: confirm and name candidate 0x21.
        session.apply(.test(0x21), now: epoch)
        session.apply(.writeCompleted(acknowledged: true), now: epoch)
        session.apply(.keep, now: epoch)
        session.apply(.named("HDMI 1"), now: epoch)
        XCTAssertEqual(session.confirmed.map(\.code), [0x21])

        // Step 2: a dead code times out.
        session.apply(.test(0x30), now: epoch)
        session.apply(.writeCompleted(acknowledged: true), now: epoch)
        let effects = session.apply(.tick(epoch.addingTimeInterval(999)), now: epoch)

        XCTAssertEqual(effects, [.cancelDeadline, .writeInput(original)])
        XCTAssertNotEqual(effects, [.cancelDeadline, .writeInput(0x21)], "not the previous candidate")
    }

    /// A revert the monitor never acknowledges is retried, and when the retries
    /// run out the recovery record is deliberately left on disk.
    /// Kills mutation: clearing the record (or reporting success) after a failed
    /// revert. The record is the only thing that lets the next launch or the next
    /// reconnect finish the job, and a revert that quietly gives up is the exact
    /// failure this file exists to prevent.
    func testAFailedRevertRetriesAndThenKeepsTheRecoveryRecord() {
        var session = openTrial()
        session.apply(.tick(epoch.addingTimeInterval(15)), now: epoch)

        for attempt in 1..<InputCalibrationSession.maxRevertAttempts {
            let retry = session.apply(.revertCompleted(acknowledged: false), now: epoch)
            XCTAssertEqual(retry, [.writeInput(original)], "attempt \(attempt) must be retried")
        }

        let giveUp = session.apply(.revertCompleted(acknowledged: false), now: epoch)
        XCTAssertEqual(giveUp, [], "no `.clearPending`: the record has to outlive the session")
        XCTAssertEqual(session.phase, .revertFailed(candidate: candidate))
    }

    /// A revert the monitor accepts puts the user back in front of a working
    /// screen, so the recovery record has done its job and must go.
    /// Kills mutation: leaving the record behind, which would make the next launch
    /// "restore" an input that was never lost.
    func testAnAcknowledgedRevertClearsTheRecoveryRecord() {
        var session = openTrial()
        session.apply(.tick(epoch.addingTimeInterval(15)), now: epoch)

        let effects = session.apply(.revertCompleted(acknowledged: true), now: epoch)

        XCTAssertEqual(effects, [.clearPending])
        XCTAssertEqual(session.phase, .choosing)
    }

    // MARK: - Confirmation is the only route to `verified`

    /// Keep means "I can see this", so the recovery record goes immediately —
    /// but nothing is confirmed until the port is actually named.
    /// Kills mutation: recording the mapping on `.keep`, which would confirm a
    /// code with no port attached to the claim.
    func testKeepClearsTheRecordButConfirmsNothingYet() {
        var session = openTrial()
        let effects = session.apply(.keep, now: epoch)

        XCTAssertEqual(effects, [.cancelDeadline, .clearPending])
        XCTAssertEqual(session.phase, .naming(candidate: candidate))
        XCTAssertTrue(session.confirmed.isEmpty)
    }

    /// The only route into `confirmed` runs through a human saying they can see
    /// the screen. Everything else — timeout, cancel, a dead write — leaves the
    /// session with nothing to contribute.
    /// Kills mutation: confirming on any trial that ran, which would put guessed
    /// input codes into a `verified` database entry and past every confirmation
    /// dialog the app has.
    func testOnlyAConfirmedTrialProducesAMapping() {
        var timedOut = makeSession()
        timedOut.apply(.test(candidate), now: epoch)
        timedOut.apply(.writeCompleted(acknowledged: true), now: epoch)
        timedOut.apply(.tick(epoch.addingTimeInterval(15)), now: epoch)
        timedOut.apply(.revertCompleted(acknowledged: true), now: epoch)
        timedOut.apply(.named("HDMI 1"), now: epoch)
        XCTAssertTrue(timedOut.confirmed.isEmpty, "a naming event outside `.naming` confirms nothing")

        var cancelled = openTrial()
        cancelled.apply(.cancel, now: epoch)
        cancelled.apply(.revertCompleted(acknowledged: true), now: epoch)
        XCTAssertTrue(cancelled.confirmed.isEmpty)

        var kept = openTrial()
        kept.apply(.keep, now: epoch)
        let effects = kept.apply(.named("USB-C"), now: epoch)
        XCTAssertEqual(kept.confirmed.map(\.label), ["USB-C"])
        XCTAssertEqual(effects, [.persistConfirmed(CalibratedInput(
            code: candidate, label: "USB-C", confirmedAt: epoch
        ))])
    }

    /// A user who confirms the picture but does not want to type gets a label
    /// that states exactly what was established: this code shows a picture.
    /// Kills mutation: substituting the VESA MCCS name for a blank entry, which
    /// would turn a table lookup into a `verified` measurement — the BenQ's code
    /// 19 would be recorded as a confirmed "DVI-10" on a panel with no DVI port.
    func testAnEmptyPortNameConfirmsWithAnHonestPlaceholder() {
        var session = openTrial()
        session.apply(.keep, now: epoch)
        session.apply(.named("   "), now: epoch)

        XCTAssertEqual(session.confirmed.map(\.label), ["Input-33"])
        XCTAssertNotEqual(session.confirmed.first?.label, MCCSInputTable.label(for: candidate))
    }

    /// Naming the same port twice in one session replaces the entry.
    /// Kills mutation: appending, which leaves two rows for one code and an
    /// ambiguous database entry.
    func testRenamingAPortReplacesItsEntry() {
        var session = makeSession()
        for label in ["HDMI", "HDMI 2"] {
            session.apply(.test(candidate), now: epoch)
            session.apply(.writeCompleted(acknowledged: true), now: epoch)
            session.apply(.keep, now: epoch)
            session.apply(.named(label), now: epoch)
        }
        XCTAssertEqual(session.confirmed.map(\.label), ["HDMI 2"])
    }

    /// A calibrated code is the app's strongest evidence about an input, and the
    /// only source of a `verified` *label*: the user watched the panel light up
    /// on that code and typed what was plugged in.
    /// Kills mutation: leaving the resolver's calibrated tier out, which would
    /// keep asking the user to confirm a port they personally measured — and,
    /// worse, keep printing the guessed label with its question mark as if the
    /// measurement had not happened.
    func testACalibratedCodeResolvesAsVerifiedWhereAnUncalibratedOneDoesNot() {
        let quirks = quirksWithInput(code: 19, confidence: "reported")

        let uncalibrated = MonitorQuirkResolver.input(
            code: 19, quirks: quirks, currentInput: 0x21, userSelectedInput: nil
        )
        XCTAssertTrue(uncalibrated.needsConfirmation)
        XCTAssertEqual(uncalibrated.displayLabel, "USB-C?")

        let calibrated = MonitorQuirkResolver.input(
            code: 19, quirks: quirks, currentInput: 0x21, userSelectedInput: nil,
            calibrated: [19: "USB-C (left)"]
        )
        XCTAssertFalse(calibrated.needsConfirmation)
        XCTAssertEqual(calibrated.labelSource, .userOverride)
        XCTAssertEqual(calibrated.labelConfidence, .verified)
        XCTAssertEqual(calibrated.displayLabel, "USB-C (left)", "no question mark on a measurement")
    }

    /// A port this user measured on this unit outranks a contributor's complete
    /// port list, so it appears in the menu even when the database says the list
    /// is finished without it.
    /// Kills mutation: appending calibrated codes after the `complete` check, so
    /// a user's own confirmed port disappears from their menu.
    func testCalibratedCodesAppearInTheMenuEvenWhenTheDatabaseListIsComplete() {
        let options = MonitorQuirkResolver.inputOptions(
            quirks: quirksWithCompleteInputList(code: 0x0F),
            currentInput: 0x0F,
            userSelectedInput: nil,
            calibrated: [19: "USB-C"],
            standardCodes: []
        )
        XCTAssertEqual(options.map(\.code), [0x0F, 19])
    }

    // MARK: - Crash / quit recovery

    /// The app was killed with an untested code on the panel. The countdown died
    /// with the process, so the record written before the switch is the only
    /// thing left that can put the monitor back.
    /// Kills mutation: dropping the record at startup instead of acting on it,
    /// which leaves the user on a black screen with the monitor's physical
    /// buttons as their only recovery — the failure mode the wizard promises
    /// cannot happen.
    func testRecoveryRestoresTheOriginalAfterACrash() {
        let pending = PendingInputCalibration(
            originalCode: original, candidateCode: candidate, startedAt: epoch
        )
        let decision = InputCalibrationRecovery.decide(
            pending: pending, currentInput: candidate, now: epoch.addingTimeInterval(30)
        )
        XCTAssertEqual(decision, .restore(original))
    }

    /// A monitor that cannot answer a read is exactly what a wedged, freshly
    /// switched panel looks like, and re-writing a code it is already on is a
    /// no-op.
    /// Kills mutation: requiring a successful read before restoring, which
    /// abandons the repair in the case that needs it most.
    func testRecoveryRestoresEvenWhenTheInputReadFailed() {
        let pending = PendingInputCalibration(
            originalCode: original, candidateCode: candidate, startedAt: epoch
        )
        XCTAssertEqual(
            InputCalibrationRecovery.decide(pending: pending, currentInput: nil, now: epoch),
            .restore(original)
        )
    }

    /// The revert landed before the process died, or the user fixed it with the
    /// monitor's buttons. Nothing to repair.
    /// Kills mutation: restoring unconditionally, which flips the input of a user
    /// who already sorted themselves out.
    func testRecoveryClearsWhenTheMonitorIsAlreadyOnTheOriginal() {
        let pending = PendingInputCalibration(
            originalCode: original, candidateCode: candidate, startedAt: epoch
        )
        XCTAssertEqual(
            InputCalibrationRecovery.decide(pending: pending, currentInput: original, now: epoch),
            .clear(reason: .alreadyRestored)
        )
    }

    /// "This code was live" decays as evidence. A record old enough that the desk
    /// may have been re-cabled must not be acted on, or the repair becomes the
    /// accident it exists to undo.
    /// Kills mutation: removing the age check. Note the safety argument for
    /// dropping it: a user who was actually stranded could not have launched
    /// anything, so a record this old belongs to a session that ended fine.
    func testRecoveryDropsAStaleRecordWithoutTouchingTheMonitor() {
        let pending = PendingInputCalibration(
            originalCode: original, candidateCode: candidate, startedAt: epoch
        )
        let later = epoch.addingTimeInterval(InputCalibrationRecovery.maxPendingAge + 1)
        XCTAssertEqual(
            InputCalibrationRecovery.decide(pending: pending, currentInput: candidate, now: later),
            .clear(reason: .expired)
        )
    }

    /// The overwhelmingly common case: no calibration was ever interrupted.
    /// Kills mutation: writing 0x60 at launch on an empty record.
    func testRecoveryDoesNothingWithoutARecord() {
        XCTAssertEqual(
            InputCalibrationRecovery.decide(pending: nil, currentInput: 19, now: epoch),
            .none
        )
    }

    // MARK: - Disconnect

    /// A disconnect mid-trial is a real case — the wizard is used precisely while
    /// cables are being moved. Nothing can be written to a display that is not
    /// there, so the record has to survive for the reconnect.
    /// Kills mutation: clearing the record (or trying to write) on disconnect,
    /// either of which loses the only fact that can repair the monitor.
    func testDisconnectMidTrialKeepsTheRecoveryRecordForLater() {
        var session = openTrial()
        let effects = session.apply(.displayDisconnected, now: epoch)

        XCTAssertEqual(effects, [], "no `.clearPending`, and above all no write to a missing display")
        XCTAssertEqual(session.phase, .interrupted)
    }

    /// Between trials the monitor is on something the user can see, so a
    /// disconnect is simply the end of the session.
    /// Kills mutation: leaving a stale record behind after a session that never
    /// had a trial open, which would make the next reconnect switch inputs for
    /// no reason.
    func testDisconnectBetweenTrialsJustEndsTheSession() {
        var session = makeSession()
        let effects = session.apply(.displayDisconnected, now: epoch)

        XCTAssertEqual(effects, [])
        XCTAssertEqual(session.phase, .finished)
    }

    // MARK: - Guards against events that arrive at the wrong moment

    /// Closing the wizard is not permission to leave an untested code on the
    /// panel.
    /// Kills mutation: finishing straight to `.finished` from `.confirming`,
    /// which cancels the countdown and strands the user by way of the one button
    /// they are most likely to press in a panic.
    func testFinishingMidTrialRevertsInsteadOfAbandoningTheCode() {
        var session = openTrial()
        let effects = session.apply(.finish, now: epoch)

        XCTAssertEqual(effects, [.cancelDeadline, .writeInput(original)])
        XCTAssertEqual(session.phase, .reverting(candidate: candidate, reason: .userCancelled, attempt: 1))
    }

    /// A finish while a write is in flight has to wait for it: the completion is
    /// what drives the revert.
    /// Kills mutation: ending the session from `.switching`, which drops the
    /// pending write's result on the floor and with it the revert it triggers.
    func testFinishingWhileAWriteIsInFlightIsDeferred() {
        var session = makeSession()
        session.apply(.test(candidate), now: epoch)
        let effects = session.apply(.finish, now: epoch)

        XCTAssertEqual(effects, [])
        XCTAssertEqual(session.phase, .switching(candidate: candidate))
    }

    /// Kills mutation: allowing `.test` from any phase, which stacks a second
    /// switch on top of an open trial — the second write would overwrite the
    /// first candidate with the countdown still counting for the wrong code.
    func testASecondTestWhileATrialIsOpenIsIgnored() {
        var session = openTrial()
        let effects = session.apply(.test(0x30), now: epoch)

        XCTAssertEqual(effects, [])
        XCTAssertEqual(session.candidateUnderTest, candidate)
    }

    /// Kills mutation: handling `.tick` outside `.confirming`. A tick during
    /// naming would revert a monitor the user is actively looking at, throwing
    /// away the picture *and* the mapping mid-keystroke.
    func testTicksOutsideAnOpenCountdownDoNothing() {
        var naming = openTrial()
        naming.apply(.keep, now: epoch)
        XCTAssertEqual(naming.apply(.tick(epoch.addingTimeInterval(9999)), now: epoch), [])
        XCTAssertEqual(naming.phase, .naming(candidate: candidate))

        var choosing = makeSession()
        XCTAssertEqual(choosing.apply(.tick(epoch.addingTimeInterval(9999)), now: epoch), [])
        XCTAssertEqual(choosing.phase, .choosing)
    }

    // MARK: - The contribution artifact

    /// The generated entry has to survive the app's own loader, and the confirmed
    /// codes have to come out the other side as `verified` — which the decoder
    /// only permits when the value says so itself.
    /// Kills mutation: emitting the confidence at the feature level instead of on
    /// each value. `MonitorQuirks` caps what `input` inherits at `reported`, so
    /// that entry would load as unconfirmed and the user's measurement would
    /// silently evaporate.
    func testTheReportEmitsVerifiedValuesTheRealDecoderAccepts() throws {
        let subject = InputCalibrationReport.Subject(
            vendor: 0x09D1, product: 0x8075, displayName: "BenQ MA320U",
            confirmed: [
                CalibratedInput(code: 19, label: "USB-C", confirmedAt: epoch),
                CalibratedInput(code: 0x21, label: "HDMI 2", confirmedAt: epoch)
            ],
            reverted: [0x30],
            osVersion: "26.4.1", macModel: "Mac16,8", appVersion: "1.4.1"
        )
        let json = try InputCalibrationReport.json(for: subject)

        let file = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file)
        XCTAssertEqual(file.problems, [], "the loader must not have to drop anything")
        let model = try XCTUnwrap(file.models.first)
        let input = try XCTUnwrap(model.feature(.input))

        XCTAssertEqual(input.values.map(\.code), [19, 0x21])
        XCTAssertEqual(input.values.map(\.label), ["USB-C", "HDMI 2"])
        XCTAssertTrue(input.values.allSatisfy { $0.confidence == .verified })
        XCTAssertFalse(input.complete, "this desk's cables are not the model's port list")
        XCTAssertEqual(model.confidence, .reported, "only the input codes were measured")
    }

    /// The two generators have deliberately opposite guarantees, and both are
    /// load-bearing: a read pass cannot establish what a code is wired to, and a
    /// human watching the panel can.
    /// Kills mutation: routing calibration results through `QuirkEntryGenerator`
    /// (which would silently downgrade them to `reported`), or relaxing that
    /// generator so a probe can emit `verified`.
    func testTheProbeGeneratorAndTheCalibrationGeneratorEmitOppositeConfidences() {
        XCTAssertEqual(QuirkEntryGenerator.emittedConfidence, .reported)
        XCTAssertEqual(InputCalibrationReport.emittedConfidence, .verified)
    }

    /// Kills mutation: emitting an entry with an empty `values` array, which
    /// claims a measurement that did not happen and invites a maintainer to merge
    /// it.
    func testTheReportRefusesToGenerateWithoutAConfirmedCode() {
        let subject = InputCalibrationReport.Subject(
            vendor: 0x09D1, product: 0x8075, confirmed: [],
            osVersion: "26.4.1", macModel: "Mac16,8", appVersion: "1.4.1"
        )
        XCTAssertThrowsError(try InputCalibrationReport.json(for: subject))
    }

    /// A reverted code is evidence about this desk's cabling, not about the
    /// model: the port may simply have had nothing plugged into it.
    /// Kills mutation: folding reverted codes into the entry, which would publish
    /// "code 48 does not work on the MA320U" on the strength of an empty socket.
    func testRevertedCodesAreReportedAsContextButNeverAsData() throws {
        let subject = InputCalibrationReport.Subject(
            vendor: 0x09D1, product: 0x8075, displayName: "BenQ MA320U",
            confirmed: [CalibratedInput(code: 19, label: "USB-C", confirmedAt: epoch)],
            reverted: [0x30],
            osVersion: "26.4.1", macModel: "Mac16,8", appVersion: "1.4.1"
        )
        let json = try InputCalibrationReport.json(for: subject)
        // The positive control matters as much as the negative one: without it,
        // a change to the encoder's spacing would turn the assertion below into a
        // test that passes because it can no longer find anything at all.
        let confirmedCode = try XCTUnwrap(
            ["\"code\" : 19", "\"code\": 19"].first { json.contains($0) },
            "the confirmed code has to be in the entry"
        )
        XCTAssertFalse(
            json.contains(confirmedCode.replacingOccurrences(of: "19", with: "48")),
            "a reverted code must not become an entry"
        )

        let body = InputCalibrationReport.issueBody(for: subject, json: json)
        XCTAssertTrue(body.contains("48"), "but a reviewer should still know it was tried")
        XCTAssertTrue(body.contains("benq.json"), "the file name comes from the shared generator")
    }

    /// Regenerating the same session must produce byte-identical JSON: Swift
    /// seeds its string hashing per process, so an unsorted encoder emits the
    /// same entry with the keys shuffled.
    /// Kills mutation: dropping `.sortedKeys`, which gives a contributor who
    /// regenerates before pushing a diff full of nothing.
    func testTheReportIsByteStableAcrossRuns() throws {
        let subject = InputCalibrationReport.Subject(
            vendor: 0x09D1, product: 0x8075, displayName: "BenQ MA320U",
            confirmed: [CalibratedInput(code: 19, label: "USB-C", confirmedAt: epoch)],
            osVersion: "26.4.1", macModel: "Mac16,8", appVersion: "1.4.1"
        )
        XCTAssertEqual(
            try InputCalibrationReport.json(for: subject),
            try InputCalibrationReport.json(for: subject)
        )
    }

    // MARK: - Persisted shape

    /// The record and the confirmed mappings ride `DisplayStateDocument`, so they
    /// key on `DisplayUUID` (AGENTS.md §3.3) and survive a round trip.
    /// Kills mutation: making either field non-optional, which stops every
    /// document written by an older build from decoding at all — including, at
    /// the worst possible moment, the one holding an interrupted calibration.
    func testCalibrationStateRoundTripsAndOlderDocumentsStillDecode() throws {
        var state = DisplayState()
        state.calibratedInputs = [CalibratedInput(code: 19, label: "USB-C", confirmedAt: epoch)]
        state.pendingInputCalibration = PendingInputCalibration(
            originalCode: 19, candidateCode: 0x21, startedAt: epoch
        )
        let document = DisplayStateDocument(displays: [uuid: state])

        let data = try JSONEncoder().encode(document)
        let decoded = DisplayStateDocument.decoding(data).document
        XCTAssertEqual(decoded.displays[uuid], state)

        let older = DisplayStateDocument.decoding(Data(#"{"version":2,"displays":{"X":{"contrast":40}}}"#.utf8))
        XCTAssertNil(older.failure)
        XCTAssertNil(older.document.displays[DisplayUUID("X")]?.pendingInputCalibration)
        XCTAssertNil(older.document.displays[DisplayUUID("X")]?.calibratedInputs)
    }

    /// Kills mutation: leaving the new fields out of `isEmpty`'s notion of empty
    /// (by giving them a non-`nil` default), which would make the store keep an
    /// entry for every display it has ever seen.
    func testAStateHoldingOnlyCalibrationDataIsNotEmpty() {
        var state = DisplayState()
        XCTAssertTrue(state.isEmpty)
        state.pendingInputCalibration = PendingInputCalibration(
            originalCode: 19, candidateCode: 0x21, startedAt: epoch
        )
        XCTAssertFalse(state.isEmpty)
    }

    // MARK: - Helpers

    private func makeSession(window: TimeInterval = 15) -> InputCalibrationSession {
        InputCalibrationSession(
            displayUUID: uuid,
            originalCode: original,
            candidates: [original, candidate, 0x30],
            confirmWindow: window
        )
    }

    /// A session with `candidate` written, acknowledged and counting down.
    private func openTrial() -> InputCalibrationSession {
        var session = makeSession()
        session.apply(.test(candidate), now: epoch)
        session.apply(.writeCompleted(acknowledged: true), now: epoch)
        return session
    }

    private func quirksWithInput(code: UInt16, confidence: String) -> MonitorQuirks? {
        decodeQuirks("""
        {
          "vendor": "0x09D1",
          "vendorName": "BenQ",
          "models": [{
            "product": "0x8075",
            "name": "MA320U",
            "features": {
              "input": {
                "values": [{ "code": \(code), "label": "USB-C", "confidence": "\(confidence)" }]
              }
            }
          }]
        }
        """)
    }

    private func quirksWithCompleteInputList(code: UInt16) -> MonitorQuirks? {
        decodeQuirks("""
        {
          "vendor": "0x09D1",
          "vendorName": "BenQ",
          "models": [{
            "product": "0x8075",
            "name": "MA320U",
            "features": {
              "input": {
                "complete": true,
                "values": [{ "code": \(code), "label": "DisplayPort", "confidence": "verified" }]
              }
            }
          }]
        }
        """)
    }

    private func decodeQuirks(_ json: String) -> MonitorQuirks? {
        MonitorQuirksFile.decoding(Data(json.utf8)).file?.models.first
    }
}
