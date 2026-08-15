import XCTest

/// Headless tests for the v4 half of `displays.json`: the `tvDevices` list and
/// the per-display binding that joins a `CGDirectDisplay` to a device on the LAN.
///
/// The properties here are the ones a rollback or a hand edit can break, and the
/// one that matters most is negative: **no credential is ever written to this
/// file.** Each test names the mutation it kills.
final class TVPersistenceTests: XCTestCase {

    private let uuidA = DisplayUUID("37D8832A-2D66-02CA-B9F7-8F30A301B230")

    /// A v3 document upgrades to v4 with everything intact and an empty TV list —
    /// nothing is converted, because nothing in v3 could be.
    /// Kills mutation: rebuilding the document instead of copying it (the
    /// display state would vanish), or leaving `version` at 3 so the file lies
    /// about its own shape forever.
    func testUpgradeFromV3KeepsEverythingAndStampsV4() {
        let json = """
            { "version": 3,
              "displays": { "\(uuidA.rawValue)": { "brightness": 42, "contrast": 60 } },
              "presets": [{ "id": "p1", "name": "Night", "settings": {} }] }
            """
        let (decoded, failure) = DisplayStateDocument.decoding(Data(json.utf8))
        XCTAssertNil(failure)

        let upgraded = DisplayStateMigration.upgraded(decoded)
        XCTAssertEqual(upgraded.version, 4)
        XCTAssertEqual(upgraded.displays[uuidA]?.brightness, 42)
        XCTAssertEqual(upgraded.presets.count, 1)
        XCTAssertTrue(upgraded.tvDevices.isEmpty)
    }

    /// The TV list decodes element-wise, exactly like groups, presets and
    /// schedules: one malformed entry costs that entry.
    /// Kills mutation: decoding `tvDevices` as a plain array, which would fail
    /// the whole document and lose the user's monitor brightness because they
    /// hand-edited one television.
    func testOneMalformedTVDoesNotCostTheDocument() {
        let json = """
            { "version": 4,
              "displays": { "\(uuidA.rawValue)": { "brightness": 42 } },
              "tvDevices": [
                { "id": "uuid:good", "platform": "webOS", "name": "Living room", "host": "10.0.0.9" },
                { "platform": "tizen", "host": "10.0.0.10" },
                { "id": "uuid:alsogood", "platform": "tizen", "name": "Kitchen", "host": "10.0.0.11" }
              ] }
            """
        let (document, failure) = DisplayStateDocument.decoding(Data(json.utf8))
        XCTAssertNil(failure)
        XCTAssertEqual(document.displays[uuidA]?.brightness, 42)
        XCTAssertEqual(document.tvDevices.map(\.id.rawValue), ["uuid:good", "uuid:alsogood"])
    }

    /// Two records for the same television make "which credential is this TV's?"
    /// ambiguous in the Keychain, so the upgrade repairs it — first wins, order
    /// preserved, deterministically.
    /// Kills mutation: skipping the deduplication, or picking an arbitrary
    /// winner (which would rewrite the file on every launch).
    func testDuplicateTVRecordsAreRepairedDeterministically() {
        let document = DisplayStateDocument(
            tvDevices: [
                TVDevice(id: TVDeviceID("uuid:1"), platform: .webOS, name: "First", host: "10.0.0.9"),
                TVDevice(id: TVDeviceID("uuid:1"), platform: .tizen, name: "Second", host: "10.0.0.10"),
                TVDevice(id: TVDeviceID("uuid:2"), platform: .tizen, name: "Other", host: "10.0.0.11")
            ]
        )
        let once = DisplayStateMigration.upgraded(document)
        let twice = DisplayStateMigration.upgraded(once)

        XCTAssertEqual(once.tvDevices.map(\.name), ["First", "Other"])
        XCTAssertEqual(twice, once, "the repair has to be idempotent or the file churns")
    }

    /// The binding is per display and survives a round trip; a display with no TV
    /// bound stores nothing at all.
    /// Kills mutation: writing `"tvDevice": null` for every display, which would
    /// give an entry to displays that have no state and defeat `isEmpty`.
    func testTheDisplayToTVBindingRoundTripsAndIsAbsentByDefault() throws {
        let bound = DisplayState(brightness: 40, tvDevice: TVDeviceID("uuid:lg"))
        let data = try JSONEncoder().encode(bound)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(#""tvDevice":"uuid:lg""#))
        XCTAssertEqual(try JSONDecoder().decode(DisplayState.self, from: data), bound)

        let unbound = try JSONEncoder().encode(DisplayState(brightness: 40))
        XCTAssertFalse(String(data: unbound, encoding: .utf8)?.contains("tvDevice") ?? true)
        XCTAssertTrue(DisplayState().isEmpty)
    }

    /// An empty TV list is omitted rather than written as `[]`.
    /// Kills mutation: always encoding the key, which puts noise in a file this
    /// project asks people to paste into bug reports — and would do so on every
    /// install that has never seen a television.
    func testAnEmptyTVListIsNotWritten() throws {
        let data = try JSONEncoder().encode(DisplayStateDocument(displays: [uuidA: DisplayState(volume: 20)]))
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("tvDevices") ?? true)
    }

    /// **No credential reaches the document.** The whole encoded file is searched,
    /// not just the TV record, because the point is that there is nowhere for one
    /// to go.
    /// Kills mutation: adding a credential field anywhere on the path from a
    /// paired TV to `displays.json` — which would put a bearer token into a file
    /// with ordinary user-readable permissions.
    func testNoCredentialFieldExistsAnywhereInTheDocument() throws {
        let document = DisplayStateDocument(
            displays: [uuidA: DisplayState(brightness: 40, tvDevice: TVDeviceID("uuid:lg"))],
            tvDevices: [
                TVDevice(
                    id: TVDeviceID("uuid:lg"), platform: .webOS, name: "Living room",
                    host: "10.0.0.9", model: "OLED55CX", pairedAt: Date(timeIntervalSince1970: 0)
                )
            ]
        )
        let text = String(data: try JSONEncoder().encode(document), encoding: .utf8) ?? ""
        for forbidden in ["token", "clientKey", "client-key", "secret", "certificate", "fingerprint"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()), "\(forbidden) in displays.json")
        }
    }
}
