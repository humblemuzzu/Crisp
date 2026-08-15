import XCTest

/// Headless tests for the pure half of the per-display state store: the `Codable`
/// document and the v1 (`UserDefaults`) → v2 (`displays.json`) migration.
///
/// `DisplayUUID` and `DisplayStateDocument` are compiled directly into this test
/// target (see `project.yml` sources, same route as `GammaPersistenceKey`), so no
/// `@testable import Crisp` is needed — that would drag in AppKit/IOKit and defeat
/// the headless purity. The I/O half (`DisplayStateStore`: files, debounce, atomic
/// rename) is covered separately in `DisplayStateStoreIOTests`, below.
///
/// Each test names the mutation it is designed to kill in a trailing comment.
final class DisplayStateStoreTests: XCTestCase {

    private let uuidA = DisplayUUID("37D8832A-2D66-02CA-B9F7-8F30A301B230")
    private let uuidB = DisplayUUID("v1552-m30740-s16843009")

    // MARK: - Round trip

    /// Every field survives encode → decode unchanged, including the ones whose
    /// "unset" value is falsy (`0`, `false`) and would be indistinguishable from
    /// `nil` if any field were made non-optional with a default.
    /// Kills mutation: dropping a field from the model, or making a field
    /// non-optional so `0`/`false` collapses into "never set".
    func testRoundTripPreservesEveryField() throws {
        let state = DisplayState(
            brightness: 0,
            contrast: 48.5,
            volume: 100,
            input: 19,
            reapplyInputOnReconnect: false,
            softwareBrightnessFactor: 0.35,
            volumeCapable: true,
            brightnessKeySelected: true
        )
        let document = DisplayStateDocument(displays: [uuidA: state])

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(DisplayStateDocument.self, from: data)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.displays[uuidA]?.brightness, 0)
        XCTAssertEqual(decoded.displays[uuidA]?.reapplyInputOnReconnect, false)
        XCTAssertEqual(decoded.displays[uuidA]?.input, 19)
    }

    /// The on-disk shape is the documented one: `version` plus a `displays`
    /// object keyed by the raw UUID string. Without `CodingKeyRepresentable`,
    /// `Dictionary`'s `Codable` conformance emits a flat `[key, value, …]`
    /// array instead, which is neither greppable nor hand-editable.
    /// Kills mutation: dropping the `CodingKeyRepresentable` conformance on
    /// `DisplayUUID`, or encoding it as `{"rawValue": …}`.
    func testEncodedShapeIsAVersionedObjectKeyedByUUIDString() throws {
        let document = DisplayStateDocument(displays: [uuidA: DisplayState(brightness: 42)])
        let data = try JSONEncoder().encode(document)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["version"] as? Int, 2)
        let displays = try XCTUnwrap(json["displays"] as? [String: Any])
        let entry = try XCTUnwrap(displays[uuidA.rawValue] as? [String: Any])
        XCTAssertEqual(entry["brightness"] as? Double, 42)
    }

    // MARK: - Tolerant decoding

    /// A document written by another build: no `version`, unknown top-level and
    /// per-display fields, and only some of the fields this build knows.
    /// Kills mutation: decoding `version`/`displays` with `decode` instead of
    /// `decodeIfPresent` (throws on the missing key), or adding a strict
    /// unknown-key check that rejects a forward-compatible document.
    func testDecodingToleratesMissingAndUnknownFields() throws {
        let json = """
        {
          "displays": {
            "\(uuidA.rawValue)": { "contrast": 60, "somethingFromTheFuture": [1, 2, 3] }
          },
          "extraTopLevelField": "ignored"
        }
        """
        let (document, failure) = DisplayStateDocument.decoding(Data(json.utf8))

        XCTAssertNil(failure)
        XCTAssertEqual(document.version, 2, "a document without a version is read as the current one")
        XCTAssertEqual(document.displays[uuidA]?.contrast, 60)
        XCTAssertNil(document.displays[uuidA]?.brightness)
    }

    /// An empty object still decodes: no `displays` key means no displays, not
    /// a failure.
    /// Kills mutation: defaulting `displays` to anything but empty, or throwing
    /// when it is absent.
    func testDecodingEmptyObjectYieldsEmptyDocument() {
        let (document, failure) = DisplayStateDocument.decoding(Data("{}".utf8))

        XCTAssertNil(failure)
        XCTAssertTrue(document.displays.isEmpty)
        XCTAssertEqual(document.version, 2)
    }

    /// Truncated/garbage bytes (the crash-mid-write case the atomic writer is
    /// there to prevent, and any hand-edit that breaks the syntax) degrade to an
    /// empty document and report the failure instead of throwing at the caller:
    /// AGENTS.md rule #4, persistence may never take the app down.
    /// Kills mutation: making `decoding` throw, or swallowing the error so the
    /// store cannot log or quarantine the bad file.
    func testCorruptInputYieldsEmptyDocumentAndReportsFailure() {
        let (document, failure) = DisplayStateDocument.decoding(Data(#"{"version": 2, "displa"#.utf8))

        XCTAssertNotNil(failure)
        XCTAssertEqual(document, DisplayStateDocument())
    }

    /// A syntactically valid document with a wrong-typed field is corrupt too,
    /// and must take the same degrade path rather than crashing on a force-cast.
    /// Kills mutation: catching only `DecodingError.dataCorrupted`, or decoding
    /// values with `as!`.
    func testTypeMismatchIsTreatedAsCorrupt() {
        let json = #"{"version": 2, "displays": {"\#(uuidA.rawValue)": {"brightness": "bright"}}}"#
        let (document, failure) = DisplayStateDocument.decoding(Data(json.utf8))

        XCTAssertNotNil(failure)
        XCTAssertTrue(document.displays.isEmpty)
    }

    // MARK: - v1 → v2 migration

    /// The full legacy key set folds into the document with the right values,
    /// including the two list-shaped settings that become per-display flags.
    /// Kills mutation: mapping a `crisp.ddcState.<uuid>.<field>` key to the wrong
    /// field, splitting the key on the *first* dot (which would make the uuid
    /// empty), or dropping either membership list.
    func testMigrationProducesTheRightValuesFromLegacyDefaults() {
        let legacy: [String: LegacyDefaultsValue] = [
            "crisp.ddcState.\(uuidA.rawValue).brightness": .number(72),
            "crisp.ddcState.\(uuidA.rawValue).contrast": .number(48),
            "crisp.ddcState.\(uuidA.rawValue).volume": .number(30),
            "crisp.ddcState.\(uuidA.rawValue).input": .number(19),
            "crisp.ddcState.\(uuidA.rawValue).reapplyInput": .flag(true),
            "crisp.softBrightness.uuid.\(uuidA.rawValue)": .number(0.4),
            "crisp.volumeCapableDisplays": .list([uuidA.rawValue, uuidB.rawValue]),
            "crisp.brightnessKeySelectedDisplays": .list([uuidB.rawValue])
        ]

        let document = DisplayStateMigration.migrated(legacy: legacy, into: DisplayStateDocument())

        XCTAssertEqual(document.version, 2)
        XCTAssertEqual(document.displays[uuidA], DisplayState(
            brightness: 72,
            contrast: 48,
            volume: 30,
            input: 19,
            reapplyInputOnReconnect: true,
            softwareBrightnessFactor: 0.4,
            volumeCapable: true
        ))
        XCTAssertEqual(document.displays[uuidB], DisplayState(volumeCapable: true, brightnessKeySelected: true))
    }

    /// `UserDefaults` erases `Bool` to an `NSNumber`, so the store hands the
    /// migration a `.number` for a key that was written as a flag. Migration has
    /// to interpret per key, not per stored type.
    /// Kills mutation: reading `reapplyInput` as a number field, or accepting
    /// only `.flag` and therefore silently dropping every migrated toggle.
    func testMigrationReadsNumericBooleansAsFlags() {
        let on = DisplayStateMigration.migrated(
            legacy: ["crisp.ddcState.\(uuidA.rawValue).reapplyInput": .number(1)],
            into: DisplayStateDocument()
        )
        let off = DisplayStateMigration.migrated(
            legacy: ["crisp.ddcState.\(uuidB.rawValue).reapplyInput": .number(0)],
            into: DisplayStateDocument()
        )

        XCTAssertEqual(on.displays[uuidA]?.reapplyInputOnReconnect, true)
        XCTAssertEqual(off.displays[uuidB]?.reapplyInputOnReconnect, false)
    }

    /// Running the migration twice — and running it over a document that already
    /// holds newer state — changes nothing: existing values win, and a second
    /// pass cannot resurrect a stale v1 value. This is what makes an interrupted
    /// migration (document written, sentinel not yet set) safe to repeat.
    /// Kills mutation: overwriting existing fields, or appending rather than
    /// merging membership flags.
    func testMigrationIsIdempotentAndNeverClobbersNewerState() {
        let legacy: [String: LegacyDefaultsValue] = [
            "crisp.ddcState.\(uuidA.rawValue).brightness": .number(72),
            "crisp.ddcState.\(uuidA.rawValue).contrast": .number(48),
            "crisp.volumeCapableDisplays": .list([uuidA.rawValue])
        ]

        let once = DisplayStateMigration.migrated(legacy: legacy, into: DisplayStateDocument())
        let twice = DisplayStateMigration.migrated(legacy: legacy, into: once)
        XCTAssertEqual(twice, once)

        // The user has since dragged brightness to 20; the v1 value must not win.
        var newer = once
        newer.displays[uuidA]?.brightness = 20
        let overNewer = DisplayStateMigration.migrated(legacy: legacy, into: newer)
        XCTAssertEqual(overNewer.displays[uuidA]?.brightness, 20)
        XCTAssertEqual(overNewer.displays[uuidA]?.contrast, 48)
    }

    /// An input code out of `UInt16`'s range must clamp, not trap: the v1 reader
    /// did `UInt16(defaults.double(forKey:))` on a value it never validated, so a
    /// garbage default would crash the app during the very migration meant to
    /// make persistence unable to do that.
    /// Kills mutation: replacing the clamp with a plain `UInt16(_:)` conversion.
    func testMigrationClampsOutOfRangeInputCodes() {
        let document = DisplayStateMigration.migrated(
            legacy: [
                "crisp.ddcState.\(uuidA.rawValue).input": .number(-7),
                "crisp.ddcState.\(uuidB.rawValue).input": .number(1e9)
            ],
            into: DisplayStateDocument()
        )

        XCTAssertEqual(document.displays[uuidA]?.input, 0)
        XCTAssertEqual(document.displays[uuidB]?.input, UInt16.max)
    }

    /// Keys the migration does not understand are ignored, and none of them may
    /// mint an empty display entry.
    /// Kills mutation: dropping the `default: break` guard on the field switch,
    /// or removing the empty-entry filter (which would leave `{}` objects in the
    /// document for every malformed key).
    func testMigrationIgnoresUnknownAndMalformedKeys() {
        let document = DisplayStateMigration.migrated(
            legacy: [
                "crisp.ddcState.\(uuidA.rawValue).gamma": .number(1),
                "crisp.ddcState.brightness": .number(50),
                "crisp.ddcState.": .number(50),
                "crisp.unrelatedSetting": .number(1)
            ],
            into: DisplayStateDocument()
        )

        XCTAssertTrue(document.displays.isEmpty)
    }

    /// The store hands over exactly the keys the migration understands. The
    /// displayID-keyed `crisp.softBrightness_<id>` legacy key is excluded on
    /// purpose: mapping it to a UUID needs the display to be online, which is
    /// `BrightnessService.migrateLegacySoftBrightnessIfNeeded`'s job. Guessing
    /// here is the issue #32 bug.
    /// Kills mutation: widening `isLegacyKey` to the `crisp.softBrightness_`
    /// prefix (a displayID would then be persisted as a UUID), or narrowing it
    /// so a whole key family stops migrating.
    func testLegacyKeyRecognition() {
        XCTAssertTrue(DisplayStateMigration.isLegacyKey("crisp.ddcState.\(uuidA.rawValue).brightness"))
        XCTAssertTrue(DisplayStateMigration.isLegacyKey("crisp.softBrightness.uuid.\(uuidA.rawValue)"))
        XCTAssertTrue(DisplayStateMigration.isLegacyKey("crisp.volumeCapableDisplays"))
        XCTAssertTrue(DisplayStateMigration.isLegacyKey("crisp.brightnessKeySelectedDisplays"))

        XCTAssertFalse(DisplayStateMigration.isLegacyKey("crisp.softBrightness_2"))
        XCTAssertFalse(DisplayStateMigration.isLegacyKey("crisp.GammaService.savedAdjustment.uuid.\(uuidA.rawValue)"))
        XCTAssertFalse(DisplayStateMigration.isLegacyKey("crisp.menuWidth"))
    }

    // MARK: - DisplayUUID

    /// The wrapper encodes as the bare string it wraps, both as a value and as a
    /// dictionary key, so the document stays readable.
    /// Kills mutation: falling back to the synthesized `{"rawValue": …}` coding.
    func testDisplayUUIDEncodesAsABareString() throws {
        let data = try JSONEncoder().encode(uuidA)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(uuidA.rawValue)\"")

        let decoded = try JSONDecoder().decode(DisplayUUID.self, from: data)
        XCTAssertEqual(decoded, uuidA)
        XCTAssertEqual(decoded.description, uuidA.rawValue)
    }

    /// Identity is the raw string and nothing else, which is what makes the type
    /// usable as a dictionary key and a set member for the membership settings.
    /// Kills mutation: a custom `==`/`hash` that ignores or normalizes the value
    /// (case-folding would silently merge two displays).
    func testDisplayUUIDIdentityIsTheRawString() {
        XCTAssertEqual(DisplayUUID(uuidA.rawValue), uuidA)
        XCTAssertNotEqual(DisplayUUID(uuidA.rawValue.lowercased()), uuidA)
        XCTAssertEqual(Set([uuidA, DisplayUUID(uuidA.rawValue), uuidB]).count, 2)
    }

    /// An all-`nil` state is empty, and any single set field makes it non-empty.
    /// The store drops empty entries, so a wrong answer here either leaves dead
    /// objects in the document forever or deletes state that was just written.
    /// Kills mutation: implementing `isEmpty` against a subset of the fields.
    func testEmptyStateDetectionCoversEveryField() {
        XCTAssertTrue(DisplayState().isEmpty)

        let mutations: [(String, (inout DisplayState) -> Void)] = [
            ("brightness", { $0.brightness = 0 }),
            ("contrast", { $0.contrast = 0 }),
            ("volume", { $0.volume = 0 }),
            ("input", { $0.input = 0 }),
            ("reapplyInputOnReconnect", { $0.reapplyInputOnReconnect = false }),
            ("softwareBrightnessFactor", { $0.softwareBrightnessFactor = 0 }),
            ("volumeCapable", { $0.volumeCapable = false }),
            ("brightnessKeySelected", { $0.brightnessKeySelected = false })
        ]
        for (field, mutate) in mutations {
            var state = DisplayState()
            mutate(&state)
            XCTAssertFalse(state.isEmpty, "\(field) set must make the state non-empty")
        }
    }
}

/// The I/O half of the store: what actually reaches `displays.json`, when, and
/// what happens when the bytes already there are broken. This is the mechanism
/// most likely to lose a user's settings, so it is tested against the real
/// filesystem rather than a fake — the atomic rename and the debounce only mean
/// anything as filesystem behaviour.
///
/// Every store here is built with an injected temp directory and an in-memory
/// `LegacyDefaults`, and the directory is removed after each test. Nothing may
/// touch the real `~/Library/Application Support/Crisp/` (the user's live
/// display state) or `~/Library/Preferences` (a real defaults suite leaves an
/// empty plist behind that cfprefsd recreates after a delete).
///
/// Each test names the mutation it is designed to kill in a trailing comment.
final class DisplayStateStoreIOTests: XCTestCase {

    /// The v1 `UserDefaults` layout, in memory. Empty here: the migration itself
    /// is covered by the pure tests above, and these tests only need it not to
    /// touch the user's machine.
    private final class InMemoryLegacyDefaults: LegacyDefaults {
        private var values: [String: Any] = [:]
        func dictionaryRepresentation() -> [String: Any] { values }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
    }

    private let uuidA = DisplayUUID("37D8832A-2D66-02CA-B9F7-8F30A301B230")

    /// Comfortably past the store's 0.5 s save debounce.
    private let afterDebounce: TimeInterval = 1.0

    private var directory: URL!
    private var defaults = InMemoryLegacyDefaults()

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CrispDisplayStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = InMemoryLegacyDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> DisplayStateStore {
        DisplayStateStore(directory: directory, defaults: defaults)
    }

    private var documentURL: URL {
        directory.appendingPathComponent("displays.json")
    }

    /// The document as it currently sits on disk. A missing or unreadable file
    /// reads as empty, because "nothing has been written yet" is a state these
    /// tests assert on rather than an error.
    private func readDocument() -> DisplayStateDocument {
        guard let data = try? Data(contentsOf: documentURL) else { return DisplayStateDocument() }
        return DisplayStateDocument.decoding(data).document
    }

    // MARK: - Writing

    /// A flushed change lands in the temp directory as `displays.json`, in the
    /// documented versioned-object shape — the same shape the pure round-trip
    /// test asserts, but produced by the real writer this time.
    /// Kills mutation: writing to a path built from anything but the injected
    /// directory, renaming the file, or dropping the encoder so the document
    /// never reaches the disk at all.
    func testFlushedChangeLandsOnDiskInTheDocumentedShape() throws {
        let store = makeStore()
        store.update(uuidA) { $0.contrast = 48 }
        store.flush()

        let data = try Data(contentsOf: documentURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        let displays = try XCTUnwrap(json["displays"] as? [String: Any])
        let entry = try XCTUnwrap(displays[uuidA.rawValue] as? [String: Any])
        XCTAssertEqual(entry["contrast"] as? Double, 48)
    }

    /// A slider drag emits a change per tick. None of them may hit the disk while
    /// the drag is running, and the value that finally lands is the last one —
    /// the two halves of "coalesced" that matter to a user.
    /// Kills mutation: writing synchronously inside `update` (every tick would
    /// hit the disk, and the mid-drag read would already see a value), or never
    /// scheduling the debounced write (the last value would never land).
    func testRapidUpdatesAreCoalescedAndTheLastValueWins() {
        let store = makeStore()
        // Ten ticks spread over ~200 ms, the shape of a short slider drag and
        // comfortably inside the 0.5 s debounce window.
        for value in stride(from: 10.0, through: 100.0, by: 10.0) {
            store.update(uuidA) { $0.brightness = value }
            Thread.sleep(forTimeInterval: 0.02)
        }

        // Give a writer that ignores the debounce every chance to land: 100 ms is
        // far more than a dispatch plus a few hundred bytes of JSON, and still
        // only a fifth of the window. In-memory state is already final.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(store.state(for: uuidA).brightness, 100)
        XCTAssertNil(readDocument().displays[uuidA]?.brightness, "the drag must not write per tick")

        Thread.sleep(forTimeInterval: afterDebounce)
        XCTAssertEqual(readDocument().displays[uuidA]?.brightness, 100)
    }

    /// `flush()` writes synchronously on the calling thread. It has to: the only
    /// caller that matters is the terminate notification, which is posted on the
    /// terminating thread and never gets a second chance to run.
    /// Kills mutation: making `flush` cancel the pending save without writing, or
    /// hopping the write onto `ioQueue` asynchronously (quit would lose it).
    func testFlushWritesImmediatelyRatherThanWaitingForTheDebounce() {
        let store = makeStore()
        store.update(uuidA) { $0.volume = 30 }
        store.flush()

        XCTAssertEqual(readDocument().displays[uuidA]?.volume, 30)
    }

    /// A truncated `displays.json` — a crash mid-write by an older build, or a
    /// broken hand-edit — must not throw at the caller, must not be silently
    /// overwritten, and must not wedge the store: AGENTS.md rule #4.
    /// Kills mutation: loading with `try!`/`decode` (a truncated file would trap
    /// or throw at init), or dropping the quarantine move so the only copy of
    /// the bad bytes is destroyed by the next save.
    func testTruncatedDocumentDegradesToEmptyAndTheStoreKeepsWorking() throws {
        try Data(#"{"version": 2, "displa"#.utf8).write(to: documentURL)

        let store = makeStore()
        XCTAssertEqual(store.state(for: uuidA), DisplayState())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("displays.corrupt.json").path),
            "the bad bytes are kept for diagnosis"
        )

        store.update(uuidA) { $0.contrast = 55 }
        store.flush()
        XCTAssertEqual(readDocument().displays[uuidA]?.contrast, 55)
    }

    /// Callers live on several threads (the brightness writer on its own queue,
    /// the DDC feature services on the main actor), so two writes can overlap. A
    /// reader must never catch a half-written file — which is the whole reason
    /// the writer stages into a temp file and renames.
    /// Kills mutation: encoding straight into `displays.json` instead of staging
    /// into a temp file and renaming, or dropping `.atomic` from the first write.
    /// (Verified: an in-place writer fails this with 40–100 torn reads per run.
    /// Dropping the *write lock* alone does not fail it — the rename is atomic
    /// either way — so that mutation is out of this test's reach.)
    func testConcurrentWritesNeverLeaveATruncatedFile() {
        let store = makeStore()
        let writers = 8
        let rounds = 40

        // A few hundred displays make the encoded document several kilobytes, so
        // a writer that rewrites `displays.json` in place leaves a window a
        // reader can actually land in. With a two-line document it would not.
        for index in 0..<200 {
            store.update(DisplayUUID("test-display-\(index)")) { $0.brightness = 0 }
        }
        store.flush()

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: writers) { writer in
                for round in 1...rounds {
                    store.update(DisplayUUID("test-display-\(writer)")) { $0.brightness = Double(round) }
                    store.flush()
                }
            }
            finished.signal()
        }

        // Spin on the file for as long as the writers run: every read has to be a
        // complete document, never a half-replaced one.
        var reads = 0
        var failures = 0
        while finished.wait(timeout: .now()) == .timedOut {
            guard let data = try? Data(contentsOf: documentURL) else { continue }
            reads += 1
            if DisplayStateDocument.decoding(data).failure != nil { failures += 1 }
        }
        XCTAssertEqual(failures, 0, "\(failures) of \(reads) concurrent reads saw a partial file")
        // Without this the test would pass vacuously if the writers finished
        // before the reader ever looked.
        XCTAssertTrue(reads > 100, "only \(reads) reads overlapped the writers")

        let document = readDocument()
        for writer in 0..<writers {
            XCTAssertEqual(document.displays[DisplayUUID("test-display-\(writer)")]?.brightness, Double(rounds))
        }
        XCTAssertEqual(document.displays.count, 200)
    }
}
