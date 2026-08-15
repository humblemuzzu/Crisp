import XCTest

/// Headless tests for the monitor quirks database's decision core.
///
/// `MonitorQuirks` is compiled directly into this test target (see `project.yml`
/// sources, same route as `DDCServiceMatcher` and `DisplayStateDocument`), so no
/// `@testable import Crisp` is needed — that would pull IOKit and the private
/// bridging header and defeat headless purity. The bundle/file half lives in
/// `MonitorQuirksService` and is deliberately not exercised here: it holds no
/// decisions. Each test names the mutation it is designed to kill.
final class MonitorQuirksTests: XCTestCase {

    // MARK: - Identity parsing

    /// Monitor ids get written down three ways in the wild: `crispctl list` and
    /// EDID dumps print hex with a prefix, bug reports drop the prefix, and
    /// `system_profiler` prints decimal. All three have to parse, and a bare
    /// decimal must be read as decimal (2513 ≠ 0x2513).
    /// Kills mutation: parsing everything as hex, or everything as decimal.
    func testIDParsingAcceptsHexAndDecimalForms() {
        XCTAssertEqual(MonitorQuirkKey.parseID("0x09D1"), 2513)
        XCTAssertEqual(MonitorQuirkKey.parseID("09D1"), 2513)
        XCTAssertEqual(MonitorQuirkKey.parseID("2513"), 2513)
        XCTAssertEqual(MonitorQuirkKey.parseID(" 0x8075 "), 32885)
        XCTAssertNil(MonitorQuirkKey.parseID("not-an-id"))
        XCTAssertNil(MonitorQuirkKey.parseID(""))
    }

    // MARK: - Parsing

    /// The full happy path: a file decodes into a keyed model with ranges, input
    /// values and workarounds intact.
    /// Kills mutation: dropping any single field from the decoder.
    func testParsesCompleteVendorFile() throws {
        let file = try XCTUnwrap(decode(benqJSON))
        XCTAssertEqual(file.vendor, 0x09D1)
        XCTAssertEqual(file.vendorName, "BenQ")
        XCTAssertEqual(file.problems, [])

        let model = try XCTUnwrap(file.models.first)
        XCTAssertEqual(model.key, MonitorQuirkKey(vendor: 0x09D1, product: 0x8075))
        XCTAssertEqual(model.modelName, "MA320U")
        XCTAssertEqual(model.confidence, .verified)
        XCTAssertEqual(model.feature(.contrast)?.range, QuirkRange(min: 0, max: 100))
        XCTAssertEqual(model.feature(.volume)?.range, QuirkRange(min: 0, max: 50))
        XCTAssertEqual(model.inputValue(for: 19)?.label, "USB-C")
        XCTAssertEqual(model.workarounds.writeDelayMs, 80)
        XCTAssertTrue(model.workarounds.saveAfterWrite)
        XCTAssertFalse(model.workarounds.revertsAfterWrite)
    }

    /// Confidence inherits model → feature → value, and each level may narrow it.
    /// This is the whole reason the MA320U can be `verified` for contrast and
    /// `reported` for its input mapping in one entry.
    /// Kills mutation: reading confidence only at the model level, or only at the
    /// value level (either collapses the three into one).
    func testConfidenceInheritsAndNarrowsPerLevel() throws {
        let file = try XCTUnwrap(decode(benqJSON))
        let model = try XCTUnwrap(file.models.first)

        XCTAssertEqual(model.confidence, .verified)
        // Feature inherits the verified model default…
        XCTAssertEqual(model.feature(.contrast)?.confidence, .verified)
        // …while `input` narrows it to reported…
        XCTAssertEqual(model.feature(.input)?.confidence, .reported)
        // …and code 33 narrows further still, back up to verified.
        XCTAssertEqual(model.inputValue(for: 19)?.confidence, .reported)
        XCTAssertEqual(model.inputValue(for: 33)?.confidence, .verified)
    }

    /// `input` is the one feature that never inherits confidence. A contributor
    /// who marks the model `verified` after confirming brightness/contrast/volume
    /// and forgets to re-declare `reported` on `input` would otherwise promote
    /// guessed input codes past the confirmation dialog — the single mistake in
    /// this database that costs somebody their screen, and the reason this is
    /// enforced in the decoder rather than in the README.
    /// Kills mutation: letting `input` inherit the model confidence, or letting a
    /// value inherit the feature's — either one makes one careless line at the
    /// top of a file promote every code below it.
    func testInputConfidenceIsNeverInheritedFromAboveIt() throws {
        let model = try XCTUnwrap(decode("""
        { "vendor": "0x1", "confidence": "verified", "models": [
          { "product": "0x2", "confidence": "verified", "features": {
            "contrast": { "range": [0, 100] },
            "input": { "values": [
              { "code": 19, "label": "USB-C" },
              { "code": 33, "label": "HDMI-1", "confidence": "verified" } ] } } } ] }
        """)?.models.first)

        // Contrast still inherits `verified` — only `input` is capped.
        XCTAssertEqual(model.confidence, .verified)
        XCTAssertEqual(model.feature(.contrast)?.confidence, .verified)
        XCTAssertEqual(model.feature(.input)?.confidence, .reported)
        XCTAssertEqual(model.inputValue(for: 19)?.confidence, .reported)
        // Declaring it on the code itself is still the way to reach verified.
        XCTAssertEqual(model.inputValue(for: 33)?.confidence, .verified)

        // What that means where it counts: the undeclared code keeps its dialog.
        let inherited = MonitorQuirkResolver.input(
            code: 19, quirks: model, currentInput: nil, userSelectedInput: nil
        )
        XCTAssertTrue(inherited.needsConfirmation)
        XCTAssertEqual(inherited.displayLabel, "USB-C?")
        XCTAssertFalse(
            MonitorQuirkResolver.input(
                code: 33, quirks: model, currentInput: nil, userSelectedInput: nil
            ).needsConfirmation
        )
    }

    /// Even an explicit `"confidence": "verified"` on the `input` *feature* does
    /// not carry down to a code that did not claim it. A feature-wide claim is
    /// one assertion; a port map is one assertion per port, and each has to be
    /// switched to and back from before it can be called verified.
    /// Kills mutation: capping only the model→feature step and letting the
    /// feature→value step through.
    func testFeatureLevelVerifiedDoesNotPromoteUndeclaredInputCodes() throws {
        let model = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2", "features": {
          "input": { "confidence": "verified", "values": [
            { "code": 19, "label": "USB-C" } ] } } } ] }
        """)?.models.first)

        XCTAssertEqual(model.inputValue(for: 19)?.confidence, .reported)
        XCTAssertTrue(
            MonitorQuirkResolver.input(
                code: 19, quirks: model, currentInput: nil, userSelectedInput: nil
            ).needsConfirmation
        )
    }

    /// A file written by a later build must still load everything this build
    /// understands, so an unrecognised feature name is skipped, not rejected.
    /// Kills mutation: throwing on an unknown feature key (would drop the model).
    func testUnknownFeatureNameIsIgnoredNotFatal() throws {
        let json = """
        { "vendor": "0x1234", "models": [ { "product": "0x1",
          "features": { "contrast": { "range": [0, 100] }, "warpFactor": { "range": [0, 10] } } } ] }
        """
        let model = try XCTUnwrap(decode(json)?.models.first)
        XCTAssertNotNil(model.feature(.contrast))
        XCTAssertEqual(model.features.count, 1)
    }

    /// The schema describes **any** registry feature, not the four that happened
    /// to be hand-coded first. `sharpness` was an unknown name until the registry
    /// existed; a contributor can now write down what they measured for it, which
    /// is the whole point of making a VCP code a data change.
    /// Kills mutation: hard-coding the decoder's feature names back to the four.
    func testAnyRegistryFeatureCanBeDescribed() throws {
        let json = """
        { "vendor": "0x1234", "models": [ { "product": "0x1", "confidence": "verified",
          "features": {
            "sharpness": { "range": [0, 10] },
            "videoGainRed": { "range": [0, 100] },
            "powerMode": { "confidence": "verified" }
          } } ] }
        """
        let model = try XCTUnwrap(decode(json)?.models.first)
        XCTAssertEqual(model.feature(.sharpness)?.range, QuirkRange(min: 0, max: 10))
        XCTAssertEqual(model.feature(.videoGainRed)?.range, QuirkRange(min: 0, max: 100))
        XCTAssertEqual(model.feature(.sharpness)?.confidence, .verified,
                       "a harmless feature still inherits the model's confidence")
    }

    /// The confidence cap generalises with the registry: every destructive
    /// feature, not just `input`, refuses to inherit `verified` from the model.
    /// 0xD6 value 5 turns the panel off and 0x04 wipes the monitor's settings —
    /// the same "one careless line costs somebody their screen" argument that put
    /// the cap on `input` in the first place.
    /// Kills mutation: keying the cap on `feature == .input` instead of on the
    /// registry's `destructive` flag.
    func testDestructiveFeaturesNeverInheritVerifiedConfidence() throws {
        let json = """
        { "vendor": "0x1234", "models": [ { "product": "0x1", "confidence": "verified",
          "features": {
            "powerMode": {}, "restoreFactoryDefaults": {}, "osdControl": {},
            "colorPreset": {}, "sharpness": {}
          } } ] }
        """
        let model = try XCTUnwrap(decode(json)?.models.first)
        for feature in [QuirkFeatureName.powerMode, .restoreFactoryDefaults, .osdControl, .colorPreset] {
            XCTAssertEqual(model.feature(feature)?.confidence, .reported,
                           "\(feature.rawValue) is destructive and must not inherit verified")
        }
        XCTAssertEqual(model.feature(.sharpness)?.confidence, .verified,
                       "and the cap must not spread to features that cost nothing")
    }

    // MARK: - Malformed input is skipped, never thrown

    /// Invalid JSON returns nil plus the reason instead of throwing at the caller
    /// (AGENTS.md rule #4 — nothing about this may take the app down).
    /// Kills mutation: `try!` in `decoding`, or swallowing the error so the loader
    /// cannot log which file was bad.
    func testMalformedJSONYieldsNilAndAReason() {
        let (file, failure) = MonitorQuirksFile.decoding(Data("{ not json at all".utf8))
        XCTAssertNil(file)
        XCTAssertNotNil(failure)
    }

    /// A file missing the one mandatory field, and one whose vendor id is
    /// unparseable, both fail as a whole — there is nothing to key entries on.
    /// Kills mutation: defaulting an unparseable vendor to 0, which would file
    /// every such model under one bogus vendor and mis-match real monitors.
    func testFileWithUnusableVendorIsRejected() {
        XCTAssertNil(decode(#"{ "models": [] }"#))
        XCTAssertNil(decode(#"{ "vendor": "banana", "models": [] }"#))
    }

    /// One broken model must cost only itself: the siblings around it still load
    /// and the reason is recorded for the log. Covers all three ways an entry can
    /// be individually bad — unparseable product id, inverted range, wrong-shaped
    /// range — and pins that a *later* good entry survives an earlier failure
    /// (the decoder has to keep consuming the array).
    /// Kills mutation: `try container.decode([RawModel].self)` without the lenient
    /// wrapper, which throws on the first bad element and loses the whole file.
    func testBrokenModelIsSkippedAndSiblingsSurvive() throws {
        let json = """
        { "vendor": "0x1234", "vendorName": "Test", "models": [
          { "product": "0x1", "name": "Good One" },
          { "product": "banana", "name": "Bad Id" },
          { "product": "0x2", "name": "Bad Range", "features": { "contrast": { "range": [100, 0] } } },
          { "product": "0x3", "name": "Short Range", "features": { "contrast": { "range": [5] } } },
          { "product": "0x4", "name": "Good Two" }
        ] }
        """
        let file = try XCTUnwrap(decode(json))
        XCTAssertEqual(file.models.map(\.modelName), ["Good One", "Good Two"])
        XCTAssertEqual(file.problems.count, 3)
    }

    /// A model with no `confidence` is `reported`, never `verified`. An omitted
    /// field is an absence of evidence, and the safe reading of no evidence is
    /// "nobody checked".
    /// Kills mutation: defaulting the model confidence to `.verified`, which
    /// would let an under-specified contribution switch inputs without asking.
    func testMissingConfidenceDefaultsToReported() throws {
        let model = try XCTUnwrap(decode(#"{ "vendor": "0x1", "models": [ { "product": "0x2" } ] }"#)?.models.first)
        XCTAssertEqual(model.confidence, .reported)
    }

    // MARK: - Merging vendor files

    /// Two vendor files merge into one database, each model reachable under its
    /// own vendor+product.
    /// Kills mutation: a merge that replaces the accumulator instead of adding to
    /// it (only the last file would survive).
    func testMergingMultipleVendorFilesKeepsEveryModel() throws {
        let benq = try XCTUnwrap(decode(benqJSON))
        let other = try XCTUnwrap(decode("""
        { "vendor": "0x4C2D", "vendorName": "Samsung", "models": [
          { "product": "0x0F30", "name": "U32H750", "confidence": "reported" } ] }
        """))

        let (database, problems) = MonitorQuirksDatabase.merging([benq, other])
        XCTAssertEqual(database.count, 2)
        XCTAssertEqual(database.quirks(vendor: 0x09D1, product: 0x8075)?.modelName, "MA320U")
        XCTAssertEqual(database.quirks(vendor: 0x4C2D, product: 0x0F30)?.modelName, "U32H750")
        XCTAssertEqual(problems, [])
    }

    /// An unknown vendor or an unknown product of a known vendor produces no
    /// quirks at all — the normal case, and the one where the app must behave
    /// exactly as it did before this database existed.
    /// Kills mutation: matching on vendor alone, which would hand one BenQ
    /// model's input map to every other BenQ.
    func testUnknownMonitorResolvesToNoQuirks() throws {
        let (database, _) = MonitorQuirksDatabase.merging([try XCTUnwrap(decode(benqJSON))])
        XCTAssertNil(database.quirks(vendor: 0x09D1, product: 0x9999))
        XCTAssertNil(database.quirks(vendor: 0xFFFF, product: 0x8075))
    }

    /// Duplicate models are resolved by evidence, not load order: `verified` wins
    /// from either side, and two equal claims keep the first. Both orders are
    /// checked, which is what makes this about evidence rather than position.
    /// Kills mutation: last-writer-wins (case (a) flips), first-writer-wins
    /// (case (b) flips), or dropping the equal-confidence stability (case (c)).
    func testDuplicateModelResolvesByConfidenceNotOrder() throws {
        let reported = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2", "name": "Reported", "confidence": "reported" } ] }
        """))
        let verified = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2", "name": "Verified", "confidence": "verified" } ] }
        """))
        let secondVerified = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2", "name": "Verified Two", "confidence": "verified" } ] }
        """))

        // (a) verified arrives second → it replaces the reported entry.
        let (a, aProblems) = MonitorQuirksDatabase.merging([reported, verified])
        XCTAssertEqual(a.quirks(vendor: 1, product: 2)?.modelName, "Verified")
        XCTAssertEqual(aProblems.count, 1, "a replaced duplicate is still worth logging")

        // (b) verified arrives first → the later reported entry must not win.
        let (b, _) = MonitorQuirksDatabase.merging([verified, reported])
        XCTAssertEqual(b.quirks(vendor: 1, product: 2)?.modelName, "Verified")

        // (c) equal confidence → first file wins, deterministically.
        let (c, _) = MonitorQuirksDatabase.merging([verified, secondVerified])
        XCTAssertEqual(c.quirks(vendor: 1, product: 2)?.modelName, "Verified")
    }

    // MARK: - Resolution priority

    /// The documented order — user override → database → probe → MCCS standard —
    /// checked one tier at a time by removing the tier above it.
    /// Kills mutation: any reordering, in particular letting the live probe beat
    /// the database (a monitor that misreports its own maximum is the reason the
    /// database exists).
    func testRangeResolutionFollowsPriorityOrder() throws {
        let quirks = try XCTUnwrap(decode(benqJSON)?.models.first)
        let dell = try XCTUnwrap(QuirkRange(min: 30, max: 50))
        let standard = try XCTUnwrap(QuirkRange(min: 0, max: 100))

        // 1. user override beats everything below it.
        let user = MonitorQuirkResolver.range(
            .contrast, quirks: quirks, userOverride: dell, probeMax: 255, standard: standard
        )
        XCTAssertEqual(user.source, .userOverride)
        XCTAssertEqual(user.value, dell)

        // 2. database beats the live probe.
        let database = MonitorQuirkResolver.range(
            .contrast, quirks: quirks, probeMax: 255, standard: standard
        )
        XCTAssertEqual(database.source, .database)
        XCTAssertEqual(database.value, QuirkRange(min: 0, max: 100))

        // 3. probe beats the MCCS default when the database is silent about the
        //    feature (this file has no brightness entry for that model's sibling).
        let probe = MonitorQuirkResolver.range(
            .brightness, quirks: nil, probeMax: 255, standard: standard
        )
        XCTAssertEqual(probe.source, .probe)
        XCTAssertEqual(probe.value, QuirkRange(min: 0, max: 255))

        // 4. nothing known at all → MCCS default, and it is not claimed as fact.
        let fallback = MonitorQuirkResolver.range(
            .brightness, quirks: nil, probeMax: nil, standard: standard
        )
        XCTAssertEqual(fallback.source, .standard)
        XCTAssertEqual(fallback.confidence, .reported)
    }

    /// A monitor that answers a 0 maximum is broken, not a monitor with a
    /// zero-wide range: fall through to the standard instead of building a range
    /// that divides by zero.
    /// Kills mutation: accepting `probeMax == 0` as a valid probe tier.
    func testZeroProbeMaxFallsThroughToStandard() throws {
        let standard = try XCTUnwrap(QuirkRange(min: 0, max: 100))
        let resolved = MonitorQuirkResolver.range(.contrast, quirks: nil, probeMax: 0, standard: standard)
        XCTAssertEqual(resolved.source, .standard)
    }

    /// Percent↔raw has to carry both ends of the range, or every monitor with a
    /// non-zero floor (Dell 2407wfp: 30–50) is driven into the part of its dial
    /// it ignores.
    /// Kills mutation: `percent / 100 * max`, which maps 0% to raw 0 (dead zone)
    /// and 50% to raw 25 instead of 40.
    func testRangeMathHonoursANonZeroMinimum() throws {
        let dell = try XCTUnwrap(QuirkRange(min: 30, max: 50))
        XCTAssertEqual(dell.raw(forPercent: 0), 30)
        XCTAssertEqual(dell.raw(forPercent: 50), 40)
        XCTAssertEqual(dell.raw(forPercent: 100), 50)
        XCTAssertEqual(dell.percent(forRaw: 40), 50, accuracy: 0.001)
        // Out-of-range input is clamped, never wrapped: UInt16 arithmetic on a
        // negative percent would trap.
        XCTAssertEqual(dell.raw(forPercent: -20), 30)
        XCTAssertEqual(dell.raw(forPercent: 400), 50)
        XCTAssertEqual(dell.percent(forRaw: 0), 0, accuracy: 0.001)
    }

    /// An inverted or empty range is contributor error and must be rejected, not
    /// silently swapped into something plausible.
    /// Kills mutation: sorting the two ends in the initializer.
    func testInvertedRangeIsRejected() {
        XCTAssertNil(QuirkRange(min: 50, max: 30))
        XCTAssertNil(QuirkRange(min: 10, max: 10))
    }

    /// Write spacing comes from the quirk row when it has one, and from the MCCS
    /// default otherwise. A zero or negative delay in a file is ignored rather
    /// than obeyed — flooding the I2C bus that brightness shares is exactly the
    /// failure this pacing exists to prevent.
    /// Kills mutation: `?? standard` alone, which would accept a `0` from a file.
    func testWriteDelayFallsBackToTheStandardSpacing() throws {
        let quirks = try XCTUnwrap(decode(benqJSON)?.models.first)
        XCTAssertEqual(MonitorQuirkResolver.writeDelayMs(quirks: quirks, standard: 50), 80)
        XCTAssertEqual(MonitorQuirkResolver.writeDelayMs(quirks: nil, standard: 50), 50)

        let zeroDelay = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2", "workarounds": { "writeDelayMs": 0 } } ] }
        """)?.models.first)
        XCTAssertEqual(MonitorQuirkResolver.writeDelayMs(quirks: zeroDelay, standard: 50), 50)
    }

    /// An absurd write delay from a contributed file is dropped at the edge, the
    /// way `range` and input `code` already are, and the model around it still
    /// loads. `50_000_000_000` is the shape of the mistake this guards against —
    /// a ms/ns units mix-up — and the pump multiplies this value by 1_000_000 to
    /// reach nanoseconds, where Swift's `*` traps on overflow. A stranger's pull
    /// request must not be able to crash the app on the first slider drag.
    /// Kills mutation: carrying `writeDelayMs` through unbounded, or bounding it
    /// by dropping the whole model (which would also lose its good range data).
    func testAbsurdWriteDelayIsRejectedAndTheModelSurvives() throws {
        let model = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2", "name": "Fat Finger",
          "features": { "contrast": { "range": [0, 100] } },
          "workarounds": { "writeDelayMs": 50000000000 } } ] }
        """)?.models.first)

        XCTAssertNil(model.workarounds.writeDelayMs, "an unusable delay must not propagate")
        XCTAssertEqual(MonitorQuirkResolver.writeDelayMs(quirks: model, standard: 50), 50)
        XCTAssertEqual(model.feature(.contrast)?.range, QuirkRange(min: 0, max: 100),
                       "the rest of the entry is still usable")

        // The bound itself: the largest accepted value is kept, one past it is not.
        let accepted = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2",
          "workarounds": { "writeDelayMs": \(QuirkWorkarounds.maxWriteDelayMs) } } ] }
        """)?.models.first)
        XCTAssertEqual(accepted.workarounds.writeDelayMs, QuirkWorkarounds.maxWriteDelayMs)

        let refused = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2",
          "workarounds": { "writeDelayMs": \(QuirkWorkarounds.maxWriteDelayMs + 1) } } ] }
        """)?.models.first)
        XCTAssertNil(refused.workarounds.writeDelayMs)

        // Negative delays are nonsense in the same way and go the same route,
        // and `UInt64(exactly:)` at the call site would refuse them anyway.
        let negative = try XCTUnwrap(decode("""
        { "vendor": "0x1", "models": [ { "product": "0x2", "workarounds": { "writeDelayMs": -1 } } ] }
        """)?.models.first)
        XCTAssertNil(negative.workarounds.writeDelayMs)
    }

    // MARK: - Input labels

    /// Label resolution: database first, then the MCCS table, then the bare code.
    /// Kills mutation: consulting the MCCS table first, which would label the
    /// MA320U's code 19 "DVI-10" on a monitor that has no DVI port at all.
    func testInputLabelPrefersTheDatabaseOverTheMCCSTable() throws {
        let quirks = try XCTUnwrap(decode(benqJSON)?.models.first)

        let known = MonitorQuirkResolver.input(code: 19, quirks: quirks, currentInput: nil, userSelectedInput: nil)
        XCTAssertEqual(known.label, "USB-C")
        XCTAssertEqual(known.labelSource, .database)

        // A code the database does not cover still gets the standard table…
        let standard = MonitorQuirkResolver.input(code: 0x20, quirks: quirks, currentInput: nil, userSelectedInput: nil)
        XCTAssertEqual(standard.label, "HDMI-1")
        XCTAssertEqual(standard.labelSource, .standard)

        // …and a code neither knows falls back to the raw number, which is honest
        // rather than wrong, so it is not marked unconfirmed.
        let unknown = MonitorQuirkResolver.input(code: 200, quirks: nil, currentInput: nil, userSelectedInput: nil)
        XCTAssertEqual(unknown.label, "200")
        XCTAssertEqual(unknown.displayLabel, "200")
        XCTAssertEqual(unknown.labelConfidence, .verified)
    }

    // MARK: - `reported` is never silently treated as `verified`

    /// The core safety contract. A `reported` label is shown with a question mark
    /// and requires confirmation before it is written to VCP 0x60; a `verified`
    /// one is shown as fact and switched to directly.
    /// Kills mutation: treating any database hit as authoritative (the reported
    /// case flips to no confirmation), or dropping the `?` marker (the app would
    /// state a stranger's guess as fact).
    func testReportedInputIsMarkedAndGatedWhileVerifiedIsNot() throws {
        let quirks = try XCTUnwrap(decode(benqJSON)?.models.first)

        let reported = MonitorQuirkResolver.input(code: 19, quirks: quirks, currentInput: nil, userSelectedInput: nil)
        XCTAssertEqual(reported.labelConfidence, .reported)
        XCTAssertEqual(reported.switchConfidence, .reported)
        XCTAssertTrue(reported.needsConfirmation)
        XCTAssertEqual(reported.displayLabel, "USB-C?")
        XCTAssertNotNil(reported.notes, "a reported entry carries the reason it is unconfirmed")

        let verified = MonitorQuirkResolver.input(code: 33, quirks: quirks, currentInput: nil, userSelectedInput: nil)
        XCTAssertEqual(verified.switchConfidence, .verified)
        XCTAssertFalse(verified.needsConfirmation)
        XCTAssertEqual(verified.displayLabel, "HDMI-1")
    }

    /// The MCCS table is a specification's claim about a monitor, not a
    /// measurement, so a generic VESA code the database says nothing about is
    /// gated too. Otherwise the database would make guesses *safer-looking*
    /// than the guesses it replaced.
    /// Kills mutation: stamping the standard tier `verified`.
    func testUnbackedStandardCodeStillNeedsConfirmation() {
        let guess = MonitorQuirkResolver.input(code: 0x21, quirks: nil, currentInput: 0x20, userSelectedInput: nil)
        XCTAssertEqual(guess.label, "HDMI-2")
        XCTAssertTrue(guess.needsConfirmation)
        XCTAssertEqual(guess.displayLabel, "HDMI-2?")
    }

    /// Two codes are provably safe to write regardless of what the database says:
    /// the one the monitor is on right now (writing it is a no-op) and the one
    /// the user picked themselves last time (their screen came back). Their
    /// *labels* stay unconfirmed — those are different questions.
    /// Kills mutation: deriving `switchConfidence` from `labelConfidence`, which
    /// would make the current input un-selectable without a dialog; or promoting
    /// the label because the code is safe, which would state a guess as fact.
    func testCurrentAndUserSelectedCodesAreSafeButKeepTheirLabelConfidence() throws {
        let quirks = try XCTUnwrap(decode(benqJSON)?.models.first)

        let current = MonitorQuirkResolver.input(code: 19, quirks: quirks, currentInput: 19, userSelectedInput: nil)
        XCTAssertFalse(current.needsConfirmation)
        XCTAssertEqual(current.labelConfidence, .reported)
        XCTAssertEqual(current.displayLabel, "USB-C?")

        let chosen = MonitorQuirkResolver.input(code: 19, quirks: quirks, currentInput: 0x20, userSelectedInput: 19)
        XCTAssertFalse(chosen.needsConfirmation)
        XCTAssertEqual(chosen.labelConfidence, .reported)
    }

    // MARK: - Menu options

    /// A model whose port list a contributor declared *complete* shows the
    /// current input first, then that model's real ports, and nothing else.
    /// Padding a fully mapped model with generic VESA codes would put back
    /// exactly the wrong guesses the database exists to remove.
    /// Kills mutation: always appending the common codes, or sorting the options
    /// (which would drop the current input out of first place).
    func testCompleteInputListReplacesTheGenericCodes() throws {
        let quirks = try XCTUnwrap(decode(completeInputJSON)?.models.first)
        let options = MonitorQuirkResolver.inputOptions(quirks: quirks, currentInput: 33, userSelectedInput: nil)
        XCTAssertEqual(options.map(\.code), [33, 19], "current first, then the model's other known port")
        XCTAssertFalse(options[0].needsConfirmation)
        XCTAssertTrue(options[1].needsConfirmation)
    }

    /// A *partial* map is the normal state of a contribution in progress — the
    /// MA320U has one inferred code and four physical ports — so the generic
    /// codes stay. Otherwise adding a single label to the database would take
    /// input switching away from the user instead of improving it.
    /// Kills mutation: `complete` defaulting to true, or `inputOptions` deciding
    /// completeness from `values.isEmpty` (the bug this test was written for).
    func testPartialInputMapKeepsTheGenericCodes() throws {
        let quirks = try XCTUnwrap(decode(benqJSON)?.models.first)
        XCTAssertFalse(quirks.hasCompleteInputList)

        let options = MonitorQuirkResolver.inputOptions(quirks: quirks, currentInput: 19, userSelectedInput: nil)
        XCTAssertEqual(options.first?.displayLabel, "USB-C?", "the database still supplies the label")
        XCTAssertTrue(options.contains { $0.code == 0x20 }, "and the generic codes are still reachable")
        XCTAssertEqual(options.count, Set(options.map(\.code)).count, "codes must be unique")
    }

    /// A monitor nobody has contributed still gets the old behaviour: the current
    /// code first, then the common VESA codes, deduplicated.
    /// Kills mutation: dropping the standard fallback (an unknown monitor would
    /// have exactly one selectable input), or forgetting to deduplicate (the
    /// current code would appear twice and `ForEach(id: \.code)` would break).
    func testInputOptionsForAnUnknownModelFallBackToTheCommonCodes() {
        let options = MonitorQuirkResolver.inputOptions(quirks: nil, currentInput: 0x20, userSelectedInput: nil)
        XCTAssertEqual(options.first?.code, 0x20)
        XCTAssertEqual(options.count, Set(options.map(\.code)).count, "codes must be unique")
        XCTAssertEqual(options.count, MCCSInputTable.commonCodes.count, "current code 0x20 is already common")
        XCTAssertTrue(options.contains { $0.code == 0x14 })
    }

    // MARK: - Fixtures

    /// Shaped like the real `Crisp/Resources/quirks/benq.json`, with two extra
    /// things the shipped file has no evidence for — a verified second input and
    /// a write delay — so the inheritance and workaround paths have something to
    /// bite on without inventing facts about the user's hardware.
    private let benqJSON = """
    {
      "schemaVersion": 1,
      "vendor": "0x09D1",
      "vendorName": "BenQ",
      "models": [
        {
          "product": "0x8075",
          "name": "MA320U",
          "confidence": "verified",
          "features": {
            "contrast": { "range": [0, 100] },
            "volume": { "range": [0, 50] },
            "input": {
              "confidence": "reported",
              "values": [
                { "code": 19, "label": "USB-C", "notes": "Inferred, not switched." },
                { "code": 33, "label": "HDMI-1", "confidence": "verified" }
              ]
            }
          },
          "workarounds": { "writeDelayMs": 80, "saveAfterWrite": true }
        }
      ]
    }
    """

    /// Same model with its port list declared complete, for the branch where the
    /// database has earned the right to replace the generic VESA codes.
    private let completeInputJSON = """
    { "vendor": "0x09D1", "models": [ { "product": "0x8075", "confidence": "verified",
      "features": { "input": { "confidence": "reported", "complete": true, "values": [
        { "code": 19, "label": "USB-C" },
        { "code": 33, "label": "HDMI-1", "confidence": "verified" } ] } } } ] }
    """

    private func decode(_ json: String) -> MonitorQuirksFile? {
        MonitorQuirksFile.decoding(Data(json.utf8)).file
    }
}
