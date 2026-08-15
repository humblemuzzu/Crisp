import XCTest

/// Headless tests for the declarative DDC feature registry.
///
/// `DDCFeatureRegistry` is compiled directly into this test target (see
/// `project.yml` sources, same route as `DDCServiceMatcher`), so no
/// `@testable import Crisp` is needed — that would pull IOKit and the private
/// bridging header and defeat headless purity.
///
/// The registry is a table, so most of what can go wrong with it is data going
/// wrong: a duplicated VCP code, a destructive feature that forgot to say so, a
/// feature that exists in the enum and not in the table. Each test names the
/// mutation it is designed to kill in a trailing comment.
final class DDCFeatureRegistryTests: XCTestCase {

    // MARK: - Table integrity

    /// *Totality.* Every `DDCFeatureID` has a real entry. The lookup cannot
    /// return nil by design, so a hole would surface as the fallback entry —
    /// VCP 0x00, read-only, destructive — and silently make a feature unusable
    /// rather than crash. This is the test that stops that being silent.
    /// Kills mutation: deleting any row from `DDCFeatureRegistry.all`.
    func testEveryFeatureHasARegistryEntry() {
        for feature in DDCFeatureID.allCases {
            XCTAssertTrue(feature.spec.isKnown, "\(feature.rawValue) has no registry entry")
            XCTAssertEqual(feature.spec.id, feature, "\(feature.rawValue) maps to the wrong entry")
        }
        XCTAssertEqual(DDCFeatureRegistry.all.count, DDCFeatureID.allCases.count)
    }

    /// *No two features share a VCP code.* The reverse lookup is a dictionary, so
    /// a duplicate would silently make one of the two features unreachable by
    /// code — and, worse, aim two different UIs at one register.
    /// Kills mutation: a copy-pasted row that kept the VCP of the row it came from.
    func testVCPCodesAreUnique() {
        let codes = DDCFeatureRegistry.all.map(\.vcp)
        XCTAssertEqual(Set(codes).count, codes.count, "two registry entries share a VCP code")
    }

    /// *A VCP code round-trips.* `feature(forVCP:)` is what the capabilities
    /// parser and the diagnostics report use to put a name to an advertised code.
    /// Kills mutation: building the reverse index off `id` instead of `vcp`.
    func testReverseLookupFindsTheSameEntry() {
        for spec in DDCFeatureRegistry.all {
            XCTAssertEqual(DDCFeatureRegistry.feature(forVCP: spec.vcp)?.id, spec.id)
        }
    }

    /// *An unclaimed code stays unclaimed.* A real monitor advertises far more
    /// codes than this app knows — the BenQ MA320U advertises 50 — and "unknown"
    /// has to be the answer for the rest rather than a nearby guess.
    /// Kills mutation: a reverse lookup that falls back to some default feature.
    func testUnknownVCPCodeHasNoFeature() {
        XCTAssertNil(DDCFeatureRegistry.feature(forVCP: 0x9B))
        XCTAssertNil(DDCFeatureRegistry.feature(forVCP: 0x00))
    }

    // MARK: - The four that already shipped

    /// *The established VCP codes are exactly what MCCS fixed them at.* These
    /// four numbers are on the wire in every build and in every quirks file; the
    /// registry is now their only definition.
    /// Kills mutation: any transposition of the four codes (0x12/0x62/0x60 are
    /// each one keystroke from another valid code).
    func testEstablishedFeatureCodes() {
        XCTAssertEqual(DDCFeatureID.brightness.spec.vcp, 0x10)
        XCTAssertEqual(DDCFeatureID.contrast.spec.vcp, 0x12)
        XCTAssertEqual(DDCFeatureID.volume.spec.vcp, 0x62)
        XCTAssertEqual(DDCFeatureID.input.spec.vcp, 0x60)
        XCTAssertEqual(DDCFeatureRegistry.established, [.brightness, .contrast, .volume, .input])
    }

    /// *The four keep their on-disk names.* Their raw values are the keys in
    /// every shipped and contributed quirks file, so renaming `input` to
    /// `inputSource` would silently stop loading every existing entry — the
    /// failure mode being that an input map quietly reverts to guesses.
    /// Kills mutation: "tidying" the enum's raw values.
    func testQuirksFileFeatureNamesAreStable() {
        XCTAssertEqual(DDCFeatureID.brightness.rawValue, "brightness")
        XCTAssertEqual(DDCFeatureID.contrast.rawValue, "contrast")
        XCTAssertEqual(DDCFeatureID.volume.rawValue, "volume")
        XCTAssertEqual(DDCFeatureID.input.rawValue, "input")
    }

    /// *The dials are dials and the code sets are code sets.* The write path
    /// clamps a continuous feature through a range and hands a non-continuous one
    /// through untouched; getting the shape wrong is how a clamp goes wrong.
    /// Kills mutation: seeding input or power mode as `.continuous`.
    func testFeatureKinds() {
        XCTAssertTrue(DDCFeatureID.brightness.spec.kind.isContinuous)
        XCTAssertTrue(DDCFeatureID.contrast.spec.kind.isContinuous)
        XCTAssertTrue(DDCFeatureID.volume.spec.kind.isContinuous)
        XCTAssertTrue(DDCFeatureID.sharpness.spec.kind.isContinuous)
        XCTAssertFalse(DDCFeatureID.input.spec.kind.isContinuous)
        XCTAssertFalse(DDCFeatureID.powerMode.spec.kind.isContinuous)
        XCTAssertEqual(DDCFeatureID.brightness.spec.kind, .continuous(defaultMax: 100))
    }

    // MARK: - The safety flags

    /// *The four codes that can cost the user something are marked.* This is the
    /// list from the brief, and it is load-bearing: `destructive` is what puts a
    /// write behind the confirmation gate and what stops a quirks file promoting
    /// a guess to `verified` by inheritance.
    /// Kills mutation: dropping `destructive` from any of these rows.
    func testDestructiveFeaturesAreMarked() {
        for feature in [DDCFeatureID.input, .powerMode, .restoreFactoryDefaults, .colorPreset, .colorTemperature] {
            XCTAssertTrue(feature.spec.destructive, "\(feature.rawValue) must be destructive")
        }
        XCTAssertEqual(DDCFeatureID.input.spec.vcp, 0x60)
        XCTAssertEqual(DDCFeatureID.powerMode.spec.vcp, 0xD6)
        XCTAssertEqual(DDCFeatureID.restoreFactoryDefaults.spec.vcp, 0x04)
        XCTAssertEqual(DDCFeatureID.colorTemperature.spec.vcp, 0x0C)
    }

    /// *0xCA is destructive, and says why.* ddcutil issue #153 documents a
    /// monitor whose OSD and physical buttons were disabled permanently by DDC
    /// commands. It is the reason the whole registry defaults to read-only, so
    /// its own row must not be the one that forgets.
    /// Kills mutation: marking the OSD lock as an ordinary read/write feature.
    func testOSDLockIsDestructiveAndSaysWhy() {
        let spec = DDCFeatureID.osdControl.spec
        XCTAssertEqual(spec.vcp, 0xCA)
        XCTAssertTrue(spec.destructive)
        XCTAssertEqual(spec.hazard?.contains("153"), true, "the hazard text has to cite the case it came from")
    }

    /// *A destructive feature always has something to say to the user.* The
    /// confirmation dialog prints `hazard`; a destructive row with none would put
    /// up a dialog that asks "are you sure?" about nothing in particular.
    /// Kills mutation: making `hazard` optional in practice as well as in type.
    func testEveryDestructiveFeatureCarriesAHazard() {
        for spec in DDCFeatureRegistry.all where spec.destructive {
            XCTAssertNotNil(spec.hazard, "\(spec.id.rawValue) is destructive with no hazard text")
            XCTAssertFalse(spec.hazard?.isEmpty ?? true)
        }
        for spec in DDCFeatureRegistry.all where !spec.destructive {
            XCTAssertNil(spec.hazard, "\(spec.id.rawValue) is harmless and should have nothing to warn about")
        }
    }

    /// *Read-only means read-only.* MCCS marks 0xDF (VCP version) and 0xB6
    /// (display technology) read-only; a write to either is meaningless at best.
    /// Kills mutation: seeding them `.readWrite` "for symmetry".
    func testAccessMatchesMCCS() {
        XCTAssertEqual(DDCFeatureID.vcpVersion.spec.access, .readOnly)
        XCTAssertEqual(DDCFeatureID.displayTechnologyType.spec.access, .readOnly)
        XCTAssertEqual(DDCFeatureID.restoreFactoryDefaults.spec.access, .writeOnly)
        XCTAssertFalse(DDCFeatureID.vcpVersion.spec.access.canWrite)
        XCTAssertFalse(DDCFeatureID.restoreFactoryDefaults.spec.access.canRead)
    }

    /// *The features the brief asked for are all present, at the right codes.*
    /// One assertion per number so a failure names which one moved.
    /// Kills mutation: a transposed nibble anywhere in the seeded table.
    func testSeededMCCSCodes() {
        let expected: [DDCFeatureID: UInt8] = [
            .restoreFactoryDefaults: 0x04, .colorTemperature: 0x0C, .colorPreset: 0x14,
            .videoGainRed: 0x16, .videoGainGreen: 0x18, .videoGainBlue: 0x1A,
            .blackLevelRed: 0x6C, .blackLevelGreen: 0x6E, .blackLevelBlue: 0x70,
            .sharpness: 0x87, .audioMute: 0x8D, .displayTechnologyType: 0xB6,
            .osdControl: 0xCA, .powerMode: 0xD6, .vcpVersion: 0xDF
        ]
        for (feature, code) in expected {
            XCTAssertEqual(feature.spec.vcp, code, "\(feature.rawValue) is at the wrong VCP code")
        }
    }

    /// *`vcpText` is how MCCS spells it.* The diagnostics report and every
    /// monitor's manual use two upper-case hex digits; `0x4` or `0X04` in a bug
    /// report is a string nobody can search for.
    /// Kills mutation: `%x`, or dropping the zero padding.
    func testVCPTextFormatting() {
        XCTAssertEqual(DDCFeatureID.restoreFactoryDefaults.spec.vcpText, "0x04")
        XCTAssertEqual(DDCFeatureID.contrast.spec.vcpText, "0x12")
        XCTAssertEqual(DDCFeatureID.powerMode.spec.vcpText, "0xD6")
    }

    // MARK: - MCCS version

    /// *Version comparison is major-then-minor.* Used to reject a monitor's
    /// impossible `mccs_ver()`; a lexical or float comparison gets 2.10 wrong.
    /// Kills mutation: comparing `major` only, or comparing the description.
    func testMCCSVersionOrdering() {
        XCTAssertTrue(MCCSVersion.v20 < MCCSVersion.v21)
        XCTAssertTrue(MCCSVersion.v22 < MCCSVersion.v30)
        XCTAssertFalse(MCCSVersion.v30 < MCCSVersion.v22)
        XCTAssertEqual(MCCSVersion.v22.description, "2.2")
    }

    /// *Version parsing is lenient and bounded.* Monitors send `2.2`, `2.2a`,
    /// whitespace, a bare major, and versions that do not exist. Only the last
    /// one is refused, because it is the only one that would be believed.
    /// Kills mutation: dropping the `newestPublished` bound, or requiring a dot.
    func testMCCSVersionParsing() {
        XCTAssertEqual(MCCSVersion.parse("2.2"), MCCSVersion.v22)
        XCTAssertEqual(MCCSVersion.parse(" 2.1 "), MCCSVersion.v21)
        XCTAssertEqual(MCCSVersion.parse("2.2a"), MCCSVersion.v22, "VESA's own revision letter")
        XCTAssertEqual(MCCSVersion.parse("2"), MCCSVersion.v20)
        XCTAssertNil(MCCSVersion.parse("255.255"), "no such standard; a monitor saying so is wrong")
        XCTAssertNil(MCCSVersion.parse("4.0"))
        XCTAssertNil(MCCSVersion.parse(""))
        XCTAssertNil(MCCSVersion.parse("lcd"))
    }
}
