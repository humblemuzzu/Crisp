import XCTest

/// Headless tests for the TV feature table and the persisted device record.
///
/// The property this file exists for is the one a user will notice: **Tizen has
/// no remote brightness command, and the app says so instead of pretending.**
/// Asserted over the whole registry rather than at the one call site that renders
/// it, so a future edit to the table cannot quietly turn a disabled control with
/// an explanation into a live-looking control that does nothing.
///
/// Each test names the mutation it is designed to kill.
final class TVDeviceTests: XCTestCase {

    // MARK: - The registry is complete and safe by default

    /// Every case has an entry. The fallback exists for a hole that cannot
    /// happen; this is what stops it happening.
    /// Kills mutation: adding a `TVFeatureID` case without a registry row, which
    /// would silently make it destructive-and-unknown at every gate.
    func testEveryFeatureHasARegistryEntry() {
        for feature in TVFeatureID.allCases {
            let spec = TVFeatureRegistry.spec(for: feature)
            XCTAssertEqual(spec.id, feature)
            XCTAssertFalse(spec.title.isEmpty)
        }
        XCTAssertEqual(TVFeatureRegistry.all.count, TVFeatureID.allCases.count)
    }

    /// A destructive feature carries the sentence the dialog needs, and a
    /// harmless one carries none.
    /// Kills mutation: marking something destructive without a hazard, which
    /// produces a confirmation dialog that says nothing — training the user to
    /// dismiss the one dialog that matters.
    func testDestructiveFeaturesAndOnlyThoseCarryAHazard() {
        for spec in TVFeatureRegistry.all {
            if spec.destructive {
                let hazard = spec.hazard ?? ""
                XCTAssertGreaterThan(hazard.count, 30, "\(spec.id) needs a real hazard sentence")
            } else {
                XCTAssertNil(spec.hazard, "\(spec.id) is not destructive and should carry no hazard")
            }
        }
    }

    /// Power and input are the destructive pair, for the same reasons VCP 0xD6
    /// and 0x60 are. Nothing else is.
    /// Kills mutation: flipping `destructive` on either — which would let a
    /// `crisp://` link a web page opened switch a television to a dead input with
    /// no dialog at all.
    func testExactlyPowerAndInputAreDestructive() {
        let destructive = Set(TVFeatureRegistry.all.filter(\.destructive).map(\.id))
        XCTAssertEqual(destructive, [.power, .input])
    }

    // MARK: - Tizen brightness

    /// **The headline limitation.** Samsung exposes no remote brightness command,
    /// and the app reports it as unavailable *with a reason* rather than
    /// accepting the write and doing nothing.
    /// Kills mutation: returning `.writeOnly` or `.readWrite` for Tizen
    /// brightness, which would give the user a slider that moves and a picture
    /// that does not.
    func testTizenBrightnessIsUnsupportedWithAReason() {
        let support = TVFeatureRegistry.support(.brightness, on: .tizen)
        XCTAssertFalse(support.canWrite)
        XCTAssertFalse(support.canRead)
        XCTAssertEqual(support.unsupportedReason, .tizenHasNoRemoteBrightness)

        let text = support.unsupportedReason?.text ?? ""
        XCTAssertGreaterThan(text.count, 40, "the disabled control needs a real explanation next to it")
        XCTAssertTrue(text.hasSuffix("."), "it is shown to a user, so it reads as a sentence")
    }

    /// LG's is reachable, so the two platforms really do differ here rather than
    /// the whole feature being off.
    /// Kills mutation: disabling brightness for both platforms, which would make
    /// the previous test pass while removing the feature.
    func testWebOSBrightnessIsReachable() {
        XCTAssertTrue(TVFeatureRegistry.support(.brightness, on: .webOS).canWrite)
        XCTAssertTrue(TVFeatureRegistry.support(.brightness, on: .webOS).canRead)
    }

    /// Volume, power and input stay available on Tizen: brightness is the only
    /// thing missing, and losing the rest with it would be a worse answer than a
    /// disabled slider.
    /// Kills mutation: marking the whole Tizen platform unsupported.
    func testTizenKeepsEverythingExceptBrightness() {
        for feature in [TVFeatureID.volume, .mute, .power, .input] {
            XCTAssertTrue(
                TVFeatureRegistry.support(feature, on: .tizen).canWrite,
                "\(feature) must still work on a Samsung TV"
            )
        }
    }

    /// Samsung's current input is genuinely unreadable, and that is reported as a
    /// caveat on a writable feature — not as the feature being missing.
    /// Kills mutation: reporting `.readWrite` for Tizen input, which would let the
    /// UI display a port the app cannot actually know.
    func testTizenInputIsWritableButNotReadable() {
        let support = TVFeatureRegistry.support(.input, on: .tizen)
        XCTAssertTrue(support.canWrite)
        XCTAssertFalse(support.canRead)
        XCTAssertEqual(support.caveat, .tizenInputIsNotReadable)
        XCTAssertNil(support.unsupportedReason, "it is writable, so it is not unsupported")
    }

    // MARK: - The device record

    /// The record round-trips, and a field a newer build wrote survives it.
    /// Kills mutation: dropping the unknown-field bag, which would delete a newer
    /// build's TV settings the first time an older Crisp saved.
    func testDeviceRoundTripsAndKeepsFieldsItDoesNotUnderstand() throws {
        let json = """
            {"id":"uuid:abc","platform":"webOS","name":"Living room","host":"10.0.0.9",
             "model":"OLED55CX","wakeOnLANMac":"aa:bb:cc:dd:ee:ff"}
            """
        let device = try JSONDecoder().decode(TVDevice.self, from: Data(json.utf8))
        XCTAssertEqual(device.id, TVDeviceID("uuid:abc"))
        XCTAssertEqual(device.platform, .webOS)
        XCTAssertEqual(device.unknown["wakeOnLANMac"], .string("aa:bb:cc:dd:ee:ff"))

        let reencoded = try JSONEncoder().encode(device)
        let text = String(data: reencoded, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("wakeOnLANMac"), "a newer build's field must survive a rollback")
    }

    /// A record with no identity, no platform or no host is dropped rather than
    /// decoded into something unusable.
    /// Kills mutation: defaulting `platform`, which would make a TV this build
    /// cannot speak to look like an LG and fail confusingly.
    func testARecordMissingItsThreeRequiredFieldsIsRefused() {
        for json in [
            #"{"platform":"webOS","host":"10.0.0.9"}"#,
            #"{"id":"uuid:abc","host":"10.0.0.9"}"#,
            #"{"id":"uuid:abc","platform":"webOS"}"#,
            #"{"id":"uuid:abc","platform":"vidaa","host":"10.0.0.9"}"#
        ] {
            XCTAssertNil(try? JSONDecoder().decode(TVDevice.self, from: Data(json.utf8)), json)
        }
    }

    /// A nameless TV gets a name, because a device the user cannot recognise is
    /// one they cannot address in a `crisp://` link either.
    /// Kills mutation: dropping `normalized()`, which would leave an empty row in
    /// the panel and an unaddressable device in Shortcuts.
    func testNormalizationGivesANamelessDeviceAName() {
        let unnamed = TVDevice(id: TVDeviceID("uuid:1"), platform: .tizen, name: "   ", host: " 10.0.0.9 ")
        let normalized = unnamed.normalized()
        XCTAssertEqual(normalized.name, TVPlatform.tizen.title)
        XCTAssertEqual(normalized.host, "10.0.0.9")

        let modelled = TVDevice(
            id: TVDeviceID("uuid:2"), platform: .tizen, name: "", host: "h", model: "UE55TU8000"
        ).normalized()
        XCTAssertEqual(modelled.name, "UE55TU8000")
    }

    /// The identity encodes as a bare string, so `displays.json` stays readable
    /// in a bug report.
    /// Kills mutation: letting the synthesised `{"rawValue": …}` wrapper through.
    func testDeviceIDEncodesAsABareString() throws {
        let data = try JSONEncoder().encode(TVDeviceID("uuid:abc"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"uuid:abc\"")
    }

    /// **No credential may ever reach the document.** The struct has no field for
    /// one, which is the mechanism rather than a rule anybody has to remember.
    /// Kills mutation: adding a `token`, `clientKey` or `certificate` property to
    /// `TVDevice` — which would put a bearer credential into a file this project
    /// tells users to paste into bug reports.
    func testTheDeviceRecordHasNoFieldThatCouldHoldACredential() throws {
        let device = TVDevice(
            id: TVDeviceID("uuid:abc"), platform: .webOS, name: "n", host: "h",
            model: "m", pairedAt: Date(timeIntervalSince1970: 0)
        )
        let encoded = try JSONEncoder().encode(device)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
        XCTAssertEqual(Set(object.keys), ["id", "platform", "name", "host", "model", "pairedAt"])
    }
}
