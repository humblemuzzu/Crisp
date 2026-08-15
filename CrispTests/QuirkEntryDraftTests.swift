import XCTest

/// Headless tests for "report this monitor": probe results → a quirks JSON entry
/// and its GitHub issue body.
///
/// `QuirkEntryDraft` and `MonitorQuirks` are both compiled into this target (see
/// `project.yml`), which is what makes the important test here possible: the
/// generated JSON is pushed back through the **real** `MonitorQuirksFile` decoder,
/// not through a mirror of it. A generator whose output the loader rejects is
/// worse than no generator — it produces contributions that silently vanish at
/// launch. Each test names the mutation it is designed to kill.
final class QuirkEntryDraftTests: XCTestCase {

    // MARK: - EDID manufacturer id

    /// EDID packs the three-letter PnP id into 16 bits: one reserved bit, then
    /// three 5-bit letters with 1 = 'A'. `0x09D1` is the BenQ id this fork was
    /// built against, so it is the one worth pinning.
    /// Kills mutation: shifting by 5/10 in the wrong order (yields "QNB"), masking
    /// with 0x1F vs 0x3F, or using 'A' = 0 (yields "COR" for BenQ).
    func testEDIDManufacturerCodeDecodesTheKnownIDs() {
        XCTAssertEqual(EDIDManufacturer.code(for: 0x09D1), "BNQ")
        XCTAssertEqual(EDIDManufacturer.code(for: 0x10AC), "DEL")
        XCTAssertEqual(EDIDManufacturer.code(for: 0x4C2D), "SAM")
    }

    /// A field that does not decode to three A–Z letters is a synthesised or
    /// virtual display, not a vendor. Unknown must read as unknown.
    /// Kills mutation: clamping out-of-range values into letters, which would put
    /// a fabricated three-letter vendor into a submitted database entry.
    func testEDIDManufacturerCodeRefusesFieldsThatAreNotThreeLetters() {
        XCTAssertNil(EDIDManufacturer.code(for: 0), "zero has no letters")
        XCTAssertNil(EDIDManufacturer.code(for: 0x0000_1FFF), "letter 31 is past 'Z'")
        XCTAssertNil(EDIDManufacturer.code(for: 0x0001_09D1), "a value wider than 16 bits is not an EDID id")
    }

    // MARK: - Names

    /// macOS reports the EDID product name, which conventionally leads with the
    /// vendor. "BenQ MA320U" must split exactly the way the hand-written
    /// `benq.json` entry is spelled, or the generated entry looks unlike every
    /// shipped one.
    /// Kills mutation: putting the whole display name in `name` and the PnP code in
    /// `vendorName`, or splitting on the last space instead of the first.
    func testDisplayNameSplitsIntoVendorAndModel() {
        let names = QuirkEntryGenerator.names(displayName: "BenQ MA320U", vendor: 0x09D1, product: 0x8075)
        XCTAssertEqual(names.vendor, "BenQ")
        XCTAssertEqual(names.model, "MA320U")

        let multiword = QuirkEntryGenerator.names(displayName: "LG UltraFine 5K", vendor: 0x1E6D, product: 0x1234)
        XCTAssertEqual(multiword.vendor, "LG")
        XCTAssertEqual(multiword.model, "UltraFine 5K", "everything after the first token is the model")
    }

    /// One token, or none: fall back to facts (the EDID PnP code, the raw ids)
    /// rather than to a guess.
    /// Kills mutation: emitting an empty `vendorName`, which decodes fine and then
    /// reads as a blank vendor in the merged database.
    func testNamesFallBackToEDIDFactsWhenTheDisplayNameIsThin() {
        let single = QuirkEntryGenerator.names(displayName: "MA320U", vendor: 0x09D1, product: 0x8075)
        XCTAssertEqual(single.vendor, "BNQ", "no vendor token, so use the EDID PnP id")
        XCTAssertEqual(single.model, "MA320U")

        let missing = QuirkEntryGenerator.names(displayName: nil, vendor: 0x09D1, product: 0x8075)
        XCTAssertEqual(missing.vendor, "BNQ")
        XCTAssertEqual(missing.model, "0x8075")

        let unknownVendor = QuirkEntryGenerator.names(displayName: nil, vendor: 0, product: 0x8075)
        XCTAssertEqual(unknownVendor.vendor, "0x0000", "an undecodable id still prints as an id")
    }

    /// `benq.json` for "BenQ": the file name the issue body tells a contributor to
    /// create, matching the shipped one exactly.
    /// Kills mutation: keeping the vendor's capitalisation or its spaces, which
    /// would send contributors to `BenQ.json` / `Some Vendor.json` and fork the
    /// database into two files for one vendor.
    func testSuggestedFileNameIsALowercaseSlug() {
        XCTAssertEqual(QuirkEntryGenerator.suggestedFileName(vendorName: "BenQ"), "benq.json")
        XCTAssertEqual(QuirkEntryGenerator.suggestedFileName(vendorName: "Some Vendor, Inc."), "somevendorinc.json")
        XCTAssertEqual(QuirkEntryGenerator.suggestedFileName(vendorName: "0x09D1"), "0x09d1.json")
        XCTAssertEqual(QuirkEntryGenerator.suggestedFileName(vendorName: "…"), "vendor.json", "never an empty name")
    }

    // MARK: - Round trip through the real loader

    /// **The test this file exists for.** The generated entry must survive the
    /// production decoder with every field intact and land under the right key.
    /// Kills mutation: emitting decimal ids the parser reads as hex (or vice
    /// versa), nesting `features` wrongly, or naming a feature something
    /// `QuirkFeatureName` does not know — all of which produce JSON that looks
    /// right and loads as nothing.
    func testGeneratedEntryRoundTripsThroughTheRealParser() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        let file = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file, json)

        XCTAssertEqual(file.problems, [], "the generator must not emit an entry the loader drops")
        XCTAssertEqual(file.vendor, 0x09D1)
        XCTAssertEqual(file.vendorName, "BenQ")
        XCTAssertEqual(file.schemaVersion, MonitorQuirksFile.currentSchemaVersion)

        let model = try XCTUnwrap(file.models.first)
        XCTAssertEqual(model.key, MonitorQuirkKey(vendor: 0x09D1, product: 0x8075))
        XCTAssertEqual(model.modelName, "MA320U")
        XCTAssertEqual(model.feature(.brightness)?.range, QuirkRange(min: 0, max: 100))
        XCTAssertEqual(model.feature(.contrast)?.range, QuirkRange(min: 0, max: 100))
        XCTAssertEqual(model.feature(.volume)?.range, QuirkRange(min: 0, max: 50))
        XCTAssertEqual(model.inputValues.map(\.code), [19])
    }

    /// Key order must be deterministic. `JSONEncoder` builds keyed containers from
    /// a dictionary and Swift seeds string hashing per process, so without
    /// `.sortedKeys` regenerating the same entry emits the same data in a
    /// different order — and a contributor who regenerates before pushing gets a
    /// diff full of nothing.
    /// Kills mutation: dropping `.sortedKeys` from the encoder's output
    /// formatting.
    func testGeneratedJSONHasDeterministicKeyOrder() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        // Top-level keys are the ones at two-space indentation.
        let topLevel = json.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("  \""), let end = line.dropFirst(3).firstIndex(of: "\"") else { return nil }
                return String(line.dropFirst(3)[..<end])
            }
        XCTAssertEqual(topLevel, ["models", "schemaVersion", "vendor", "vendorName"])
        XCTAssertEqual(json, try QuirkEntryGenerator.json(for: benq), "same probe, same bytes")
    }

    /// **The rule the database enforces in code, and this generator must not
    /// fight.** No input code may be emitted as `verified`: an unverified 0x60
    /// write sends the panel to a dead port and the only way back is the monitor's
    /// physical buttons.
    /// Kills mutation: emitting `"confidence": "verified"` anywhere, or omitting
    /// the input confidence and relying on inheritance (which the decoder caps at
    /// `reported` today — but a generator must not depend on somebody else's cap).
    func testNoInputCodeIsEverEmittedAsVerified() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        XCTAssertFalse(json.contains("\"verified\""), "the generator emitted a verified field:\n\(json)")
        XCTAssertEqual(QuirkEntryGenerator.emittedConfidence, .reported)

        let model = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file?.models.first)
        XCTAssertEqual(model.confidence, .reported)
        for feature in QuirkFeatureName.allCases {
            XCTAssertEqual(model.feature(feature)?.confidence ?? .reported, .reported, feature.rawValue)
        }
        XCTAssertTrue(
            model.inputValues.allSatisfy { !$0.confidence.isVerified },
            "an input code reached verified: \(model.inputValues)"
        )
    }

    /// The resolver must still demand confirmation before writing the generated
    /// code — the end-to-end statement of the rule above, through the real
    /// resolution path rather than through the JSON text.
    /// Kills mutation: any change that lets a generated entry skip the input
    /// confirmation dialog.
    func testGeneratedInputCodeStillNeedsConfirmationAfterLoading() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        let model = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file?.models.first)
        // Resolved as a code the user has never picked and the monitor is not on,
        // i.e. the case where writing it is a leap of faith.
        let resolved = MonitorQuirkResolver.input(
            code: 19, quirks: model, currentInput: 33, userSelectedInput: nil
        )
        XCTAssertTrue(resolved.needsConfirmation)
        XCTAssertTrue(resolved.displayLabel.hasSuffix("?"), "an unconfirmed label keeps its question mark")
    }

    /// **The MCCS label never becomes a database label.** Code 19 is the worked
    /// example: `MCCSInputTable` names it "DVI-10" and the MA320U has no DVI port.
    /// The generator must emit the neutral `Input-19` and put the table's name in
    /// the notes, where it reads as the guess it is.
    /// Kills mutation: `label: MCCSInputTable.label(for: code) ?? …`, which would
    /// promote a specification's claim about monitors in general to a contributed
    /// fact about this model — and get this exact monitor wrong.
    func testMCCSLabelIsNeverCopiedIntoTheEntry() throws {
        let json = try QuirkEntryGenerator.json(for: probe(inputCurrent: 19))
        XCTAssertFalse(json.contains("DVI-10\""), "the MCCS name reached a label field:\n\(json)")

        let model = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file?.models.first)
        let value = try XCTUnwrap(model.inputValue(for: 19))
        XCTAssertEqual(value.label, "Input-19")
        let notes = try XCTUnwrap(value.notes)
        XCTAssertTrue(notes.contains("UNCONFIRMED"), notes)
        XCTAssertTrue(notes.contains("\"DVI-10\""), "the table's guess belongs in the notes: \(notes)")
    }

    /// A code the MCCS table does not name at all says so, rather than quoting a
    /// table entry that does not exist.
    /// Kills mutation: emitting an empty quoted label ("" reads as a name), or
    /// dropping the branch so the note claims a standard name for every code.
    func testInputCodeOutsideTheMCCSTableSaysThereIsNoStandardName() throws {
        // 0x50 is in none of `MCCSInputTable`'s ranges.
        let json = try QuirkEntryGenerator.json(for: probe(inputCurrent: 0x50))
        let model = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file?.models.first)
        let value = try XCTUnwrap(model.inputValue(for: 0x50))
        XCTAssertEqual(value.label, "Input-80")
        XCTAssertTrue(
            try XCTUnwrap(value.notes).contains("not a code the VESA MCCS table names"),
            value.notes ?? ""
        )
    }

    /// The port list is never declared complete: one code cannot be a whole port
    /// list, and `complete: true` stops the app offering the generic VESA codes —
    /// taking input switching away instead of improving it.
    /// Kills mutation: emitting `complete: true`, or omitting the key and relying
    /// on the decoder's default.
    func testGeneratedInputListIsNeverDeclaredComplete() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        XCTAssertTrue(json.contains("\"complete\" : false"), json)
        let model = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file?.models.first)
        XCTAssertFalse(model.hasCompleteInputList)
    }

    // MARK: - Ranges

    /// A monitor that did not answer a read contributes no range at all. Emitting
    /// `[0, 0]` would be rejected by `QuirkRange` and drop the whole model with it.
    /// Kills mutation: defaulting an unanswered probe to `[0, 100]` (a fabricated
    /// measurement) or to `[0, 0]` (an entry that dies in the loader).
    func testUnansweredProbesContributeNoRange() throws {
        let sparse = MonitorProbeReport(
            vendor: 0x09D1,
            product: 0x8075,
            displayName: "BenQ MA320U",
            brightness: RawProbe(current: 40, max: 100),
            contrast: nil,
            volume: RawProbe(current: 0, max: 0),
            input: nil,
            osVersion: "26.4.1 (25G76)",
            macModel: "Mac16,8",
            appVersion: "1.4.1"
        )
        let json = try QuirkEntryGenerator.json(for: sparse)
        let file = try XCTUnwrap(MonitorQuirksFile.decoding(Data(json.utf8)).file, json)
        XCTAssertEqual(file.problems, [], "a zero max must be skipped, not emitted and then rejected")

        let model = try XCTUnwrap(file.models.first)
        XCTAssertEqual(model.feature(.brightness)?.range, QuirkRange(min: 0, max: 100))
        XCTAssertNil(model.feature(.contrast), "no answer means no claim")
        XCTAssertNil(model.feature(.volume), "a max of 0 is not a range")
        XCTAssertNil(model.feature(.input), "no 0x60 answer means no input entry")
    }

    /// The emitted minimum is 0 and the note says so is an *assumption* — the Dell
    /// 2407wfp ignores everything below raw 30, which is the entire reason
    /// `QuirkRange` carries a minimum at all.
    /// Kills mutation: dropping the caveat, which turns a guess into a claim.
    func testRangeNotesSayTheMinimumIsUnconfirmed() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        XCTAssertTrue(json.contains("minimum is assumed to be 0 and has NOT been confirmed"), json)
    }

    // MARK: - Issue body

    /// The issue body has to be a complete contribution on its own: the JSON, the
    /// file it belongs in, what is still unproven, and the 0x60 warning.
    /// Kills mutation: dropping the JSON block (leaving a bug report that asks the
    /// maintainer to do the work), or dropping the input-source warning.
    func testIssueBodyIsSelfContained() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        let body = QuirkEntryGenerator.issueBody(for: benq, json: json)

        XCTAssertTrue(body.contains("Monitor report: BenQ MA320U"), body)
        XCTAssertTrue(body.contains("Crisp/Resources/quirks/benq.json"), body)
        XCTAssertTrue(body.contains("```json"), "the JSON must be fenced so GitHub does not reflow it")
        XCTAssertTrue(body.contains(json), "the issue body must carry the entry verbatim")
        XCTAssertTrue(body.contains("Never guess an input code"), body)
        XCTAssertTrue(body.contains("26.4.1 (25G76)"), "a reviewer needs the OS it was measured on")
    }

    /// The issue body must not carry the monitor's serial number: quirks describe
    /// a model, not one person's unit, and the database is keyed on vendor +
    /// product precisely so a contributed entry is useful to everybody else.
    /// Kills mutation: adding a serial to `MonitorProbeReport` and printing it.
    func testIssueBodyCarriesNoSerialNumber() throws {
        let json = try QuirkEntryGenerator.json(for: benq)
        let body = QuirkEntryGenerator.issueBody(for: benq, json: json)
        XCTAssertFalse(body.contains("16843009"))
        XCTAssertFalse(json.contains("16843009"))
        XCTAssertTrue(body.contains("No serial number is included"), "and it says so")
    }

    // MARK: - Fixtures

    /// The BenQ MA320U exactly as `crispctl list` reports it, so the expectations
    /// above are checkable against real hardware rather than invented.
    private let benq = MonitorProbeReport(
        vendor: 0x09D1,
        product: 0x8075,
        displayName: "BenQ MA320U",
        brightness: RawProbe(current: 0, max: 100),
        contrast: RawProbe(current: 50, max: 100),
        volume: RawProbe(current: 44, max: 50),
        input: RawProbe(current: 19, max: 19),
        osVersion: "26.4.1 (25G76)",
        macModel: "Mac16,8",
        appVersion: "1.4.1"
    )

    private func probe(inputCurrent: UInt16) -> MonitorProbeReport {
        MonitorProbeReport(
            vendor: 0x09D1,
            product: 0x8075,
            displayName: "BenQ MA320U",
            input: RawProbe(current: inputCurrent, max: inputCurrent),
            osVersion: "26.4.1 (25G76)",
            macModel: "Mac16,8",
            appVersion: "1.4.1"
        )
    }
}
