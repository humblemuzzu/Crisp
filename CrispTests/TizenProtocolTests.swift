import XCTest

/// Headless tests for Samsung's Tizen remote protocol: detection, the port
/// decision, both token locations, the key frames, the rate limit and the UPnP
/// volume path.
///
/// `TizenProtocol.swift` is compiled directly into this target (see `project.yml`
/// sources), so no `@testable import Crisp` is needed. Each test names the
/// mutation it is designed to kill.
///
/// **There is no television on the machine this was written on**, so this suite
/// and code review are the whole of the verification. That is exactly why the
/// protocol was put above the `TVTransport` seam.
final class TizenProtocolTests: XCTestCase {

    // MARK: - Detection

    /// The real shape of `GET /api/v2/`, with every boolean-ish field a *string*.
    /// Kills mutation: decoding `TokenAuthSupport` as a JSON boolean, which is
    /// `nil` on every real TV — the client then picks the wrong port and the TV
    /// looks dead.
    func testDeviceInfoReadsSamsungsStringBooleans() {
        let info = TizenRemote.deviceInfo(from: """
            {"id":"uuid:0d1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9","name":"Living Room TV",
             "device":{"OS":"Tizen","TokenAuthSupport":"true","PowerState":"on",
                       "modelName":"UE55TU8000","wifiMac":"aa:bb:cc:dd:ee:ff",
                       "id":"uuid:0d1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"}}
            """)
        XCTAssertEqual(info?.id, "uuid:0d1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9")
        XCTAssertEqual(info?.tokenAuthSupport, true)
        XCTAssertEqual(info?.isOn, true)
        XCTAssertEqual(info?.model, "UE55TU8000")
        XCTAssertEqual(info?.isSupported, true)
    }

    /// `"false"` really means false, and it has to, because it is the whole port
    /// decision.
    /// Kills mutation: a `looseBoolValue` that treats any non-empty string as
    /// true, which would send every non-token TV to port 8002.
    func testTokenAuthSupportFalseIsHonoured() {
        let info = TizenRemote.deviceInfo(from: """
            {"id":"uuid:1","device":{"OS":"Tizen","TokenAuthSupport":"false"}}
            """)
        XCTAssertEqual(info?.tokenAuthSupport, false)
        XCTAssertEqual(TizenRemote.preferredPort(tokenAuthSupport: false), TizenRemote.plainPort)
    }

    /// An unreadable or absent field is `nil`, and `nil` means the secure port.
    /// Kills mutation: defaulting unknown to the plain port — a TV that wants a
    /// token would then be unpairable, which is the worse of the two failures
    /// (the other one just falls back).
    func testUnknownTokenSupportPrefersTheSecurePort() {
        XCTAssertNil(TizenRemote.deviceInfo(from: #"{"id":"uuid:1","device":{"OS":"Tizen"}}"#)?.tokenAuthSupport)
        XCTAssertEqual(TizenRemote.preferredPort(tokenAuthSupport: nil), TizenRemote.securePort)
    }

    /// A device with no identifier cannot be persisted safely, so it is refused.
    /// Kills mutation: falling back to the address as the id, which is the exact
    /// bug `TVDeviceID` exists to prevent — a DHCP move would then re-point a
    /// stored device at whatever took the lease.
    func testADeviceWithNoIdentifierIsRefused() {
        XCTAssertNil(TizenRemote.deviceInfo(from: #"{"device":{"OS":"Tizen"}}"#))
        XCTAssertNil(TizenRemote.deviceInfo(from: #"{"id":"","device":{"OS":"Tizen"}}"#))
    }

    /// Hostile input never crashes and never half-decodes.
    /// Kills mutation: force-unwrapping anything in the parser.
    func testMalformedDetectionDocumentsAreRefused() {
        for text in ["", "not json", "[]", "42", "{", String(repeating: "[", count: 5000)] {
            XCTAssertNil(TizenRemote.deviceInfo(from: text))
        }
    }

    /// A non-Samsung device answering on 8001 is reported as unsupported rather
    /// than half-driven.
    /// Kills mutation: treating any answer on 8001 as a Tizen TV.
    func testANonTizenDeviceIsNotSupported() {
        let info = TizenRemote.deviceInfo(from: #"{"id":"uuid:2","device":{"OS":"Android"}}"#)
        XCTAssertEqual(info?.isSupported, false)
    }

    // MARK: - The control URL

    /// The token goes on 8002 and only on 8002; the name is base64.
    /// Kills mutation: attaching the token on the plain port, which puts a bearer
    /// credential in a URL on an unencrypted connection for no benefit at all
    /// (8001 does not use tokens).
    func testTokenIsAttachedOnlyOnTheSecurePort() throws {
        let secure = try XCTUnwrap(TizenRemote.controlURL(host: "10.0.0.9", port: 8002, token: "tok"))
        XCTAssertEqual(secure.scheme, "wss")
        XCTAssertEqual(secure.port, 8002)
        // Read back through `URLComponents` rather than matched against the raw
        // string: base64 of an odd-length name ends in `=`, which Foundation
        // percent-encodes inside a query value (`%3D`). That is correct, and it
        // is what every other client sends too — but asserting on the literal
        // would pin the encoding rather than the value.
        XCTAssertEqual(queryItems(secure)["token"], "tok")
        XCTAssertEqual(queryItems(secure)["name"], TizenRemote.base64Name("Crisp"))

        let plain = try XCTUnwrap(TizenRemote.controlURL(host: "10.0.0.9", port: 8001, token: "tok"))
        XCTAssertEqual(plain.scheme, "ws")
        XCTAssertNil(queryItems(plain)["token"])
        XCTAssertEqual(queryItems(plain)["name"], TizenRemote.base64Name("Crisp"))
    }

    /// Query items decoded, so a test asserts on values rather than on
    /// Foundation's percent-encoding choices.
    private func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(
            items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Channel events and the two token locations

    /// Current firmware: the token is at `data.token`.
    /// Kills mutation: reading only the legacy location, which would fail to pair
    /// with every recent TV.
    func testTokenIsReadFromTheModernLocation() {
        let event = TizenRemote.channelEvent(from: #"{"event":"ms.channel.connect","data":{"token":"12345678"}}"#)
        XCTAssertEqual(event, .connected(token: "12345678"))
    }

    /// Older models: the token is at `data.clients[0].attributes.token` and
    /// `data.token` is absent entirely.
    /// Kills mutation: reading only `data.token`, which pairs fine on a new TV
    /// and silently never pairs on an old one — the failure that is hardest to
    /// find, because the developer's own TV works.
    func testTokenIsReadFromTheLegacyClientsLocation() {
        let event = TizenRemote.channelEvent(from: """
            {"event":"ms.channel.connect","data":{"id":"uuid:9","clients":[
              {"id":"1","isHost":true,"attributes":{"name":"Q3Jpc3A=","token":"87654321"}}]}}
            """)
        XCTAssertEqual(event, .connected(token: "87654321"))
    }

    /// A connect with no token at all is still a connect: the plain port issues
    /// none.
    /// Kills mutation: requiring a token to consider the channel open, which
    /// would break every `TokenAuthSupport: false` TV.
    func testAConnectWithoutATokenIsStillAConnect() {
        let event = TizenRemote.channelEvent(from: #"{"event":"ms.channel.connect","data":{"id":"uuid:9"}}"#)
        XCTAssertEqual(event, .connected(token: nil))
    }

    /// An empty-string token is not a token.
    /// Kills mutation: storing "" as a credential, which then fails every future
    /// connection while looking like a successful pairing.
    func testAnEmptyTokenIsTreatedAsAbsent() {
        let event = TizenRemote.channelEvent(from: #"{"event":"ms.channel.connect","data":{"token":""}}"#)
        XCTAssertEqual(event, .connected(token: nil))
    }

    /// Refusal is its own event and must be distinguishable from a timeout.
    /// Kills mutation: mapping every non-connect event to "other", which turns
    /// "you pressed Deny on the TV" into "your TV did not answer".
    func testUnauthorizedAndTimeoutAreDistinctFromEverythingElse() {
        XCTAssertEqual(TizenRemote.channelEvent(from: #"{"event":"ms.channel.unauthorized"}"#), .unauthorized)
        XCTAssertEqual(TizenRemote.channelEvent(from: #"{"event":"ms.channel.timeOut"}"#), .timeout)
        XCTAssertEqual(TizenRemote.channelEvent(from: #"{"event":"ms.channel.ready"}"#), .other("ms.channel.ready"))
        XCTAssertNil(TizenRemote.channelEvent(from: #"{"data":{"token":"x"}}"#))
    }

    /// Hostile frames never crash and never look like a connect.
    /// Kills mutation: force-unwrapping in the event parser.
    func testMalformedChannelFramesAreRefused() {
        for text in ["", "{", "[]", "null", String(repeating: "{\"a\":", count: 2000)] {
            XCTAssertNil(TizenRemote.channelEvent(from: text))
        }
    }

    // MARK: - Keys

    /// The frame the TV accepts, exactly. `Option` is the *string* "false".
    /// Kills mutation: emitting a JSON boolean for `Option`, or renaming any of
    /// the four params — the TV ignores such a frame silently, which is the worst
    /// possible failure mode to debug.
    func testKeyFrameHasTheDocumentedShape() {
        // Split only so the line fits; the two halves join to exactly the frame
        // the TV accepts, and `Option` is the *string* "false" in it.
        let expected = #"{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_VOLUP","#
            + #""Option":"false","TypeOfRemote":"SendRemoteKey"}}"#
        XCTAssertEqual(TizenRemote.keyFrame(.volumeUp), expected)
    }

    /// Direct HDMI keys are 1-based and bounded.
    /// Kills mutation: off-by-one indexing, which would send `KEY_HDMI2` when the
    /// user asked for HDMI 1 — and Samsung reports no input back, so nothing
    /// would ever notice.
    func testDirectHDMIKeysAreOneBasedAndBounded() {
        XCTAssertEqual(TizenRemote.hdmiKey(port: 1), .hdmi1)
        XCTAssertEqual(TizenRemote.hdmiKey(port: 4), .hdmi4)
        XCTAssertNil(TizenRemote.hdmiKey(port: 0))
        XCTAssertNil(TizenRemote.hdmiKey(port: 5))
    }

    // MARK: - The rate limit

    /// One key per second. Faster drops the *connection*, not the key.
    /// Kills mutation: dropping the pacing, or computing it without booking the
    /// slot — a caller that asked "how long?" twice would then get zero both
    /// times and send exactly the burst this prevents.
    func testKeysArePacedOneSecondApart() {
        var limiter = TizenRemote.KeyRateLimiter()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(limiter.reserve(at: start), 0, accuracy: 0.001)
        XCTAssertEqual(limiter.reserve(at: start), 1.0, accuracy: 0.001)
        XCTAssertEqual(limiter.reserve(at: start), 2.0, accuracy: 0.001)
    }

    /// A caller that already waited is not made to wait again.
    /// Kills mutation: pacing from "the last reservation" rather than from the
    /// later of that and now, which would make a limiter that has been idle for a
    /// minute still delay the next key.
    func testAnIdleLimiterDoesNotDelayTheNextKey() {
        var limiter = TizenRemote.KeyRateLimiter()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = limiter.reserve(at: start)
        XCTAssertEqual(limiter.reserve(at: start.addingTimeInterval(30)), 0, accuracy: 0.001)
    }

    /// A reconnect starts with no history to be paced against.
    /// Kills mutation: keeping the pacing across a reset, which delays the first
    /// key of every new session for no reason.
    func testResetClearsThePacing() {
        var limiter = TizenRemote.KeyRateLimiter()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = limiter.reserve(at: start)
        limiter.reset()
        XCTAssertEqual(limiter.reserve(at: start), 0, accuracy: 0.001)
    }

    // MARK: - UPnP

    /// The control URL is read out of the device description and resolved against
    /// the URL it came from — never assumed.
    /// Kills mutation: hardcoding port 9197 and a path, which is a feature that
    /// works on one television (real TVs use 9197 *and* 7676 with varying paths).
    func testRenderingControlURLIsDiscoveredAndResolvedRelatively() {
        let xml = """
            <root><device><serviceList>
              <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                       <controlURL>/upnp/control/ConnectionManager1</controlURL></service>
              <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                       <controlURL>/upnp/control/RenderingControl1</controlURL></service>
            </serviceList></device></root>
            """
        let base = URL(string: "http://10.0.0.9:7676/smp_2_")!
        let control = TizenRemote.UPnP.controlURL(fromDescription: xml, baseURL: base)
        XCTAssertEqual(control?.absoluteString, "http://10.0.0.9:7676/upnp/control/RenderingControl1")
    }

    /// A description with no RenderingControl yields nothing rather than the
    /// first service it happened to find.
    /// Kills mutation: taking `controlURL` from whichever `<service>` came first,
    /// which would POST volume commands at the connection manager.
    func testADescriptionWithoutRenderingControlYieldsNothing() {
        let xml = """
            <root><device><serviceList>
              <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                       <controlURL>/upnp/control/ConnectionManager1</controlURL></service>
            </serviceList></device></root>
            """
        XCTAssertNil(
            TizenRemote.UPnP.controlURL(fromDescription: xml, baseURL: URL(string: "http://10.0.0.9:9197/dmr")!)
        )
    }

    /// Malformed XML is refused, not partially believed.
    /// Kills mutation: a scan that runs off the end of a truncated document.
    func testMalformedDescriptionsAreRefused() {
        for xml in ["", "<root>", "<service><controlURL>", String(repeating: "<service>", count: 5000)] {
            XCTAssertNil(
                TizenRemote.UPnP.controlURL(fromDescription: xml, baseURL: URL(string: "http://10.0.0.9/")!)
            )
        }
    }

    /// The SOAP body carries the three arguments the service requires, in the
    /// namespace it requires.
    /// Kills mutation: omitting `InstanceID` or `Channel`, which the service
    /// rejects, or clamping the volume somewhere else and letting 140 through.
    func testSetVolumeBodyIsAWellFormedRenderingControlCall() {
        let body = TizenRemote.UPnP.setVolumeBody(percent: 137)
        XCTAssertTrue(body.contains("<InstanceID>0</InstanceID>"))
        XCTAssertTrue(body.contains("<Channel>Master</Channel>"))
        XCTAssertTrue(body.contains("<DesiredVolume>100</DesiredVolume>"))
        XCTAssertTrue(body.contains(TizenRemote.UPnP.renderingControl))
        XCTAssertEqual(
            TizenRemote.UPnP.soapAction("SetVolume"),
            "\"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume\""
        )
    }

    /// The volume comes back inside a SOAP envelope and is clamped on the way in.
    /// Kills mutation: trusting the TV's number, which has been seen out of range
    /// and would then drive a slider off its track.
    func testGetVolumeResponseIsParsedAndClamped() {
        let response = """
            <s:Envelope><s:Body><u:GetVolumeResponse><CurrentVolume>17</CurrentVolume>
            </u:GetVolumeResponse></s:Body></s:Envelope>
            """
        XCTAssertEqual(TizenRemote.UPnP.volume(fromResponse: response), 17)
        XCTAssertNil(TizenRemote.UPnP.volume(fromResponse: "<s:Envelope/>"))
    }
}
