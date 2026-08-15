import XCTest

/// Headless tests for the brightness-sync arithmetic — the whole of what a
/// display group does to a value.
///
/// `DisplayGroup` is compiled directly into this target (see `project.yml`), so
/// none of this needs an app, a monitor, or two of them. That is the point:
/// "relative sync does not oscillate" and "a member pinned at 0 does not drag the
/// group" are the two properties a sync feature is usually wrong about, and both
/// are only checkable here.
///
/// Each test names the mutation it is designed to kill in a trailing comment.
final class BrightnessSyncTests: XCTestCase {

    private let displayA = DisplayUUID("AAAA-0001")
    private let displayB = DisplayUUID("BBBB-0002")
    private let displayC = DisplayUUID("CCCC-0003")

    private var everything: Set<DisplayUUID> { [displayA, displayB, displayC] }

    private func group(
        _ mode: BrightnessSyncMode,
        members: [DisplayUUID],
        baselines: [DisplayUUID: Double] = [:]
    ) -> DisplayGroup {
        DisplayGroup(id: "g", name: "Desk", members: members, syncMode: mode, baselines: baselines)
    }

    private func targets(
        _ group: DisplayGroup,
        moved: DisplayUUID,
        to value: Double,
        origin: BrightnessChangeOrigin = .user,
        current: [DisplayUUID: Double],
        attached: Set<DisplayUUID>? = nil
    ) -> [BrightnessSync.Target] {
        BrightnessSync.targets(
            in: group, movedDisplay: moved, to: value, origin: origin,
            current: current, attached: attached ?? everything
        )
    }

    // MARK: - Absolute versus relative

    /// The distinction the whole feature is about, on one input. Absolute sends
    /// every member to the same number; relative preserves the 30-point gap the
    /// user set up. Same group, same move, different answers.
    /// Kills mutation: collapsing the two modes into one, or reading the mode
    /// from anywhere but the group.
    func testAbsoluteAndRelativeDifferOnTheSameMove() {
        let baselines: [DisplayUUID: Double] = [displayA: 50, displayB: 20]
        let current: [DisplayUUID: Double] = [displayA: 50, displayB: 20]

        let absolute = targets(
            group(.absolute, members: [displayA, displayB], baselines: baselines),
            moved: displayA, to: 70, current: current
        )
        let relative = targets(
            group(.relative, members: [displayA, displayB], baselines: baselines),
            moved: displayA, to: 70, current: current
        )

        XCTAssertEqual(absolute.map(\.value), [70])
        XCTAssertEqual(relative.map(\.value), [40], "70 - (50 - 20)")
    }

    /// Relative sync uses the *baselines*, not the members' live values. Those
    /// diverge the moment anything else touches a monitor — the OSD, another app,
    /// a reconnect — and a rule that read the live gap would let the group's
    /// offsets drift a little further on every single move.
    /// Kills mutation: computing the offset from `current` instead of
    /// `baselines`, which passes every test where the two happen to agree.
    func testRelativeUsesTheCapturedOffsetNotTheLiveGap() {
        let group = group(.relative, members: [displayA, displayB], baselines: [displayA: 50, displayB: 20])
        // The monitor's own buttons moved B to 90 since the offsets were taken.
        let current: [DisplayUUID: Double] = [displayA: 50, displayB: 90]

        let result = targets(group, moved: displayA, to: 60, current: current)

        XCTAssertEqual(result.map(\.value), [30], "60 - 30, the captured offset, not 60 + 40")
    }

    // MARK: - Oscillation

    /// The rule that makes a propagation one level deep: a change that is itself
    /// a sync plans nothing. Without it, A moves, B follows, B's change is
    /// observed, A follows B — and the group hunts until the clamp stops it.
    /// Kills mutation: dropping the origin guard, or checking it after the
    /// targets have already been computed.
    func testASyncedChangeIsNeverPropagatedAgain() {
        let group = group(.relative, members: [displayA, displayB], baselines: [displayA: 50, displayB: 20])
        let current: [DisplayUUID: Double] = [displayA: 50, displayB: 20]

        let first = targets(group, moved: displayA, to: 70, origin: .user, current: current)
        XCTAssertEqual(first.count, 1)
        let follower = try? XCTUnwrap(first.first)
        XCTAssertEqual(follower?.origin, .groupSync(groupID: "g"), "a follower's write is tagged as a sync")

        // Feed the follower's own change straight back in, which is exactly what
        // an observer that could not tell the two apart would do.
        let second = targets(
            group, moved: displayB, to: 40,
            origin: .groupSync(groupID: "g"),
            current: [displayA: 70, displayB: 40]
        )

        XCTAssertTrue(second.isEmpty, "the group must not follow its own follower")
    }

    /// A second propagation with the same input is a no-op: every member is
    /// already where it belongs, so nothing is written. This is what makes a
    /// duplicate notification, a retry or a coalesced slider tick free rather
    /// than another round of I²C traffic.
    /// Kills mutation: removing the deadband, or comparing against the baseline
    /// instead of the live value.
    func testPropagationIsIdempotent() {
        let group = group(.relative, members: [displayA, displayB, displayC],
                          baselines: [displayA: 50, displayB: 20, displayC: 80])
        var current: [DisplayUUID: Double] = [displayA: 50, displayB: 20, displayC: 80]

        let first = targets(group, moved: displayA, to: 60, current: current)
        XCTAssertEqual(first.map(\.value), [30, 90])
        for target in first { current[target.display] = target.value }
        current[displayA] = 60

        XCTAssertTrue(targets(group, moved: displayA, to: 60, current: current).isEmpty)
    }

    /// A change smaller than the deadband is not worth a DDC write. Sized below
    /// one step of any control the app offers, so it can only ever swallow a
    /// rounding difference — never a movement a user made.
    /// Kills mutation: widening the deadband past 1% (a brightness key press
    /// would stop propagating), or dropping it (every re-read would write).
    func testTheDeadbandSwallowsOnlySubStepDifferences() {
        let group = group(.absolute, members: [displayA, displayB])

        let tiny = targets(group, moved: displayA, to: 50.4, current: [displayA: 50, displayB: 50])
        XCTAssertTrue(tiny.isEmpty)

        let oneStep = targets(group, moved: displayA, to: 51, current: [displayA: 50, displayB: 50])
        XCTAssertEqual(oneStep.map(\.value), [51], "a one-percent step still propagates")
    }

    // MARK: - Clamping

    /// A member the clamp has pinned at an end must not drag the group towards
    /// it. Every target is computed from the mover and the baselines, so B's
    /// pinned 0 is never an input: A keeps moving down and B simply stays at 0,
    /// and when A comes back up B rejoins at its own offset.
    /// Kills mutation: feeding a follower's clamped value back into the
    /// arithmetic (as a "re-baseline on clamp" would), which makes B's 0 pull
    /// every other member down with it.
    func testAMemberPinnedAtAnEndDoesNotDragTheGroup() {
        let group = group(.relative, members: [displayA, displayB, displayC],
                          baselines: [displayA: 50, displayB: 5, displayC: 60])
        var current: [DisplayUUID: Double] = [displayA: 50, displayB: 5, displayC: 60]

        // A down to 10: B wants -35 and pins at 0, C wants 20.
        let down = targets(group, moved: displayA, to: 10, current: current)
        XCTAssertEqual(down.map(\.value), [0, 20])
        for target in down { current[target.display] = target.value }
        current[displayA] = 10

        // A down again: B is already pinned, C follows. B's 0 has not moved C.
        let further = targets(group, moved: displayA, to: 5, current: current)
        XCTAssertEqual(further.map(\.value), [15], "only C moves; B is at 0 and stays there")

        // And back up: B rejoins at its own offset rather than at whatever the
        // clamp left it on.
        current[displayC] = 15
        current[displayA] = 5
        let up = targets(group, moved: displayA, to: 50, current: current)
        XCTAssertEqual(up.map(\.value), [5, 60], "B returns to its captured offset, not to 0 + delta")
    }

    /// The same at the top of the range, and with the mover itself out of range:
    /// a value above 100 is clamped before anything is derived from it, so the
    /// followers land where 100 would put them rather than where 130 would.
    /// Kills mutation: clamping the followers but not the mover.
    func testTheMoverIsClampedBeforeTheOffsetsAreApplied() {
        let group = group(.relative, members: [displayA, displayB], baselines: [displayA: 50, displayB: 80])

        let result = targets(group, moved: displayA, to: 130, current: [displayA: 50, displayB: 80])

        XCTAssertEqual(result.map(\.value), [100], "100 + 30, clamped, not 130 + 30")
    }

    /// A value that is not a number is not a move. Refused before the clamp,
    /// because `min(100, .nan)` is 100 in Swift — a NaN reaching the clamp would
    /// arrive as full brightness on every other monitor in the group.
    /// Kills mutation: clamping first and checking `isFinite` afterwards, or not
    /// checking at all.
    func testANonFiniteValuePropagatesNothing() {
        let group = group(.absolute, members: [displayA, displayB])

        XCTAssertTrue(targets(group, moved: displayA, to: .nan, current: [displayA: 50, displayB: 50]).isEmpty)
        XCTAssertTrue(targets(group, moved: displayA, to: .infinity, current: [displayA: 50, displayB: 50]).isEmpty)
    }

    // MARK: - Membership and attachment

    /// A member that is not attached is skipped, and the rest of the group still
    /// moves. A group outlives the desk it was made on — refusing the whole
    /// propagation because one monitor is unplugged would make groups useless on
    /// a laptop.
    /// Kills mutation: dropping the `attached` filter (a write would be aimed at
    /// a display that is not there), or bailing out of the whole propagation.
    func testAnUnattachedMemberIsSkippedAndTheRestStillMove() {
        let group = group(.absolute, members: [displayA, displayB, displayC])

        let result = targets(
            group, moved: displayA, to: 30,
            current: [displayA: 50, displayB: 50, displayC: 50],
            attached: [displayA, displayC]
        )

        XCTAssertEqual(result.map(\.display), [displayC])
    }

    /// A display that is not in the group moves nothing, and a group with fewer
    /// than two members has nothing to sync. Both would otherwise be silent
    /// writes to monitors the user never grouped.
    /// Kills mutation: dropping the membership check, or treating a one-member
    /// group as actionable (harmless today, but it is the shape that lets a
    /// future "sync to everything" bug in).
    func testANonMemberAndAOneMemberGroupPropagateNothing() {
        let full = group(.absolute, members: [displayA, displayB])
        XCTAssertTrue(targets(full, moved: displayC, to: 30, current: [:]).isEmpty)

        let lonely = group(.absolute, members: [displayA])
        XCTAssertTrue(targets(lonely, moved: displayA, to: 30, current: [:]).isEmpty)
    }

    /// The mover is never in its own result. It already holds the value the user
    /// set; writing it again would fight an in-flight drag and could bounce the
    /// slider under the pointer.
    /// Kills mutation: removing the `$0 != movedDisplay` filter.
    func testTheMoverIsNeverATarget() {
        let group = group(.absolute, members: [displayA, displayB])

        let result = targets(group, moved: displayA, to: 30, current: [displayA: 50, displayB: 50])

        XCTAssertFalse(result.contains { $0.display == displayA })
    }

    /// A member with no baseline and no live reading is still written — an
    /// unknown value is not a reason to leave one screen behind — and it lands on
    /// the mover's own value, which is the only defensible guess.
    /// Kills mutation: skipping members missing from `current` (a display whose
    /// brightness has not been read yet would never join its group).
    func testAMemberWithNoBaselineAndNoReadingStillFollows() {
        let group = group(.relative, members: [displayA, displayB], baselines: [displayA: 50])

        let result = targets(group, moved: displayA, to: 30, current: [displayA: 50])

        XCTAssertEqual(result.map(\.value), [30])
    }

    /// Order is by identifier, so a propagation reads the same way twice — in a
    /// test, and in the log line that says what a group just did.
    /// Kills mutation: returning the dictionary's iteration order, which Swift
    /// deliberately varies between runs.
    func testTargetsAreOrderedByIdentifier() {
        let group = group(.absolute, members: [displayC, displayB, displayA])

        let result = targets(group, moved: displayC, to: 30, current: [:])

        XCTAssertEqual(result.map(\.display), [displayA, displayB])
    }

    // MARK: - Capturing

    /// Arming relative sync records what the members are on now, clamped, and
    /// records nothing for a display it cannot read — which `targets` then treats
    /// as "capture at the first move" rather than as an offset of zero.
    /// Kills mutation: capturing a value for every member regardless (an
    /// unreadable display would be baselined at 0 and jump on the next move), or
    /// skipping the clamp.
    func testBaselineCaptureTakesTheLiveValuesAndSkipsWhatItCannotRead() {
        let captured = BrightnessSync.baselines(
            for: [displayA, displayB, displayC],
            current: [displayA: 50, displayB: 140, displayC: .nan]
        )

        XCTAssertEqual(captured, [displayA: 50, displayB: 100])
    }
}
