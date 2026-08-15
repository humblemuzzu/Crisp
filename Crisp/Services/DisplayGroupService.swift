import Foundation
import CoreGraphics
import os.log

/// Display groups: the stored list, the CRUD the panel drives, and the one
/// observer that makes a group's brightness move together.
///
/// **Every decision this service makes about values lives in `BrightnessSync`**,
/// which is pure and headless (AGENTS.md §3.6). What is left here is the impure
/// half and nothing else: which displays are attached, what each is on right now,
/// and issuing the write. That split is why "relative sync does not oscillate"
/// and "a member pinned at 0 does not drag the group" are unit tests instead of
/// something to watch for on a two-monitor desk.
///
/// **How a propagation cannot start another one.** Three independent things, in
/// the order they act:
///
///   1. `BrightnessSync.targets` plans nothing for a change whose origin is
///      already `.groupSync`. This is the rule, and it is pure.
///   2. Follower writes go out as `isAutoAdjust: true`, which is the existing
///      flag `BrightnessService` uses to mean "not the user's own gesture" — so
///      they never post `.crispExternalManualAdjust`, the notification this
///      service listens to. There is therefore no second event to ignore.
///   3. `isPropagating` refuses re-entry anyway, because a future caller could
///      route a follower write through some other path and the first two guards
///      should not be the only thing standing between that and a hunt.
///
/// No private frameworks: `BrightnessService`'s public API, `DisplayStateStore`,
/// Foundation, os.log.
@MainActor
final class DisplayGroupService: ObservableObject {
    static let shared = DisplayGroupService()

    private static let log = Logger(subsystem: "com.crisp.app", category: "DisplayGroupService")

    /// The stored groups, republished for SwiftUI. The store is the source of
    /// truth; this is a cache that is written through on every mutation.
    @Published private(set) var groups: [DisplayGroup] = []

    private var store: DisplayStateStore { .shared }
    private var isPropagating = false
    private var adjustObserver: NSObjectProtocol?

    private init() {
        groups = store.groups
        // The same notification `AutoBrightnessService` and `DDCFeatureService`
        // already use to mean "the user moved this display's brightness". It is
        // posted only for `isAutoAdjust == false`, which is exactly the
        // `.user` origin the sync rule requires.
        //
        // `queue: nil` — synchronous, on the posting thread — for the reason
        // `AutoBrightnessService` gives for the same notification: the values
        // this reads are about to change. `BrightnessService` posts *before* it
        // assigns `display.brightness`, so a synchronous observer sees the group
        // as it was when the user moved it, which is what the offsets are
        // relative to. An `OperationQueue.main` hop would sample it afterwards.
        adjustObserver = NotificationCenter.default.addObserver(
            forName: .crispExternalManualAdjust, object: nil, queue: nil
        ) { [weak self] note in
            guard let displayID = note.userInfo?["displayID"] as? CGDirectDisplayID,
                  let value = note.userInfo?["value"] as? Double else { return }
            MainActor.assumeIsolated {
                self?.propagate(from: displayID, value: value)
            }
        }
    }

    // MARK: - CRUD

    /// Creates a group and captures its baselines from what the members are on
    /// right now, which is what "offsets are captured when sync is enabled"
    /// means in practice.
    @discardableResult
    func createGroup(name: String, members: [DisplayUUID], syncMode: BrightnessSyncMode = .relative) -> DisplayGroup {
        let group = DisplayGroup(
            name: name, members: members, syncMode: syncMode,
            baselines: BrightnessSync.baselines(for: members, current: currentBrightness())
        ).normalized()
        write(groups + [group])
        return group
    }

    func rename(_ id: String, to name: String) {
        write(groups.map { $0.id == id ? withName(name, on: $0) : $0 })
    }

    func delete(_ id: String) {
        write(groups.filter { $0.id != id })
    }

    /// Adds or removes one member, re-capturing the baselines either way: the
    /// offsets a group holds describe a particular set of screens, so a set that
    /// has changed no longer has offsets to preserve.
    func setMembership(_ id: String, display: DisplayUUID, isMember: Bool) {
        write(groups.map { group in
            guard group.id == id else { return group }
            var copy = group
            copy.members = isMember
                ? group.members.filter { $0 != display } + [display]
                : group.members.filter { $0 != display }
            copy.baselines = BrightnessSync.baselines(for: copy.members, current: currentBrightness())
            return copy.normalized()
        })
    }

    /// Switches sync mode. Moving *to* relative re-arms the offsets from the
    /// live values — the user has just said "keep them as they are now".
    func setSyncMode(_ id: String, to mode: BrightnessSyncMode) {
        write(groups.map { group in
            guard group.id == id else { return group }
            var copy = group
            copy.syncMode = mode
            if mode == .relative {
                copy.baselines = BrightnessSync.baselines(for: copy.members, current: currentBrightness())
            }
            return copy
        })
    }

    /// Re-captures the offsets without changing anything else, for after the
    /// user has dialled the screens in by hand again.
    func recaptureBaselines(_ id: String) {
        write(groups.map { group in
            guard group.id == id else { return group }
            var copy = group
            copy.baselines = BrightnessSync.baselines(for: copy.members, current: currentBrightness())
            return copy
        })
    }

    // MARK: - Propagation

    /// One display moved; bring its groups along.
    ///
    /// A display in two groups propagates through both, in stored order. That is
    /// not a merge — the last group to write a shared member wins — and it is
    /// deliberate: merging two users' intentions is a guess, while "the groups
    /// run in the order you made them" is at least explicable.
    private func propagate(from displayID: CGDirectDisplayID, value: Double) {
        guard !isPropagating, !groups.isEmpty else { return }
        let displays = DisplayManagerAccessor.shared.displays
        guard let moved = displays.first(where: { $0.displayID == displayID }) else { return }

        let movedUUID = moved.stateUUID
        let current = currentBrightness()
        let attached = Set(displays.map(\.stateUUID))

        isPropagating = true
        defer { isPropagating = false }

        for group in groups {
            let targets = BrightnessSync.targets(
                in: group, movedDisplay: movedUUID, to: value,
                // The origin token. A follower's own write never reaches here
                // (it goes out as `isAutoAdjust: true` and posts nothing), so
                // anything that does get here is the user's own gesture.
                origin: .user,
                current: current, attached: attached
            )
            for target in targets {
                guard let follower = displays.first(where: { $0.stateUUID == target.display }) else { continue }
                apply(target, to: follower)
            }
        }
    }

    private func apply(_ target: BrightnessSync.Target, to display: DisplayInfo) {
        Self.log.debug(
            "group sync: \(display.name, privacy: .public) -> \(Int(target.value), privacy: .public)%"
        )
        Task { @MainActor in
            // `isAutoAdjust: true` is what stops this write from being reported
            // as a manual change and starting another round — see the class doc.
            await BrightnessService.shared.setBrightness(target.value, for: display, isAutoAdjust: true)
        }
        // The manual-adjust path persists brightness for reconnect reapply; a
        // synced write has to do it itself, or the follower would come back on
        // its pre-sync level after an unplug.
        DDCFeatureService.shared.persistBrightness(target.value, for: display)
    }

    // MARK: - Plumbing

    /// What every attached display is on right now, as the pure rule wants it.
    private func currentBrightness() -> [DisplayUUID: Double] {
        var values: [DisplayUUID: Double] = [:]
        for display in DisplayManagerAccessor.shared.displays {
            values[display.stateUUID] = min(display.brightness, BrightnessSync.range.upperBound)
        }
        return values
    }

    private func withName(_ name: String, on group: DisplayGroup) -> DisplayGroup {
        var copy = group
        copy.name = name
        return copy
    }

    private func write(_ groups: [DisplayGroup]) {
        let normalized = groups.map { $0.normalized() }
        store.setGroups(normalized)
        // Read back rather than trusting the local copy: the store repairs
        // duplicate identifiers, and the panel must show what was actually kept.
        self.groups = store.groups
    }
}
