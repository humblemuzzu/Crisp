import XCTest

/// Headless tests for LG's SSAP: the envelope, id-based correlation, the pairing
/// state machine and the backlight round trip.
///
/// `WebOSProtocol.swift` is compiled directly into this target (see `project.yml`
/// sources, same route as `DDCPacket`), so no `@testable import Crisp` is needed.
/// Each test names the mutation it is designed to kill in a trailing comment.
///
/// **There is no television on the machine this was written on.** Everything
/// below is the protocol as documented by the working clients, exercised against
/// text — which is exactly why the protocol logic was put above the `TVTransport`
/// seam in the first place.
final class WebOSProtocolTests: XCTestCase {

    // MARK: - Envelope

    /// The wire format, byte for byte. Sorted keys make this assertable at all.
    /// Kills mutation: renaming `type`/`uri`/`payload`, or emitting the id as a
    /// number — the TV echoes the id back and correlation is string equality.
    func testRequestFrameHasTheDocumentedShape() {
        let frame = WebOSSSAP.requestFrame(id: "req_1", uri: WebOSSSAP.URI.getVolume)
        XCTAssertEqual(
            frame,
            #"{"id":"req_1","payload":{},"type":"request","uri":"ssap://audio/getVolume"}"#
        )
    }

    /// The volume payload carries a whole number, clamped.
    /// Kills mutation: dropping the clamp (the TV accepts 140 and does something
    /// unhelpful), or sending a fractional volume.
    func testSetVolumeFrameClampsAndRounds() {
        XCTAssertEqual(
            WebOSSSAP.setVolumeFrame(id: "v", percent: 143.6),
            #"{"id":"v","payload":{"volume":100},"type":"request","uri":"ssap://audio/setVolume"}"#
        )
        XCTAssertEqual(
            WebOSSSAP.setVolumeFrame(id: "v", percent: -12),
            #"{"id":"v","payload":{"volume":0},"type":"request","uri":"ssap://audio/setVolume"}"#
        )
    }

    /// A NaN percentage must not become full volume.
    /// Kills mutation: `min(100, .nan)` is 100 in Swift, so a clamp that does not
    /// check `isFinite` first turns a garbage value into the loudest one.
    func testNonFinitePercentBecomesZeroNotFull() {
        XCTAssertEqual(WebOSSSAP.clampedPercent(.nan), 0)
        XCTAssertEqual(WebOSSSAP.clampedPercent(.infinity), 0)
    }

    /// Ids are unique within a connection and human-legible in a log.
    /// Kills mutation: a generator that returns the same id twice, which would
    /// make two outstanding requests indistinguishable.
    func testIDGeneratorNeverRepeats() {
        var ids = WebOSSSAP.IDGenerator()
        let issued = (0..<50).map { _ in ids.next() }
        XCTAssertEqual(Set(issued).count, 50)
    }

    // MARK: - Replies

    /// `returnValue` is success — and so is `subscribed`.
    /// Kills mutation: checking only `returnValue`, which reads every successful
    /// subscribe as a failure (several webOS services answer only the latter).
    func testSubscribedCountsAsSuccessAsWellAsReturnValue() {
        let returned = WebOSSSAP.reply(from: #"{"id":"a","type":"response","payload":{"returnValue":true}}"#)
        let subscribed = WebOSSSAP.reply(from: #"{"id":"b","type":"response","payload":{"subscribed":true}}"#)
        XCTAssertEqual(returned?.isSuccess, true)
        XCTAssertEqual(subscribed?.isSuccess, true)
    }

    /// An `error` field beats a `returnValue` that says otherwise.
    /// Kills mutation: reading `returnValue` first and returning early, which
    /// would treat an errored frame as a success whenever the TV sends both.
    func testErrorFieldOverridesReturnValue() {
        let reply = WebOSSSAP.reply(
            from: #"{"id":"a","type":"response","error":"404 no such service","payload":{"returnValue":true}}"#
        )
        XCTAssertEqual(reply?.isSuccess, false)
        XCTAssertEqual(reply?.error, "404 no such service")
    }

    /// Hostile and malformed input is `nil`, never a crash and never a `Reply`
    /// with an empty id that could satisfy somebody's pending request.
    /// Kills mutation: defaulting `id` to "" for any parsed object, which would
    /// let a bare `{"foo":1}` frame answer a request whose id happened to be "".
    func testMalformedFramesAreRefusedRatherThanCoerced() {
        for text in [
            "", "not json", "[1,2,3]", "42", "null", #"{"foo":1}"#,
            #"{"id":{"nested":true}}"#, String(repeating: "{", count: 5000)
        ] {
            XCTAssertNil(WebOSSSAP.reply(from: text), "\(text.prefix(20)) is not a frame")
        }
    }

    /// A frame whose `id` is a number still parses, using the fields that *are*
    /// readable, because it carries a usable `type`.
    /// Kills mutation: a strict decode that drops the whole frame on one
    /// unexpected field type — one odd firmware would disable a feature.
    func testAFrameWithAnOddlyTypedFieldStillYieldsWhatIsReadable() {
        let reply = WebOSSSAP.reply(from: #"{"id":7,"type":"registered","payload":{"client-key":"abc"}}"#)
        XCTAssertEqual(reply?.type, "registered")
        XCTAssertEqual(reply?.id, "")
        XCTAssertEqual(reply?.payload?["client-key"]?.stringValue, "abc")
    }

    // MARK: - Correlation

    /// Replies arrive in whatever order the services behind them finish, and each
    /// one has to reach the request that asked for it.
    /// Kills mutation: matching "the next frame" to "my last request", which is
    /// wrong the moment two requests are outstanding.
    func testOutOfOrderRepliesReachTheRightRequest() throws {
        var correlator = WebOSSSAP.Correlator<String>()
        correlator.expect("req_1", tag: "volume")
        correlator.expect("req_2", tag: "inputs")

        let second = WebOSSSAP.reply(from: #"{"id":"req_2","type":"response","payload":{"returnValue":true}}"#)
        let first = WebOSSSAP.reply(from: #"{"id":"req_1","type":"response","payload":{"returnValue":true}}"#)
        XCTAssertEqual(correlator.take(try XCTUnwrap(second)), "inputs")
        XCTAssertEqual(correlator.take(try XCTUnwrap(first)), "volume")
        XCTAssertEqual(correlator.pendingCount, 0)
    }

    /// A frame nobody is waiting for is a normal event (a subscription push), not
    /// an error and not somebody else's answer.
    /// Kills mutation: returning the first outstanding tag for an unknown id,
    /// which would hand a push to whichever request happened to be pending.
    func testAnUnexpectedFrameMatchesNothing() throws {
        var correlator = WebOSSSAP.Correlator<String>()
        correlator.expect("req_1", tag: "volume")
        let push = WebOSSSAP.reply(from: #"{"id":"push_9","type":"response","payload":{"returnValue":true}}"#)
        XCTAssertNil(correlator.take(try XCTUnwrap(push)))
        XCTAssertEqual(correlator.pendingCount, 1)
    }

    /// A socket that went away has to fail everyone waiting on it.
    /// Kills mutation: clearing the map without returning the tags, which leaves
    /// every caller awaiting a reply that can never arrive.
    func testDrainReturnsEveryOutstandingTag() {
        var correlator = WebOSSSAP.Correlator<String>()
        correlator.expect("a", tag: "one")
        correlator.expect("b", tag: "two")
        XCTAssertEqual(Set(correlator.drainAll()), ["one", "two"])
        XCTAssertEqual(correlator.pendingCount, 0)
    }

    // MARK: - Pairing

    /// The happy path: the TV registers and hands back a key.
    /// Kills mutation: ignoring the `registered` type, which would leave pairing
    /// waiting forever on a TV that already said yes.
    func testRegisteredFrameCompletesPairingWithTheKey() {
        var pairing = WebOSSSAP.Pairing(requestID: "register_1")
        let state = pairing.ingest(
            #"{"id":"register_1","type":"registered","payload":{"client-key":"0123456789abcdef"}}"#
        )
        XCTAssertEqual(state, .registered(clientKey: "0123456789abcdef"))
        XCTAssertTrue(state.isFinished)
    }

    /// The prompt going up is *not* an answer.
    /// Kills mutation: treating any `response` as the end of the conversation,
    /// which would report a pairing failure the instant the TV showed its prompt
    /// — i.e. every first pairing would fail.
    func testPromptResponseDoesNotEndTheConversation() {
        var pairing = WebOSSSAP.Pairing(requestID: "register_1")
        let after = pairing.ingest(
            #"{"id":"register_1","type":"response","payload":{"pairingType":"PROMPT","returnValue":true}}"#
        )
        XCTAssertEqual(after, .promptShown)
        XCTAssertFalse(after.isFinished)

        let final = pairing.ingest(
            #"{"id":"register_1","type":"registered","payload":{"client-key":"key-2"}}"#
        )
        XCTAssertEqual(final, .registered(clientKey: "key-2"))
    }

    /// Rejection ends it, carrying the TV's own words.
    /// Kills mutation: swallowing the error and timing out instead, which turns
    /// "you pressed Cancel on the TV" into "your TV is unreachable".
    func testRejectionIsReportedWithTheTVsOwnReason() {
        var pairing = WebOSSSAP.Pairing(requestID: "register_1")
        let state = pairing.ingest(#"{"id":"register_1","type":"error","error":"403 access denied"}"#)
        XCTAssertEqual(state, .refused(reason: "403 access denied"))
    }

    /// A stale key re-triggers the prompt and yields a *new* key, which must be
    /// adopted rather than compared against the old one.
    /// Kills mutation: keeping the previously stored key on re-registration,
    /// which would leave the app authenticating with a key the TV has forgotten
    /// — and prompting the user on every single connection forever.
    func testStaleKeyReprompsAndTheNewKeyIsAdopted() {
        var pairing = WebOSSSAP.Pairing(requestID: "register_1")
        _ = pairing.ingest(#"{"id":"register_1","type":"response","payload":{"pairingType":"PROMPT"}}"#)
        let state = pairing.ingest(
            #"{"id":"register_1","type":"registered","payload":{"client-key":"fresh-key"}}"#
        )
        XCTAssertEqual(state, .registered(clientKey: "fresh-key"))
    }

    /// A frame for somebody else's request must not move this state machine.
    /// Kills mutation: dropping the id check, so a `getVolume` error during
    /// pairing would be read as the pairing being refused.
    func testAFrameForAnotherRequestIsIgnored() {
        var pairing = WebOSSSAP.Pairing(requestID: "register_1")
        let state = pairing.ingest(#"{"id":"volume_3","type":"error","error":"404"}"#)
        XCTAssertEqual(state, .awaitingResponse)
    }

    /// "Registered" with no key is a refusal, not a success.
    /// Kills mutation: storing an empty client key, which looks exactly like a
    /// successful pairing and then fails every later connection.
    func testRegisteredWithoutAKeyIsRefused() {
        var pairing = WebOSSSAP.Pairing(requestID: "register_1")
        let state = pairing.ingest(#"{"id":"register_1","type":"registered","payload":{"client-key":""}}"#)
        guard case .refused = state else {
            return XCTFail("an empty client key must not count as paired, got \(state)")
        }
    }

    /// Once finished, nothing moves it again.
    /// Kills mutation: letting a late frame overwrite a completed pairing, which
    /// could turn a stored key back into a refusal after the fact.
    func testAFinishedPairingIsNotReopenedByLaterFrames() {
        var pairing = WebOSSSAP.Pairing(requestID: "r")
        _ = pairing.ingest(#"{"id":"r","type":"registered","payload":{"client-key":"k"}}"#)
        let after = pairing.ingest(#"{"id":"r","type":"error","error":"403"}"#)
        XCTAssertEqual(after, .registered(clientKey: "k"))
    }

    /// Malformed frames never crash the state machine and never advance it.
    /// Kills mutation: force-unwrapping anything in `ingest`.
    func testHostileFramesDoNotMovePairing() {
        var pairing = WebOSSSAP.Pairing(requestID: "r")
        for text in ["", "{", "[]", "\u{0}\u{0}", String(repeating: "a", count: 100_000)] {
            XCTAssertEqual(pairing.ingest(text), .awaitingResponse)
        }
    }

    /// The registration frame carries the signed manifest LG's firmware checks
    /// the shape of, and the stored key when there is one.
    /// Kills mutation: dropping the `signed` block or the signature (the TV then
    /// silently never shows the prompt, which is indistinguishable from a dead
    /// TV), or sending `"client-key": null` on a first pairing.
    func testRegisterFrameCarriesTheManifestAndOnlyARealKey() throws {
        let first = try XCTUnwrap(WebOSSSAP.registerFrame(id: "r", clientKey: nil))
        XCTAssertTrue(first.contains("\"signed\""))
        XCTAssertTrue(first.contains("\"signatures\""))
        XCTAssertTrue(first.contains("com.lge.test"))
        XCTAssertTrue(first.contains("\"pairingType\":\"PROMPT\""))
        XCTAssertFalse(first.contains("client-key"), "no key means no key field")

        let repeated = try XCTUnwrap(WebOSSSAP.registerFrame(id: "r", clientKey: "stored"))
        XCTAssertTrue(repeated.contains(#""client-key":"stored""#))

        let empty = try XCTUnwrap(WebOSSSAP.registerFrame(id: "r", clientKey: ""))
        XCTAssertFalse(empty.contains("client-key"), "an empty key is not a key")
    }

    // MARK: - Brightness

    /// The backlight write is an alert whose handlers carry the Luna settings
    /// call — the direct `setSystemSettings` answers "404 no such service".
    /// Kills mutation: sending `setSystemSettings` directly, or dropping the
    /// `onclose`/`onfail` handlers, either of which makes the write a no-op.
    func testBacklightWriteEmbedsTheLunaCallInTheAlertHandlers() throws {
        let frame = try XCTUnwrap(WebOSSSAP.backlightAlertFrame(id: "alert_1", percent: 42))
        XCTAssertTrue(frame.contains("ssap://system.notifications/createAlert"))
        XCTAssertTrue(frame.contains("luna://com.webos.settingsservice/setSystemSettings"))
        XCTAssertTrue(frame.contains(#""backlight":42"#))
        XCTAssertTrue(frame.contains("onclose"))
        XCTAssertTrue(frame.contains("onfail"))
    }

    /// The alert id comes back only from a successful reply.
    /// Kills mutation: reading `alertId` off a failed reply, which would then
    /// close an alert that was never created and report a write that never
    /// happened as a success.
    func testAlertIDIsOnlyTakenFromASuccessfulReply() throws {
        let good = try XCTUnwrap(
            WebOSSSAP.reply(from: #"{"id":"a","type":"response","payload":{"returnValue":true,"alertId":"al-9"}}"#)
        )
        XCTAssertEqual(WebOSSSAP.alertID(from: good), "al-9")

        let bad = try XCTUnwrap(
            WebOSSSAP.reply(from: #"{"id":"a","type":"response","error":"404","payload":{"alertId":"al-9"}}"#)
        )
        XCTAssertNil(WebOSSSAP.alertID(from: bad))
    }

    /// `backlight` is the panel's light output; `brightness` on a webOS TV is the
    /// black level. Conflating them is why some remote apps appear to do nothing.
    /// Kills mutation: reading `brightness` where `backlight` is meant.
    func testPictureSettingsReadsBacklightSeparatelyFromBrightness() throws {
        let reply = try XCTUnwrap(WebOSSSAP.reply(from: """
            {"id":"p","type":"response","payload":{"returnValue":true,"settings":\
            {"backlight":"80","brightness":50,"contrast":85,"pictureMode":"cinema"}}}
            """))
        let settings = try XCTUnwrap(WebOSSSAP.pictureSettings(from: reply))
        // `backlight` arrived as a string here on purpose: a firmware that quotes
        // its numbers must yield "not readable", never a coerced 0 that a slider
        // would then jump to.
        XCTAssertNil(settings.backlight)
        XCTAssertEqual(settings.brightness, 50)
        XCTAssertEqual(settings.pictureMode, "cinema")
    }

    // MARK: - Inputs

    /// Inputs with no id cannot be switched to, so they are not offered; inputs
    /// the TV says nothing is connected to *are*, because that flag is wrong
    /// often enough to hide real ports.
    /// Kills mutation: filtering on `connected`, which hides the port the user is
    /// looking through — the same mistake as filtering the DDC input menu by the
    /// capabilities string (AGENTS.md §6).
    func testExternalInputsKeepDisconnectedPortsAndDropIdlessOnes() throws {
        let reply = try XCTUnwrap(WebOSSSAP.reply(from: """
            {"id":"i","type":"response","payload":{"returnValue":true,"devices":[\
            {"id":"HDMI_1","label":"Mac","connected":true},\
            {"id":"HDMI_2","label":"Console","connected":false},\
            {"label":"No id at all"}]}}
            """))
        let inputs = WebOSSSAP.externalInputs(from: reply)
        XCTAssertEqual(inputs.map(\.id), ["HDMI_1", "HDMI_2"])
        XCTAssertEqual(inputs[1].isConnected, false)
    }

    // MARK: - Sound output

    /// An absolute volume write is silently swallowed when audio is routed to a
    /// soundbar, so the app has to know before it pretends to have set one.
    /// Kills mutation: assuming every unknown output is external (which disables
    /// the slider on TVs where it works) or that none is (which leaves a slider
    /// reporting success and doing nothing).
    func testAbsoluteVolumeIsKnownToBeIgnoredOnlyForExternalOutputs() {
        XCTAssertTrue(WebOSSSAP.absoluteVolumeIsIgnored(soundOutput: "external_arc"))
        XCTAssertTrue(WebOSSSAP.absoluteVolumeIsIgnored(soundOutput: "EXTERNAL_OPTICAL"))
        XCTAssertFalse(WebOSSSAP.absoluteVolumeIsIgnored(soundOutput: "tv_speaker"))
        XCTAssertFalse(WebOSSSAP.absoluteVolumeIsIgnored(soundOutput: nil))
        XCTAssertFalse(WebOSSSAP.absoluteVolumeIsIgnored(soundOutput: "something_new"))
    }

    // MARK: - Against the fake transport

    /// The whole pairing conversation, driven through the seam.
    /// Kills mutation: any change that makes pairing depend on frames arriving in
    /// one particular order, or on a socket-level signal the protocol layer
    /// cannot see.
    func testPairingConversationOverTheFakeTransport() async throws {
        let transport = FakeTVTransport(
            platform: .webOS,
            connectOutcome: .connected(port: 3001, fingerprint: "aabb"),
            frames: [
                #"{"id":"other_1","type":"response","payload":{"returnValue":true}}"#,
                #"{"id":"register_1","type":"response","payload":{"pairingType":"PROMPT"}}"#,
                #"{"id":"register_1","type":"registered","payload":{"client-key":"the-key"}}"#
            ]
        )
        let channel = try await transport.open(host: "10.0.0.5", credential: nil, timeout: 1)
        XCTAssertEqual(channel.port, 3001)
        XCTAssertEqual(channel.certificateFingerprint, "aabb")

        try await transport.send(try XCTUnwrap(WebOSSSAP.registerFrame(id: "register_1", clientKey: nil)))
        var pairing = WebOSSSAP.Pairing(requestID: "register_1")
        while !pairing.state.isFinished {
            pairing.ingest(try await transport.receive(timeout: 1))
        }
        XCTAssertEqual(pairing.state, .registered(clientKey: "the-key"))
        transport.close()
        XCTAssertFalse(transport.isOpen)
    }

    /// A TV that is off is a thrown `unreachable`, not a hang and not a partial
    /// conversation.
    /// Kills mutation: an `open` that returns a channel it did not get, which
    /// would leave every later `send` failing with "closed" instead of the one
    /// message that tells the user to switch the TV on.
    func testAnUnreachableTVFailsAtOpenWithAnActionableMessage() async {
        let transport = FakeTVTransport(connectOutcome: .unreachable)
        do {
            _ = try await transport.open(host: "10.0.0.5", credential: nil, timeout: 1)
            XCTFail("an unreachable TV must not report a channel")
        } catch let error as TVTransportError {
            XCTAssertEqual(error, .unreachable("10.0.0.5"))
            XCTAssertTrue(error.message.contains("10.0.0.5"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - The registration wait's two bounds

    /// A frame that parses, belongs to somebody else's request, and therefore
    /// moves the pairing state machine not at all. What a device that is not the
    /// television sounds like.
    private static let chatter = #"{"id":"someone_else_1","type":"response","payload":{"returnValue":true}}"#

    /// A device that answers forever without ever finishing is stopped by the
    /// deadline, not by luck.
    ///
    /// This is the property that had no test: the fake used to fall silent as
    /// soon as its script ran out, so a wait that exits only on a thrown
    /// `receive` passed anyway. `.repeats` is what makes the hang expressible.
    /// Kills mutation: deleting the `now() < deadline` term from `awaitPairing`,
    /// which is exactly the bug this replaced — and which sat on the path taken
    /// before every webOS write, not merely at pairing.
    func testARepeatingDeviceIsStoppedByTheDeadlineOnBothWaits() async throws {
        for silence in [WebOSSSAP.PairingSilence.ends, .keepsWaiting] {
            let transport = FakeTVTransport(platform: .webOS)
            transport.whenExhausted = .repeats(Self.chatter)
            _ = try await transport.open(host: "10.0.0.5", credential: "stored-key", timeout: 1)

            let clock = SteppingClock(step: 1)
            let pairing = await WebOSSSAP.awaitPairing(
                WebOSSSAP.Pairing(requestID: "register_1"),
                on: transport,
                timeout: 5,
                onSilence: silence,
                now: { clock.now() }
            )

            // Unfinished is the honest answer — the caller turns it into a
            // timeout. What matters is that there *is* an answer.
            XCTAssertEqual(pairing.state, .awaitingResponse)
            XCTAssertFalse(pairing.state.isFinished)
            // One read for the deadline, then one per iteration until the clock
            // reaches it: five seconds of budget at one second per read.
            XCTAssertEqual(transport.receiveCount, 4)
        }
    }

    /// Silence means different things to the two callers, and the difference is
    /// the parameter rather than two copies of the loop.
    /// Kills mutation: making `.ends` the behaviour of both, which would abandon
    /// a pairing prompt at the first quiet ten seconds — before the user has
    /// reached the sofa.
    func testSilenceEndsTheWriteWaitAndNotThePairingWait() async throws {
        let quick = FakeTVTransport(platform: .webOS)
        _ = try await quick.open(host: "10.0.0.5", credential: "stored-key", timeout: 1)
        let quickClock = SteppingClock(step: 1)
        _ = await WebOSSSAP.awaitPairing(
            WebOSSSAP.Pairing(requestID: "register_1"), on: quick,
            timeout: 5, onSilence: .ends, now: { quickClock.now() }
        )
        XCTAssertEqual(quick.receiveCount, 1)

        let patient = FakeTVTransport(platform: .webOS)
        _ = try await patient.open(host: "10.0.0.5", credential: nil, timeout: 1)
        let patientClock = SteppingClock(step: 1)
        _ = await WebOSSSAP.awaitPairing(
            WebOSSSAP.Pairing(requestID: "register_1"), on: patient,
            timeout: 5, onSilence: .keepsWaiting, now: { patientClock.now() }
        )
        XCTAssertEqual(patient.receiveCount, 4)
    }

    /// The bound does not cost a television that answers anything: the wait ends
    /// on the key, at the frame that carries it, with the deadline untouched.
    /// Kills mutation: a deadline expressed in the wrong unit, or a loop that
    /// keeps reading after `registered` and swallows the next frame.
    func testAPairingThatSucceedsStillEndsAtTheKey() async throws {
        let transport = FakeTVTransport(
            platform: .webOS,
            connectOutcome: .connected(port: 3001, fingerprint: "aabb"),
            frames: [
                Self.chatter,
                #"{"id":"register_1","type":"response","payload":{"pairingType":"PROMPT"}}"#,
                #"{"id":"register_1","type":"registered","payload":{"client-key":"the-key"}}"#
            ]
        )
        transport.whenExhausted = .repeats(Self.chatter)
        _ = try await transport.open(host: "10.0.0.5", credential: nil, timeout: 1)

        let pairing = await WebOSSSAP.awaitPairing(
            WebOSSSAP.Pairing(requestID: "register_1"), on: transport, timeout: TVTimeout.pairing
        )

        XCTAssertEqual(pairing.state, .registered(clientKey: "the-key"))
        XCTAssertEqual(transport.receiveCount, 3)
    }
}

/// A clock that advances one step per reading.
///
/// So a wait against a deadline is a deterministic handful of iterations rather
/// than a real sixty seconds of test time — the same reason `PresetSchedule`'s
/// tests inject a calendar instead of waiting for 22:00.
private final class SteppingClock: @unchecked Sendable {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval
    private let lock = NSLock()
    private var readings = 0

    init(step: TimeInterval) { self.step = step }

    func now() -> Date {
        lock.withLock {
            defer { readings += 1 }
            return origin.addingTimeInterval(Double(readings) * step)
        }
    }
}
