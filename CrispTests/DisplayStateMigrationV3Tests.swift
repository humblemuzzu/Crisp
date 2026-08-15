import XCTest

/// Headless tests for the v2 → v3 upgrade of `displays.json`, and for the two
/// forward-compatibility mechanisms it shipped with: the unknown-field bag that
/// makes a rollback lossless, and the element-wise list decode that stops one bad
/// entry from costing the user their monitor settings.
///
/// `DisplayStateDocument`, `JSONValue`, `DisplayGroup`, `DDCPreset` and
/// `PresetSchedule` are compiled directly into this target (see `project.yml`),
/// so nothing here imports the app. Each test names the mutation it is designed
/// to kill in a trailing comment.
final class DisplayStateMigrationV3Tests: XCTestCase {

    private let uuidA = DisplayUUID("37D8832A-2D66-02CA-B9F7-8F30A301B230")
    private let uuidB = DisplayUUID("v1552-m30740-s16843009")

    private func v2Document() -> String {
        """
        {
          "version": 2,
          "displays": {
            "\(uuidA.rawValue)": { "brightness": 12, "contrast": 50, "input": 19, "reapplyInputOnReconnect": true }
          }
        }
        """
    }

    // MARK: - The upgrade itself

    /// A real v2 document upgrades to v3 with every value intact and three empty
    /// collections — nothing is converted because nothing in v2 could be, so
    /// "loses nothing" is the entire correctness claim.
    /// Kills mutation: rebuilding the document instead of copying it (the display
    /// state would vanish), or leaving `version` at 2 so the file lies about its
    /// own shape forever.
    func testUpgradeFromV2KeepsEveryValueAndStampsV3() {
        let (decoded, failure) = DisplayStateDocument.decoding(Data(v2Document().utf8))
        XCTAssertNil(failure)

        let upgraded = DisplayStateMigration.upgraded(decoded)

        XCTAssertEqual(upgraded.version, DisplayStateDocument.currentVersion)
        XCTAssertEqual(upgraded.displays[uuidA]?.brightness, 12)
        XCTAssertEqual(upgraded.displays[uuidA]?.contrast, 50)
        XCTAssertEqual(upgraded.displays[uuidA]?.input, 19)
        XCTAssertEqual(upgraded.displays[uuidA]?.reapplyInputOnReconnect, true)
        XCTAssertTrue(upgraded.groups.isEmpty)
        XCTAssertTrue(upgraded.presets.isEmpty)
        XCTAssertTrue(upgraded.schedules.isEmpty)
    }

    /// Running the upgrade twice is the same as running it once. The store runs
    /// it on every load, so a non-idempotent one would rewrite the file at every
    /// launch — and any repair it makes would be re-applied to its own output.
    /// Kills mutation: appending rather than replacing a collection, or making
    /// the repair order-dependent so a second pass reshuffles it.
    func testUpgradeIsIdempotent() {
        let document = DisplayStateDocument(
            version: 2,
            displays: [uuidA: DisplayState(brightness: 40)],
            groups: [DisplayGroup(id: "g", name: "Desk", members: [uuidA, uuidB])],
            presets: [DDCPreset(id: "p", name: "Night", settings: [uuidA: DDCPresetSettings(brightness: 20)])],
            schedules: [PresetSchedule(
                id: "s", presetID: "p",
                trigger: ScheduleTrigger(at: TimeOfDay(hour: 22, minute: 0)!),
                armedAt: Date(timeIntervalSince1970: 0)
            )]
        )

        let once = DisplayStateMigration.upgraded(document)
        let twice = DisplayStateMigration.upgraded(once)

        XCTAssertEqual(twice, once)
        XCTAssertEqual(once.version, DisplayStateDocument.currentVersion)
        XCTAssertEqual(once.groups.count, 1)
        XCTAssertEqual(once.presets.count, 1)
        XCTAssertEqual(once.schedules.count, 1)
    }

    /// A document a *newer* build stamped keeps its own version. Lowering it
    /// would make a v4 file claim to be v3 while still carrying v4 fields in the
    /// unknown bag, and the next build up would then read it on the wrong terms.
    /// Kills mutation: `result.version = currentVersion` instead of `max(...)`.
    func testUpgradeNeverLowersTheVersionOfANewerDocument() {
        let fromTheFuture = DisplayStateDocument(version: 9, displays: [uuidA: DisplayState(volume: 30)])

        XCTAssertEqual(DisplayStateMigration.upgraded(fromTheFuture).version, 9)
    }

    /// The v1 → v2 fold and the v2 → v3 upgrade compose: a user coming from the
    /// `UserDefaults` era lands on a v3 document with their values in it.
    /// Kills mutation: pinning either migration's output version to its own
    /// number, which would leave one of the two permanently re-running.
    func testV1FoldAndV3UpgradeCompose() {
        let legacy: [String: LegacyDefaultsValue] = [
            "crisp.ddcState.\(uuidA.rawValue).brightness": .number(72),
            "crisp.volumeCapableDisplays": .list([uuidA.rawValue])
        ]

        let folded = DisplayStateMigration.migrated(legacy: legacy, into: DisplayStateDocument(version: 1))
        let upgraded = DisplayStateMigration.upgraded(folded)

        XCTAssertEqual(upgraded.version, DisplayStateDocument.currentVersion)
        XCTAssertEqual(upgraded.displays[uuidA]?.brightness, 72)
        XCTAssertEqual(upgraded.displays[uuidA]?.volumeCapable, true)
    }

    // MARK: - The invariants the upgrade repairs

    /// Two entities sharing an identifier make every lookup ambiguous — and the
    /// lookups are what a `crisp://preset/<id>` link and a schedule's `presetID`
    /// are made of. First wins, deterministically, so the repair does not pick a
    /// different survivor on each launch.
    /// Kills mutation: dropping the de-duplication, or keeping the *last*
    /// occurrence (a re-imported file would silently repoint every link).
    func testUpgradeDeduplicatesIdentifiersKeepingTheFirst() {
        let document = DisplayStateDocument(
            groups: [DisplayGroup(id: "g", name: "First"), DisplayGroup(id: "g", name: "Second")],
            presets: [DDCPreset(id: "p", name: "First"), DDCPreset(id: "p", name: "Second")],
            schedules: [
                PresetSchedule(id: "s", presetID: "p", trigger: .init(at: TimeOfDay(hour: 1, minute: 0)!),
                               armedAt: .distantPast),
                PresetSchedule(id: "s", presetID: "q", trigger: .init(at: TimeOfDay(hour: 2, minute: 0)!),
                               armedAt: .distantPast)
            ]
        )

        let upgraded = DisplayStateMigration.upgraded(document)

        XCTAssertEqual(upgraded.groups.map(\.name), ["First"])
        XCTAssertEqual(upgraded.presets.map(\.name), ["First"])
        XCTAssertEqual(upgraded.schedules.map(\.presetID), ["p"])
    }

    /// A group listing one display twice would write that monitor twice per
    /// propagation and leave its offset undefined; a baseline for a display that
    /// is no longer a member is dead weight that survives every edit.
    /// Kills mutation: dropping `DisplayGroup.normalized()` from the upgrade, or
    /// implementing it with a `Set` (which would also lose the user's order).
    func testUpgradeNormalizesGroupMembership() {
        let document = DisplayStateDocument(groups: [DisplayGroup(
            id: "g", name: "Desk",
            members: [uuidB, uuidA, uuidB],
            baselines: [uuidA: 50, uuidB: 40, DisplayUUID("gone"): 10]
        )])

        let group = DisplayStateMigration.upgraded(document).groups[0]

        XCTAssertEqual(group.members, [uuidB, uuidA], "duplicates dropped, the user's order kept")
        XCTAssertEqual(group.baselines, [uuidA: 50, uuidB: 40])
    }

    /// A preset entry that would apply nothing is dropped. Without this, every
    /// display ever named by a preset accumulates an empty object forever.
    /// Kills mutation: dropping `DDCPreset.normalized()`, or writing `isEmpty`
    /// against a subset of the three fields.
    func testUpgradeDropsPresetEntriesThatWouldApplyNothing() {
        let document = DisplayStateDocument(presets: [DDCPreset(
            id: "p", name: "Night",
            settings: [uuidA: DDCPresetSettings(brightness: 20), uuidB: DDCPresetSettings()]
        )])

        let preset = DisplayStateMigration.upgraded(document).presets[0]

        XCTAssertEqual(Array(preset.settings.keys), [uuidA])
    }

    // MARK: - Forward compatibility

    /// The whole point of the unknown bag: a build that has never heard of
    /// `somethingFromTheFuture` still writes it back out, at both levels. Before
    /// this, opening an older Crisp once deleted whatever a newer one had stored,
    /// with no error and no way to notice.
    /// Kills mutation: dropping the bag from either `DisplayStateDocument` or
    /// `DisplayState`, or decoding it but never encoding it.
    func testUnknownFieldsSurviveARoundTripAtBothLevels() throws {
        let json = """
        {
          "version": 4,
          "displays": { "\(uuidA.rawValue)": { "contrast": 60, "colourProfile": "sRGB" } },
          "somethingFromTheFuture": { "nested": [1, true, null] }
        }
        """

        let (document, failure) = DisplayStateDocument.decoding(Data(json.utf8))
        XCTAssertNil(failure)

        let rewritten = try JSONEncoder().encode(DisplayStateMigration.upgraded(document))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])

        XCTAssertEqual(object["version"] as? Int, 4)
        XCTAssertNotNil(object["somethingFromTheFuture"], "a top-level field from a newer build must survive")
        let displays = try XCTUnwrap(object["displays"] as? [String: Any])
        let entry = try XCTUnwrap(displays[uuidA.rawValue] as? [String: Any])
        XCTAssertEqual(entry["colourProfile"] as? String, "sRGB", "a per-display field must survive too")
        XCTAssertEqual(entry["contrast"] as? Double, 60, "and the fields this build does know are unchanged")
    }

    /// A display whose only content came from a newer build is not empty, so the
    /// store does not drop it — which would be exactly the data loss the bag
    /// exists to prevent, arriving by a different door.
    /// Kills mutation: computing `isEmpty` from the known fields only.
    func testADisplayHoldingOnlyUnknownFieldsIsNotEmpty() {
        XCTAssertTrue(DisplayState().isEmpty)
        XCTAssertFalse(DisplayState(unknown: ["colourProfile": .string("sRGB")]).isEmpty)
    }

    /// One malformed entry in a list costs that entry and nothing else. Failing
    /// the whole document instead would make the store quarantine it, so a
    /// mistyped schedule would take the user's per-display brightness with it.
    /// Kills mutation: decoding the lists with a plain `[T]` (one bad element
    /// throws and the document is declared corrupt).
    func testOneMalformedListEntryDoesNotCostTheDocument() {
        let json = """
        {
          "version": 3,
          "displays": { "\(uuidA.rawValue)": { "brightness": 12 } },
          "presets": [
            { "id": "good", "name": "Night", "settings": {} },
            { "name": "no id at all" },
            "not even an object"
          ],
          "schedules": [ { "id": "s", "presetID": "good", "trigger": { "at": "25:00" } } ]
        }
        """

        let (document, failure) = DisplayStateDocument.decoding(Data(json.utf8))

        XCTAssertNil(failure, "a bad list entry is not a corrupt document")
        XCTAssertEqual(document.displays[uuidA]?.brightness, 12)
        XCTAssertEqual(document.presets.map(\.id), ["good"])
        XCTAssertTrue(document.schedules.isEmpty, "'25:00' is not a time of day, so that schedule is dropped")
    }

    /// Garbage bytes still degrade to an empty document and report the failure:
    /// v3 added three collections and none of them may become a new way for
    /// persistence to take the app down (AGENTS.md rule #4).
    /// Kills mutation: making the new members' decode throw out of `decoding`.
    func testCorruptInputStillDegradesToAnEmptyDocument() {
        let (document, failure) = DisplayStateDocument.decoding(Data(#"{"version": 3, "presets": [{"#.utf8))

        XCTAssertNotNil(failure)
        XCTAssertEqual(document, DisplayStateDocument())
        XCTAssertTrue(DisplayStateMigration.upgraded(document).presets.isEmpty)
    }

    /// A list member that is present but is not a list at all (a hand edit that
    /// put an object where an array belongs) reads as empty rather than failing
    /// the document — the same tolerance the scalar members have always had.
    /// Kills mutation: decoding the member with `try` so a wrong type throws.
    func testAListMemberOfTheWrongTypeReadsAsEmpty() {
        let json = #"{"version": 3, "groups": {"id": "g"}, "displays": {}}"#

        let (document, failure) = DisplayStateDocument.decoding(Data(json.utf8))

        XCTAssertNil(failure)
        XCTAssertTrue(document.groups.isEmpty)
    }

    /// The documented on-disk shape: the three collections are siblings of
    /// `displays`, and an install that has never made one writes no empty arrays.
    /// Kills mutation: nesting them under `displays`, renaming a key, or always
    /// emitting `[]` (noise in every bug report from every user).
    func testEncodedShapeKeepsTheCollectionsAsSiblingsAndOmitsEmptyOnes() throws {
        let bare = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(DisplayStateDocument())
        ) as? [String: Any]
        XCTAssertNil(bare?["groups"])
        XCTAssertNil(bare?["presets"])
        XCTAssertNil(bare?["schedules"])

        let full = DisplayStateDocument(
            groups: [DisplayGroup(id: "g", name: "Desk", members: [uuidA])],
            presets: [DDCPreset(id: "p", name: "Night", settings: [uuidA: DDCPresetSettings(brightness: 20)])],
            schedules: [PresetSchedule(
                id: "s", presetID: "p",
                trigger: ScheduleTrigger(at: TimeOfDay(hour: 22, minute: 0)!),
                armedAt: Date(timeIntervalSince1970: 0)
            )]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(full)) as? [String: Any]
        )

        XCTAssertEqual((object["groups"] as? [Any])?.count, 1)
        XCTAssertEqual((object["presets"] as? [Any])?.count, 1)
        let schedules = try XCTUnwrap(object["schedules"] as? [[String: Any]])
        let trigger = try XCTUnwrap(schedules[0]["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["at"] as? String, "22:00", "a trigger reads as a time, not as two numbers")
    }

    /// Every v3 entity survives encode → decode unchanged, including the fields
    /// whose "unset" value is falsy and the ones with tolerant decoders.
    /// Kills mutation: dropping a field from any of the three models, or writing
    /// a tolerant decoder that also loses the value it was tolerating.
    func testEveryV3EntityRoundTrips() throws {
        let document = DisplayStateDocument(
            displays: [uuidA: DisplayState(brightness: 0, volumeCapable: true)],
            groups: [DisplayGroup(
                id: "g", name: "Desk", members: [uuidA, uuidB],
                syncMode: .absolute, baselines: [uuidA: 12, uuidB: 80]
            )],
            presets: [DDCPreset(
                id: "p", name: "Night",
                settings: [uuidA: DDCPresetSettings(brightness: 0, contrast: 45, volume: 10)]
            )],
            schedules: [PresetSchedule(
                id: "s", presetID: "p", enabled: false,
                trigger: ScheduleTrigger(at: TimeOfDay(hour: 7, minute: 5)!, days: [2, 3, 4, 5, 6]),
                armedAt: Date(timeIntervalSince1970: 1_000),
                lastFired: Date(timeIntervalSince1970: 2_000)
            )]
        )

        let decoded = try JSONDecoder().decode(
            DisplayStateDocument.self, from: try JSONEncoder().encode(document)
        )

        XCTAssertEqual(decoded, document)
    }

    /// A group whose `syncMode` is missing, or is a mode a newer build invented,
    /// decodes as relative rather than being dropped. Relative is the safe
    /// default because it preserves the difference the user dialled in.
    /// Kills mutation: decoding `syncMode` with `try` (an unknown value would
    /// throw and `LossyList` would drop the whole group), or defaulting to
    /// absolute (which silently flattens a mixed-monitor desk).
    func testAnUnknownSyncModeFallsBackToRelativeRatherThanDroppingTheGroup() {
        let json = """
        {"version": 3, "groups": [
          {"id": "a", "name": "No mode", "members": ["\(uuidA.rawValue)"]},
          {"id": "b", "name": "Future mode", "syncMode": "perceptual"}
        ]}
        """

        let document = DisplayStateDocument.decoding(Data(json.utf8)).document

        XCTAssertEqual(document.groups.map(\.id), ["a", "b"])
        XCTAssertTrue(document.groups.allSatisfy { $0.syncMode == .relative })
    }
}
