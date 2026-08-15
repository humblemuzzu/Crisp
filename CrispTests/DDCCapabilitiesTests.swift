import XCTest

/// Headless tests for the DDC/CI capabilities-string parser.
///
/// `DDCCapabilities` is compiled directly into this test target (see
/// `project.yml` sources, same route as `DDCServiceMatcher`), so no
/// `@testable import Crisp` is needed — that would pull IOKit and the private
/// bridging header and defeat headless purity.
///
/// **Every string in this file that is described as a capture is verbatim from a
/// real monitor.** That is the only reason the tolerance rules are worth having:
/// each one is a shape some panel's firmware actually emits, not a shape someone
/// imagined it might. Each test names the mutation it is designed to kill.
final class DDCCapabilitiesTests: XCTestCase {

    // MARK: - Fixtures (verbatim captures)

    /// AOC C24G2. No spaces anywhere: `cmds` and every value list are one long
    /// hex run, which is what makes greedy pairing mandatory rather than a nicety.
    private let aocC24G2 = "(prot(monitor)type(lcd)model(C24G2)cmds(010203070C4EF3E3)"
        + "vcp(020405080B0C101214(010506080B)16181A6C6E70ACAEB6C0C6C8C9CA60(010F1112)"
        + "CC(0102030405060708090A0B0D1214161E)D6(0104)DFDC(000B0C0D0E0F10)86(0205)628D(0102)FF)"
        + "mswhql(1)asset_eep(40)mccs_ver(2.2))"

    /// ASUS MG279. `model LCDPB287` — the value is not parenthesized. ddcutil
    /// aborts the whole parse there and consequently loses `cmds`, `vcp` AND
    /// `mccs_ver` out of an otherwise perfect string.
    private let asusMG279 = "(prot(monitor) type(LCD)model LCDPB287 cmds(01 02 03 07 0C F3) "
        + "vcp(02 04 05 08 0B 0C 10 12 14(05 06 08 0B) 16 18 1A 60(11 12 0F 10) 62 6C 6E 70 "
        + "8D(01 02) A8 AC AE B6 C6 C8 C9 D6(01 04) DF) mccs_ver(2.1)asset_eep(32)mpu(01)mswhql(1))"

    /// BenQ MA320U, the monitor this fork was built for, read with
    /// `crispctl capabilities`. Kept whole because of what it proves: the
    /// advertised 0x60 values are `0F 11 12 15`, and the panel is sitting on 19
    /// (0x13) right now. The capabilities string omits the input the monitor is
    /// *currently using*.
    private let benqMA320U = "(prot(monitor)type(LCD)model(MA320U)cmds(01 02 03 07 0C E3 F3)"
        + "vcp(02 04 10 12 13(00 01) 14(04 05 08 0B) 16 18 19 1A 59 5A 5B 5C 5D 5E 5F(00 02 03) "
        + "60(0F 11 12 15) 62 67(00 01) 68(00 01) 69(00 01) 6A(00 01) 72(50 64 77 78 8C A0) "
        + "81(00 01 02) 86(01 02 05) 87 8D(01 02) 94(01 02 03 04 05) 9B 9C 9D 9E 9F A0 AA(01 02 03) "
        + "BE C1 C2 C9 CA(01 02 03) CC(01 02 03 04 05 06 07 09 0A 0B 0D 0E 0F 12 14 1A 1E 1F) "
        + "DC(0A 0F 12 22 23 27 28 32) DF E5 EE(00 01 02) EF(00 01) F0(00 01 02) F6(00 01) "
        + "FD(00 03 04))mswhql(1)asset_eep(40)mccs_ver(2.2))"

    // MARK: - AOC C24G2: greedy hex with no spaces at all

    /// *The whole string parses with no separators anywhere.* Splitting on
    /// whitespace is the obvious tokenizer and it returns exactly one token here.
    /// Kills mutation: tokenizing `vcp()` or `cmds()` on whitespace.
    func testAOCNoSpacesParsesEveryVCPCode() {
        let caps = DDCCapabilities.parse(aocC24G2)
        XCTAssertEqual(caps.validity, .valid)
        XCTAssertEqual(caps.model, "C24G2")
        for code in [UInt8(0x10), 0x12, 0x62, 0x60, 0x14, 0xD6, 0xDF, 0xFF] {
            XCTAssertTrue(caps.advertises(code), "0x\(String(code, radix: 16)) was not found")
        }
        XCTAssertEqual(caps.mccsVersion, MCCSVersion.v22)
    }

    /// *A run that ends at `(` gives the list to its last byte, not its first.*
    /// `…C8C9CA60(01 0F 11 12)` means 0xC8, 0xC9, 0xCA are plain codes and 0x60
    /// owns the input list. Handing the list to the first byte of the run would
    /// attach the monitor's input codes to some unrelated feature.
    /// Kills mutation: assigning the value list to the run's first byte.
    func testAOCValueListBelongsToTheLastByteOfTheRun() {
        let caps = DDCCapabilities.parse(aocC24G2)
        XCTAssertEqual(caps.feature(0x60)?.values.map(\.code), [0x01, 0x0F, 0x11, 0x12])
        XCTAssertEqual(caps.feature(0xCA)?.values.isEmpty, true, "0xCA is a plain code in this run")
        XCTAssertTrue(caps.advertises(0xC9))
        XCTAssertEqual(caps.feature(0xDC)?.values.map(\.code), [0x00, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10])
        XCTAssertTrue(caps.advertises(0xDF), "the byte before the run that owns a list is still a code")
    }

    /// *`cmds` with no spaces yields whole bytes.* `010203070C4EF3E3` is eight
    /// commands; a one-nibble misalignment turns every one of them into garbage.
    /// Kills mutation: parsing hex runs a digit at a time.
    func testAOCCommandsPairGreedily() {
        let caps = DDCCapabilities.parse(aocC24G2)
        XCTAssertEqual(caps.commands, [0x01, 0x02, 0x03, 0x07, 0x0C, 0x4E, 0xF3, 0xE3])
    }

    /// *Unknown fields are kept and do not lower the verdict.* `mswhql` and
    /// `asset_eep` are not in any parser's vocabulary, and the spec's own rule is
    /// that hosts discard unsupported fields — so a string full of them is still
    /// a well-formed string, and this one is `valid`, not `usable`.
    /// Kills mutation: treating an unrecognised segment name as damage.
    func testAOCUnknownSegmentsArePreservedWithoutDegrading() {
        let caps = DDCCapabilities.parse(aocC24G2)
        XCTAssertEqual(caps.validity, .valid)
        XCTAssertEqual(caps.unknownSegments.map(\.name), ["mswhql", "asset_eep"])
        XCTAssertEqual(caps.segment("asset_eep")?.value, "40")
        XCTAssertTrue(caps.diagnostics.contains { $0.contains("mswhql") }, "kept, ignored — and logged")
    }

    // MARK: - ASUS MG279: the segment that costs ddcutil the whole string

    /// *One unparenthesized value costs one segment.* This is the headline test:
    /// `model LCDPB287` must not take `cmds`, `vcp` and `mccs_ver` with it, which
    /// is exactly what it does to ddcutil.
    /// Kills mutation: aborting the scan on the first malformed segment.
    func testASUSUnparenthesizedModelDoesNotLoseTheRestOfTheString() {
        let caps = DDCCapabilities.parse(asusMG279)
        XCTAssertEqual(caps.model, "LCDPB287", "the bare token after `model` is its value")
        XCTAssertEqual(caps.mccsVersion, MCCSVersion.v21, "the field ddcutil loses first")
        XCTAssertEqual(caps.commands, [0x01, 0x02, 0x03, 0x07, 0x0C, 0xF3])
        XCTAssertTrue(caps.advertises(0x10))
        XCTAssertTrue(caps.advertises(0x60))
        XCTAssertEqual(caps.feature(0x60)?.values.map(\.code), [0x11, 0x12, 0x0F, 0x10])
        XCTAssertEqual(caps.validity, .usable, "repaired, so not `valid` — but not lost either")
    }

    /// *A bare value is not mistaken for the next segment's name.* The tell is
    /// what follows: a name is followed by `(`, a value is not. Get this wrong
    /// and `cmds` becomes the value of `model` and the command list disappears.
    /// Kills mutation: treating every bare token as a value, or as a name.
    func testASUSBareValueDoesNotSwallowTheNextSegmentName() {
        let caps = DDCCapabilities.parse(asusMG279)
        XCTAssertNotNil(caps.segment("cmds"))
        XCTAssertNotNil(caps.segment("vcp"))
        XCTAssertEqual(caps.segment("model")?.degraded, true, "the repair is recorded, not hidden")
    }

    // MARK: - BenQ MA320U: the monitor this fork exists for

    /// *The capabilities string omits the input the monitor is on.* Read live
    /// with `crispctl capabilities`: 0x60 advertises `0F 11 12 15`, while VCP
    /// 0x60 reads back 19 (0x13). A UI that greyed out or filtered inputs from
    /// this list would hide the port the user is actually looking through.
    /// Kills nothing in the parser — it pins the fact the discovery rule exists
    /// for, on the hardware this repo was built around.
    func testBenQAdvertisedInputsOmitTheInputItIsCurrentlyUsing() {
        let caps = DDCCapabilities.parse(benqMA320U)
        XCTAssertEqual(caps.validity, .valid)
        XCTAssertEqual(caps.model, "MA320U")
        XCTAssertEqual(caps.feature(0x60)?.values.map(\.code), [0x0F, 0x11, 0x12, 0x15])
        XCTAssertFalse(
            caps.feature(0x60)?.values.contains { $0.code == 0x13 } ?? true,
            "the panel reports input 19 (0x13) and does not advertise it"
        )
        XCTAssertEqual(caps.advertisedCodes.count, 50)
        XCTAssertTrue(caps.advertises(0x87), "sharpness, which Crisp has no control for yet")
    }

    // MARK: - Nesting

    /// *Value lists nest, and nesting is not assumed to be one level deep.* The
    /// Lenovo Legion 27U-10 emits this shape verbatim.
    /// Kills mutation: a single-level value parser, or one that flattens depth.
    func testDeeplyNestedValueListsParse() {
        let caps = DDCCapabilities.parse("(vcp(10 F7(01(01) 02 09(01 02(00 03 04 05 06) 03))))")
        let f7 = caps.feature(0xF7)
        XCTAssertEqual(f7?.values.map(\.code), [0x01, 0x02, 0x09])
        XCTAssertEqual(f7?.values.first?.values.map(\.code), [0x01])
        let nine = f7?.values.last
        XCTAssertEqual(nine?.values.map(\.code), [0x01, 0x02, 0x03])
        XCTAssertEqual(nine?.values.first { $0.code == 0x02 }?.values.map(\.code), [0x00, 0x03, 0x04, 0x05, 0x06])
        XCTAssertTrue(caps.advertises(0x10), "the sibling code is still there")
    }

    /// *Pathological nesting is bounded, not followed.* 2000 open parens is a
    /// wedged controller, not a monitor, and recursing on it overflows the stack.
    /// Kills mutation: removing the depth cap.
    func testPathologicalNestingIsBoundedNotFatal() {
        let bomb = "(vcp(" + String(repeating: "01(", count: 2000) + "))"
        let caps = DDCCapabilities.parse(bomb)
        XCTAssertEqual(caps.validity, .usable)
        XCTAssertTrue(caps.diagnostics.contains { $0.contains("nested deeper") })
    }

    // MARK: - Degenerate input

    /// *The empty string is an answer, not a crash.* The Samsung S32D850 returns
    /// a zero-length capabilities string.
    /// Kills mutation: force-unwrapping or indexing before the empty check.
    func testEmptyStringIsInvalidNotFatal() {
        let caps = DDCCapabilities.parse("")
        XCTAssertEqual(caps.validity, .invalid)
        XCTAssertTrue(caps.isEmpty)
        XCTAssertEqual(caps.raw, "")
        XCTAssertFalse(caps.diagnostics.isEmpty, "an empty result still has to say why")
    }

    /// *A single `(` parses to nothing and takes nothing down.*
    /// Kills mutation: `dropFirst().dropLast()` without checking there are two.
    func testLoneOpenParenIsInvalidNotFatal() {
        let caps = DDCCapabilities.parse("(")
        XCTAssertEqual(caps.validity, .invalid)
        XCTAssertTrue(caps.isEmpty)
    }

    /// *No outer parens at all is normal.* The Apple Cinema Display A1082 omits
    /// them; a parser that requires them gets nothing from that monitor.
    /// Kills mutation: requiring a leading `(`.
    func testMissingOuterParensParsesAnyway() {
        let caps = DDCCapabilities.parse("prot(monitor)type(lcd)vcp(10 12)mccs_ver(2.0)")
        XCTAssertEqual(caps.validity, .valid)
        XCTAssertEqual(caps.protocolName, "monitor")
        XCTAssertTrue(caps.advertises(0x12))
        XCTAssertEqual(caps.mccsVersion, MCCSVersion.v20)
    }

    /// *An unbalanced paren mid-string costs its own segment and no more.* The
    /// scan resumes at the next thing that looks like a segment name, which is
    /// the difference between losing `type` and losing everything after it.
    /// Kills mutation: consuming to the end of the string with no recovery scan.
    func testUnbalancedParenMidStringStillParsesLaterSegments() {
        let caps = DDCCapabilities.parse("(prot(monitor)type(lcd vcp(10 12 62)mccs_ver(2.2)")
        XCTAssertEqual(caps.validity, .usable)
        XCTAssertEqual(caps.protocolName, "monitor", "the segment before the break survives")
        XCTAssertTrue(caps.advertises(0x10), "and so does the one after it")
        XCTAssertTrue(caps.advertises(0x62))
        XCTAssertEqual(caps.mccsVersion, MCCSVersion.v22)
        XCTAssertEqual(caps.segment("type")?.degraded, true)
    }

    /// *The recovery scan resumes at a name, never inside a hex value list.*
    /// `14(01 05)` looks exactly like a segment when read as text, and a recovery
    /// that accepted it would manufacture segments out of the data it is
    /// rescuing.
    /// Kills mutation: dropping the "looks like a name" test from the recovery.
    func testRecoveryDoesNotInventSegmentsOutOfHexValueLists() {
        let caps = DDCCapabilities.parse("(vcp(10 14(01 05) 60(11 12)")
        XCTAssertNil(caps.segment("14"), "a hex token is not a segment name")
        XCTAssertNil(caps.segment("60"))
        XCTAssertTrue(caps.advertises(0x10), "the runaway segment's contents are still parsed")
    }

    /// *Non-ASCII bytes are filtered and flagged, never parsed.*
    /// Kills mutation: parsing raw bytes, or dropping the degradation note.
    func testNonASCIIBytesAreFilteredAndFlagged() {
        let caps = DDCCapabilities.parse("(prot(mon\u{FFFD}itor)vcp(10\u{0007} 12)mccs_ver(2.2))")
        XCTAssertEqual(caps.validity, .usable)
        XCTAssertTrue(caps.diagnostics.contains { $0.contains("non-printable") })
        XCTAssertTrue(caps.advertises(0x10))
        XCTAssertTrue(caps.advertises(0x12))
    }

    /// *An oversized string is capped before parsing.* ddcutil's fixed 2048-byte
    /// accumulator asserts on overflow; that is a real crash vector, and a
    /// monitor that never stops talking must cost a truncated result and nothing
    /// else.
    /// Kills mutation: removing the length cap.
    func testOversizedStringIsCappedAndSurvives() {
        let padding = String(repeating: "AB ", count: 3000)
        let caps = DDCCapabilities.parse("(prot(monitor)vcp(10 12 \(padding))mccs_ver(2.2))")
        XCTAssertEqual(caps.validity, .usable)
        XCTAssertTrue(caps.diagnostics.contains { $0.contains("truncated") })
        XCTAssertTrue(caps.advertises(0x10), "what fitted inside the cap is still parsed")
        XCTAssertGreaterThan(caps.raw.utf8.count, DDCCapabilities.maxLength,
                             "the cap bounds the parse, not the evidence: `raw` stays whole")
    }

    /// *An odd hex run drops its trailing nibble and says so.* Inventing a nibble
    /// would fabricate a VCP code that the monitor never mentioned.
    /// Kills mutation: rounding the run up, or silently dropping it whole.
    func testOddLengthHexRunDropsTheTrailingNibbleWithADiagnostic() {
        let caps = DDCCapabilities.parse("(vcp(101262A))")
        XCTAssertEqual(caps.advertisedCodes, [0x10, 0x12, 0x62])
        XCTAssertEqual(caps.validity, .usable)
        XCTAssertTrue(caps.diagnostics.contains { $0.contains("odd number of hex digits") })
    }

    /// *A lone hex digit is a zero-padded byte.* `9` means 0x09, not nothing.
    /// Kills mutation: requiring pairs and discarding single digits.
    func testSingleHexDigitIsZeroPadded() {
        let caps = DDCCapabilities.parse("(cmds(1 2 F3)vcp(9 10))")
        XCTAssertEqual(caps.commands, [0x01, 0x02, 0xF3])
        XCTAssertEqual(caps.advertisedCodes, [0x09, 0x10])
    }

    /// *An impossible `mccs_ver` is dropped, and drops nothing else.* Monitors
    /// contradict their own feature 0xDF freely, so the field is never truth and
    /// never fatal.
    /// Kills mutation: treating a bad version as a parse failure.
    func testAbsurdMCCSVersionIsIgnoredNotFatal() {
        let caps = DDCCapabilities.parse("(vcp(10 12)mccs_ver(255.255))")
        XCTAssertNil(caps.mccsVersion)
        XCTAssertTrue(caps.advertises(0x12))
        XCTAssertTrue(caps.diagnostics.contains { $0.contains("mccs_ver") })
    }

    /// *Real-world misnamed and vendor-private fields survive.* `UM69cmds` is
    /// the LG 29UM69G's mis-named `cmds`; `vcp_p02` and `vcp_p10` are the NEC
    /// P241W's. None of them may cost the string.
    /// Kills mutation: rejecting a string containing an unknown segment.
    func testMisnamedAndVendorPrivateFieldsSurvive() {
        let caps = DDCCapabilities.parse(
            "(prot(monitor)UM69cmds(01 02)vcp_p02(01)vcp_p10(02)vcpme(01)window1(01)vcp(10 12)mccs_ver(2.1))"
        )
        XCTAssertEqual(caps.validity, .valid)
        XCTAssertTrue(caps.advertises(0x10))
        XCTAssertEqual(caps.mccsVersion, MCCSVersion.v21)
        XCTAssertEqual(
            caps.unknownSegments.map(\.name),
            ["UM69cmds", "vcp_p02", "vcp_p10", "vcpme", "window1"]
        )
    }

    /// *The raw string is carried through untouched.* The report prints it
    /// verbatim because it is the evidence; a parser that returned only its own
    /// reading of a string cannot produce the next bug report about a string.
    /// Kills mutation: storing the sanitized text as `raw`.
    func testRawStringIsPreservedVerbatim() {
        XCTAssertEqual(DDCCapabilities.parse(asusMG279).raw, asusMG279)
    }

    // MARK: - Fragment reassembly

    /// *A zero-data fragment is the only thing that ends the string.* Inferring
    /// completion from "this fragment was short" truncates every monitor that
    /// answers short, and several do.
    /// Kills mutation: ending on `data.count < 32`.
    func testShortFragmentDoesNotEndTheTransfer() {
        var reader = DDCCapabilitiesReader()
        XCTAssertEqual(reader.accept(offset: 0, data: Array("(vcp(".utf8)), .needMore(offset: 5))
        XCTAssertEqual(reader.accept(offset: 5, data: Array("10))".utf8)), .needMore(offset: 9))
        XCTAssertEqual(reader.accept(offset: 9, data: []), .complete)
        XCTAssertEqual(reader.text, "(vcp(10))")
    }

    /// *A reply for the wrong offset is refused.* It is a stale answer to an
    /// earlier request, and appending it silently corrupts the string.
    /// Kills mutation: ignoring the reply's offset field.
    func testMismatchedOffsetFailsRatherThanAppending() {
        var reader = DDCCapabilitiesReader()
        _ = reader.accept(offset: 0, data: Array("(vcp".utf8))
        guard case .failed(let reason) = reader.accept(offset: 0, data: Array("(10)".utf8)) else {
            return XCTFail("a stale fragment must not be appended")
        }
        XCTAssertTrue(reason.contains("offset"))
        XCTAssertEqual(reader.text, "(vcp")
    }

    /// *A zero-filled first fragment means "no capabilities".* The Samsung
    /// S32D850 answers that way; it is an answer, not a failure.
    /// Kills mutation: treating the zero fragment as data and appending NULs.
    func testZeroFilledFirstFragmentEndsTheTransferEmpty() {
        var reader = DDCCapabilitiesReader()
        XCTAssertEqual(reader.accept(offset: 0, data: [UInt8](repeating: 0, count: 32)), .complete)
        XCTAssertTrue(reader.bytes.isEmpty)
        XCTAssertTrue(reader.diagnostics.contains { $0.contains("no capabilities") })
    }

    /// *A monitor that never stops is stopped.* Both the byte cap and the
    /// fragment cap have to hold, because either one alone leaves an unbounded
    /// accumulator — the exact shape of ddcutil's assert.
    /// Kills mutation: removing either cap.
    func testEndlessMonitorIsCappedNotFollowedForever() {
        var reader = DDCCapabilitiesReader()
        var offset: UInt16 = 0
        var outcomes: [DDCCapabilitiesReader.Outcome] = []
        for _ in 0..<(DDCCapabilitiesReader.maxFragments + 10) {
            let outcome = reader.accept(offset: offset, data: [UInt8](repeating: 0x41, count: 32))
            outcomes.append(outcome)
            guard case .needMore(let next) = outcome else { break }
            offset = next
        }
        XCTAssertNotEqual(outcomes.last, DDCCapabilitiesReader.Outcome.needMore(offset: offset),
                          "the loop has to end by itself")
        XCTAssertLessThanOrEqual(reader.bytes.count, DDCCapabilities.maxLength)
    }
}
