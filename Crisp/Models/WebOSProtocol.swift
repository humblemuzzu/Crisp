import Foundation

// LG webOS SSAP, as pure text.
//
// Everything in this file is "a string in, a value out" or "a value in, a string
// out": the envelope, the registration handshake, the id-based correlation, the
// pairing state machine, and the two-step round trip that is the only working way
// to write a modern webOS TV's backlight. None of it opens a socket. That is the
// same split `DDCPacket`/`DDCProtocolEngine` have over `DDCTransport`, and it is
// here for the same reason: there is no television on this network, so the only
// way any of this can be *known* to work is for it to be exercised headlessly
// against `FakeTVTransport`.
//
// ---------------------------------------------------------------------------
// THE PROTOCOL, AND THE FIVE PLACES IT SURPRISES PEOPLE
// ---------------------------------------------------------------------------
// 1. **Send no `Origin` header.** The TV refuses a connection that looks like it
//    came from a browser. `URLSessionWebSocketTask` sends none, so this costs
//    nothing here — but it is written down because "adding an Origin for good
//    measure" is a one-line change that breaks every connection.
//
// 2. **Correlation is purely by `id`.** The TV echoes back the id it was sent,
//    and answers arrive in whatever order the services behind them finish. There
//    is no sequence number and no ordering guarantee, so anything that reads
//    "the next frame" as "the answer to my last request" is wrong on a TV that
//    happens to be doing something else. `Correlator` below is the whole of what
//    replaces that assumption.
//
// 3. **Success is `payload.returnValue` — or `payload.subscribed`.** Subscription
//    services answer with the latter and never send the former, so a client that
//    only checks `returnValue` treats every successful subscribe as a failure.
//
// 4. **`turnOff` is fire and forget.** The TV goes down, and the socket goes with
//    it; the response is unreliable and waiting for it is waiting for a device
//    that is switching itself off. Nothing here waits.
//
// 5. **Power *on* is not possible over this socket at all.** It needs
//    Wake-on-LAN, a different mechanism at a different layer. `TVFeatureRegistry`
//    says so in the hazard text and the UI does not offer it — a "turn on" button
//    that never works is worse than no button.
//
// ---------------------------------------------------------------------------
// BRIGHTNESS, WHICH IS THE INTERESTING PART
// ---------------------------------------------------------------------------
// Reading is ordinary: `ssap://settings/getSystemSettings` with `category:
// picture` returns `backlight`, `brightness`, `contrast` and `pictureMode`.
//
// Writing is not. The direct `setSystemSettings` request answers "404 no such
// service or method" on current firmware. The path that does work goes through
// the notification service: create an alert whose button handlers embed a
// `luna://com.webos.settingsservice/setSystemSettings` call, then immediately
// close the alert by the id the TV just handed back. The settings write happens
// as a side effect of the alert's own lifecycle. It is write-only — nothing comes
// back saying what the panel did — and it may be closed off by a future firmware,
// so `TVDeviceService` treats a failure here as ordinary and says so rather than
// leaving a slider that silently does nothing.
//
// Pure Foundation. Compiles into `CrispTests` and `crispctl` (AGENTS.md §3.6).

enum WebOSSSAP {

    // MARK: - Ports

    /// Plaintext. Older firmware only; webOS 5 and later (2020+) frequently
    /// refuse it outright.
    static let plaintextPort = 3000
    /// TLS, with a self-signed certificate that chains to nothing — see
    /// `TVTrust` for what Crisp does about that instead of turning validation
    /// off.
    static let tlsPort = 3001

    /// The order to try. Plaintext first because when it works it works without
    /// any certificate question at all, and a TV old enough to answer on 3000 is
    /// exactly the one least likely to have a certificate worth pinning.
    static let ports = [plaintextPort, tlsPort]

    static func isEncrypted(port: Int) -> Bool { port == tlsPort }

    // MARK: - URIs

    /// Every SSAP endpoint this app uses, spelled once.
    enum URI {
        static let systemInfo = "ssap://system/getSystemInfo"
        static let getVolume = "ssap://audio/getVolume"
        static let setVolume = "ssap://audio/setVolume"
        static let volumeUp = "ssap://audio/volumeUp"
        static let volumeDown = "ssap://audio/volumeDown"
        static let setMute = "ssap://audio/setMute"
        static let getSoundOutput = "ssap://com.webos.service.apiadapter/audio/getSoundOutput"
        static let turnOff = "ssap://system/turnOff"
        static let getPowerState = "ssap://com.webos.service.tvpower/power/getPowerState"
        static let turnOffScreen = "ssap://com.webos.service.tvpower/power/turnOffScreen"
        static let turnOnScreen = "ssap://com.webos.service.tvpower/power/turnOnScreen"
        static let externalInputList = "ssap://tv/getExternalInputList"
        static let switchInput = "ssap://tv/switchInput"
        static let systemSettings = "ssap://settings/getSystemSettings"
        static let createAlert = "ssap://system.notifications/createAlert"
        static let closeAlert = "ssap://system.notifications/closeAlert"
        /// The Luna URI the brightness write smuggles through the alert handlers.
        /// Not an SSAP endpoint: it is a bus address the TV executes locally.
        static let lunaSetSystemSettings = "luna://com.webos.settingsservice/setSystemSettings"
    }

    // MARK: - Envelope

    /// The `type` field's five values. Sibling of `Envelope` rather than nested
    /// inside it purely to keep the nesting one level deep, which is what the
    /// repo's SwiftLint configuration allows.
    enum EnvelopeKind: String, Equatable, Sendable {
        case hello
        case register
        case request
        case subscribe
        case unsubscribe
    }

    /// One host→TV frame.
    ///
    /// `id` is the correlation key and nothing else: the TV echoes it back
    /// verbatim, so it only has to be unique within a connection.
    struct Envelope: Equatable, Sendable {
        let id: String
        let kind: EnvelopeKind
        let uri: String?
        let payload: JSONValue?

        /// The frame as it goes on the wire, or nil if it will not serialise —
        /// which cannot happen for anything this file builds, and is still not a
        /// reason to force-unwrap on a code path that talks to a network.
        func serialized() -> String? {
            var object: [String: JSONValue] = [
                "id": .string(id),
                "type": .string(kind.rawValue)
            ]
            if let uri { object["uri"] = .string(uri) }
            if let payload { object["payload"] = payload }
            return JSONValue.object(object).serialized()
        }
    }

    /// Unique-per-connection message ids.
    ///
    /// Monotonic and prefixed rather than a UUID, because these end up in logs
    /// and in the frames a bug report quotes: `req_7` is legible where a UUID is
    /// forty characters of noise. Uniqueness only has to hold within one socket.
    struct IDGenerator: Sendable {
        private var counter = 0

        init() {}

        mutating func next(_ prefix: String = "req") -> String {
            counter += 1
            return "\(prefix)_\(counter)"
        }
    }

    /// The optional opening frame. Newer firmware also wants
    /// `getSystemInfo` requested *before* registration, which is why
    /// `LGWebOSTransport` sends both.
    static func helloFrame() -> String? {
        Envelope(id: "hello", kind: .hello, uri: nil, payload: .object([:])).serialized()
    }

    static func requestFrame(id: String, uri: String, payload: JSONValue = .object([:])) -> String? {
        Envelope(id: id, kind: .request, uri: uri, payload: payload).serialized()
    }

    // MARK: - Replies

    /// One TV→host frame, as far as this layer reads it.
    struct Reply: Equatable, Sendable {
        /// The id the TV echoed. Empty for the frames that carry none, which
        /// exist and must not be mistaken for a reply to request `""`.
        let id: String
        /// `response`, `registered`, `error`, `hello`.
        let type: String
        let payload: JSONValue?
        /// The `error` field, when the frame carries one.
        let error: String?

        /// Whether the TV says the request succeeded.
        ///
        /// Both spellings are accepted: subscription services answer
        /// `subscribed: true` and never send `returnValue`, so checking only the
        /// latter reads every successful subscribe as a failure.
        var isSuccess: Bool {
            guard error == nil else { return false }
            if payload?["returnValue"]?.boolValue == true { return true }
            if payload?["subscribed"]?.boolValue == true { return true }
            return type == "registered"
        }
    }

    /// Parses one frame. Total: anything that is not a frame is `nil`, never a
    /// throw and never a partially-filled `Reply`.
    ///
    /// The input arrived over a network from a device nobody controls, so every
    /// field is read defensively — a frame whose `id` is a number, or whose
    /// `payload` is a string, yields the fields that *are* readable and `nil` for
    /// the rest, rather than being dropped whole. Dropping whole would mean one
    /// odd field from one firmware silently disabling a feature.
    static func reply(from text: String) -> Reply? {
        guard let value = JSONValue.parse(text), let object = value.objectValue else { return nil }
        // A JSON document that is a bare array or a number is not a frame; an
        // object with neither an id nor a type is not one either, and treating it
        // as a reply to id "" would let a stray frame satisfy a pending request.
        let id = object["id"]?.stringValue
        let type = object["type"]?.stringValue
        guard id != nil || type != nil else { return nil }
        return Reply(
            id: id ?? "",
            type: type ?? "",
            payload: object["payload"],
            error: object["error"]?.stringValue
        )
    }

    // MARK: - Registration

    /// LG's well-known test-app signature, shipped verbatim by every client that
    /// pairs with a webOS TV.
    ///
    /// It is not a secret and not a credential: it is a fixed blob the TV checks
    /// the shape of before it will show the pairing prompt at all. Base64 of a
    /// JOSE-ish header naming `test-signing-cert`, followed by a signature nobody
    /// outside LG can produce. Changing any field of the manifest below
    /// invalidates it and the TV silently refuses to show the prompt — which
    /// looks exactly like "the TV is not responding", so the fields are left
    /// exactly as they are even where they read oddly (`appId: com.lge.test`, a
    /// fixed serial, a Korean app name).
    static let registrationSignature = "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbm"
        + "ctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR"
        + "+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRy"
        + "aMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4"
        + "RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n"
        + "50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM"
        + "2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQoj"
        + "oa7NQnAtw=="

    /// The permissions the *app* asks for. A superset of what Crisp uses:
    /// trimming it is not free, because the signature covers the manifest and a
    /// TV that dislikes the manifest shows no prompt at all.
    static let permissions = [
        "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED",
        "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
        "CONTROL_POWER", "CONTROL_TV_SCREEN", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
        "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS",
        "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE",
        "READ_COUNTRY_INFO", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
        "READ_INSTALLED_APPS", "READ_SETTINGS"
    ]

    /// The permissions inside the signed block. Different list, and it has to
    /// stay different: it is the one the signature was produced over.
    static let signedPermissions = [
        "TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
        "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_NOTIFICATIONS", "SEARCH",
        "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT", "CONTROL_POWER",
        "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO",
        "UPDATE_FROM_REMOTE_APP", "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME"
    ]

    /// The `register` frame.
    ///
    /// `clientKey` is the key stored from a previous pairing, or nil for the
    /// first one. A **stale** key is not an error case that needs handling: the
    /// TV simply shows the prompt again and answers with a fresh key, which the
    /// state machine below adopts. That is why `Pairing` has no "the key was
    /// rejected" branch — there is no such reply.
    static func registerFrame(id: String, clientKey: String?) -> String? {
        var payload: [String: JSONValue] = [
            "forcePairing": .bool(false),
            "pairingType": .string("PROMPT"),
            "manifest": manifest
        ]
        // Only when there is one: sending `"client-key": null` is not the same
        // message as sending no key, and firmware has been picky about it.
        if let clientKey, !clientKey.isEmpty {
            payload["client-key"] = .string(clientKey)
        }
        return Envelope(id: id, kind: .register, uri: nil, payload: .object(payload)).serialized()
    }

    private static let manifest: JSONValue = .object([
        "manifestVersion": .number(1),
        "appVersion": .string("1.1"),
        "permissions": .array(permissions.map(JSONValue.string)),
        "signatures": .array([
            .object([
                "signature": .string(registrationSignature),
                "signatureVersion": .number(1)
            ])
        ]),
        "signed": .object([
            "appId": .string("com.lge.test"),
            "created": .string("20140509"),
            "localizedAppNames": .object([
                "": .string("LG Remote App"),
                "ko-KR": .string("리모컨 앱"),
                "zxx-XX": .string("ЛГ Rэмotэ AПП")
            ]),
            "localizedVendorNames": .object(["": .string("LG Electronics")]),
            "permissions": .array(signedPermissions.map(JSONValue.string)),
            "serial": .string("2f930e2d2cfe083771f68e4fe7bb07"),
            "vendorId": .string("com.lge")
        ])
    ])

    // MARK: - The pairing state machine

    /// Where a registration attempt has got to.
    enum PairingState: Equatable, Sendable {
        /// The `register` frame is out; nothing has come back.
        case awaitingResponse
        /// The TV has put the accept prompt on screen and is waiting for a human
        /// to pick up the remote. A distinct state because it is the one the UI
        /// has to say something about — "look at the TV" — and because it can
        /// last as long as a walk to the sofa.
        case promptShown
        /// Paired. The key must be stored and sent on every future connection.
        case registered(clientKey: String)
        /// The TV said no. Carries the TV's own words where it gave any.
        case refused(reason: String)

        var isFinished: Bool {
            switch self {
            case .awaitingResponse, .promptShown: return false
            case .registered, .refused: return true
            }
        }
    }

    /// The pairing conversation, as a value.
    ///
    /// Pure and step-wise so every branch is a unit test: acceptance, the prompt
    /// arriving first, outright refusal, a frame for somebody else's request
    /// arriving in the middle, and a stale key producing a *new* key that must be
    /// adopted rather than compared against the old one.
    struct Pairing: Equatable, Sendable {
        /// The id the `register` frame was sent with. Frames carrying any other
        /// id belong to another request and must not move this state machine —
        /// that is the whole of point 2 in the header, applied to pairing.
        let requestID: String
        private(set) var state: PairingState

        init(requestID: String) {
            self.requestID = requestID
            self.state = .awaitingResponse
        }

        /// Feeds one raw frame in. Returns the state afterwards, which is
        /// unchanged for anything that is not part of this conversation.
        ///
        /// Ordered by what each frame means, not by how likely it is:
        ///   - anything unparseable, or addressed to another id, is ignored;
        ///   - `registered` with a usable key wins, wherever it arrives;
        ///   - `error`, or a `response` that says the pairing was rejected, ends
        ///     it;
        ///   - `response` carrying `pairingType` is the prompt going up, which is
        ///     *not* an answer and must not end the wait.
        @discardableResult
        mutating func ingest(_ text: String) -> PairingState {
            guard !state.isFinished, let reply = Self.matching(text, requestID: requestID) else {
                return state
            }

            if reply.type == "registered" || reply.payload?["client-key"] != nil {
                // An empty key is not a key. Accepting one would store a
                // credential that fails every future connection while looking
                // exactly like a successful pairing.
                if let key = reply.payload?["client-key"]?.stringValue, !key.isEmpty {
                    state = .registered(clientKey: key)
                    return state
                }
                state = .refused(reason: String(localized: "The TV completed pairing without sending a key."))
                return state
            }

            if let error = reply.error, !error.isEmpty {
                state = .refused(reason: error)
                return state
            }

            if reply.type == "error" {
                state = .refused(reason: String(localized: "The TV refused the pairing request."))
                return state
            }

            if reply.payload?["pairingType"] != nil {
                state = .promptShown
                return state
            }

            return state
        }

        /// Marks the conversation refused because nothing arrived in time. The
        /// UI needs the same shape for "you did not answer the prompt" as for
        /// "the TV said no", and a timeout is the far more common of the two.
        mutating func timedOut() {
            guard !state.isFinished else { return }
            state = .refused(reason: String(localized: "The TV did not answer the pairing request in time."))
        }

        private static func matching(_ text: String, requestID: String) -> Reply? {
            guard let reply = reply(from: text) else { return nil }
            // A frame with no id at all is accepted only while it is clearly part
            // of this conversation (`registered` carries one in practice, but
            // firmware has been seen to omit it). Anything with a *different*
            // id belongs to somebody else.
            guard reply.id.isEmpty || reply.id == requestID else { return nil }
            return reply
        }
    }

    /// What a receive that brought nothing means for a registration wait.
    enum PairingSilence: Equatable, Sendable {
        /// Keep waiting until the deadline. The answer is a person walking to
        /// the sofa to press *accept*, so one elapsed receive means nothing.
        case keepsWaiting
        /// Stop. The connection already carried a client key, so a TV that is
        /// answering at all should have answered by now, and the caller is a
        /// write somebody is watching a slider for.
        case ends
    }

    /// Waits for a registration to finish, bounded on both sides.
    ///
    /// A function over the seam rather than a hand-rolled loop per call site,
    /// because the bound is the half that is easy to omit and impossible to see
    /// afterwards. `ingest` moves the state machine only for frames that belong
    /// to *this* conversation, so anything that answers and then keeps talking —
    /// a stale DHCP lease on webOS's plaintext port 3000, some other box that
    /// chats — leaves the state non-terminal for as long as it cares to keep
    /// sending. A loop that exits only when `receive` throws therefore never
    /// exits at all, and that loop ran before **every** webOS write, not only at
    /// pairing: one such device would wedge the television forever.
    ///
    /// Two bounds, because the two failure shapes are different: `timeout` covers
    /// a device that talks and never finishes, `onSilence` covers one that says
    /// nothing at all.
    ///
    /// `now` is injected so the deadline is a unit test rather than a stopwatch.
    static func awaitPairing(
        _ pairing: Pairing,
        on transport: TVTransport,
        timeout: TimeInterval,
        receiveTimeout: TimeInterval = TVTimeout.request,
        onSilence: PairingSilence = .keepsWaiting,
        now: @Sendable () -> Date = { Date() }
    ) async -> Pairing {
        var pairing = pairing
        let deadline = now().addingTimeInterval(timeout)
        while !pairing.state.isFinished, now() < deadline {
            guard let text = try? await transport.receive(timeout: receiveTimeout) else {
                if onSilence == .ends { break }
                continue
            }
            pairing.ingest(text)
        }
        return pairing
    }

    // MARK: - Correlation

    /// Matches replies to the requests that are still outstanding.
    ///
    /// A dictionary and two methods, rather than "read the next frame and assume
    /// it is mine". The TV answers when each service behind a URI finishes, so
    /// two requests in flight can come back in either order, and a subscription
    /// can push a frame in between them. `take` returns the tag the caller
    /// registered, or nil for a frame nobody is waiting for — which is a normal
    /// event, not an error.
    struct Correlator<Tag: Equatable & Sendable>: Sendable {
        private var outstanding: [String: Tag] = [:]

        init() {}

        var pendingCount: Int { outstanding.count }

        mutating func expect(_ id: String, tag: Tag) {
            outstanding[id] = tag
        }

        /// The tag for this frame's id, removing it from the outstanding set.
        mutating func take(_ reply: Reply) -> Tag? {
            outstanding.removeValue(forKey: reply.id)
        }

        /// Drops everything, for a socket that went away. Every caller waiting on
        /// one of these has to be failed, not left holding an id that will never
        /// come back.
        mutating func drainAll() -> [Tag] {
            let tags = Array(outstanding.values)
            outstanding.removeAll()
            return tags
        }
    }

    // MARK: - Commands

    /// Audio, power and input, as frames.
    ///
    /// Free functions rather than an enum of commands because each one has a
    /// different payload shape and the enum would only be a second name for the
    /// URI. `volume` is clamped here rather than at the call site: the TV accepts
    /// out-of-range values and does something unhelpful with them.
    static func setVolumeFrame(id: String, percent: Double) -> String? {
        requestFrame(
            id: id, uri: URI.setVolume,
            payload: .object(["volume": .number(Double(clampedPercent(percent)))])
        )
    }

    static func setMuteFrame(id: String, muted: Bool) -> String? {
        requestFrame(id: id, uri: URI.setMute, payload: .object(["mute": .bool(muted)]))
    }

    static func switchInputFrame(id: String, inputID: String) -> String? {
        requestFrame(id: id, uri: URI.switchInput, payload: .object(["inputId": .string(inputID)]))
    }

    static func powerOffFrame(id: String) -> String? {
        requestFrame(id: id, uri: URI.turnOff)
    }

    static func pictureSettingsFrame(id: String) -> String? {
        requestFrame(
            id: id, uri: URI.systemSettings,
            payload: .object([
                "category": .string("picture"),
                "keys": .array([
                    .string("backlight"), .string("brightness"),
                    .string("contrast"), .string("pictureMode")
                ])
            ])
        )
    }

    /// 0–100, as a whole number. Written once so the clamp cannot differ between
    /// the volume path and the backlight path.
    static func clampedPercent(_ percent: Double) -> Int {
        guard percent.isFinite else { return 0 }
        return Int(min(max(percent, 0), 100).rounded())
    }

    // MARK: - Brightness (the alert round trip)

    /// The first half of a backlight write: an alert whose handlers carry the
    /// Luna settings call.
    ///
    /// The alert is never meant to be seen. `message` is a single space because
    /// an empty string is rejected, and the whole thing is closed by
    /// `closeAlertFrame` the moment the TV hands back an id — see this file's
    /// header for why the write has to be laundered through a notification at
    /// all.
    static func backlightAlertFrame(id: String, percent: Double) -> String? {
        let params = JSONValue.object([
            "category": .string("picture"),
            "settings": .object(["backlight": .number(Double(clampedPercent(percent)))])
        ])
        let handler = JSONValue.object([
            "uri": .string(URI.lunaSetSystemSettings),
            "params": params
        ])
        let payload = JSONValue.object([
            "message": .string(" "),
            "buttons": .array([
                .object([
                    "label": .string(""),
                    "onClick": .string(URI.lunaSetSystemSettings),
                    "params": params
                ])
            ]),
            "onclose": handler,
            "onfail": handler
        ])
        return requestFrame(id: id, uri: URI.createAlert, payload: payload)
    }

    /// The second half: close the alert the TV just created.
    static func closeAlertFrame(id: String, alertID: String) -> String? {
        requestFrame(id: id, uri: URI.closeAlert, payload: .object(["alertId": .string(alertID)]))
    }

    /// The alert id out of a `createAlert` reply, or nil if the TV refused.
    static func alertID(from reply: Reply) -> String? {
        guard reply.isSuccess else { return nil }
        return reply.payload?["alertId"]?.stringValue
    }

    // MARK: - Reading state back

    /// The picture settings a `getSystemSettings` reply carries.
    ///
    /// `backlight` is the one that moves the panel's light output; `brightness`
    /// on a webOS TV is the black level, and conflating the two is why some
    /// remote apps appear to do nothing. Crisp drives `backlight` and reports the
    /// rest for diagnostics only.
    struct PictureSettings: Equatable, Sendable {
        var backlight: Double?
        var brightness: Double?
        var contrast: Double?
        var pictureMode: String?
    }

    static func pictureSettings(from reply: Reply) -> PictureSettings? {
        guard reply.isSuccess, let settings = reply.payload?["settings"]?.objectValue else { return nil }
        return PictureSettings(
            backlight: settings["backlight"]?.numberValue,
            brightness: settings["brightness"]?.numberValue,
            contrast: settings["contrast"]?.numberValue,
            pictureMode: settings["pictureMode"]?.stringValue
        )
    }

    static func volume(from reply: Reply) -> Double? {
        guard reply.isSuccess else { return nil }
        return reply.payload?["volume"]?.numberValue
    }

    static func isMuted(from reply: Reply) -> Bool? {
        guard reply.isSuccess else { return nil }
        return reply.payload?["mute"]?.boolValue
    }

    static func modelName(from reply: Reply) -> String? {
        guard reply.isSuccess else { return nil }
        return reply.payload?["modelName"]?.stringValue
    }

    /// One entry from `getExternalInputList`.
    struct ExternalInput: Equatable, Sendable {
        /// What `switchInput` takes: `HDMI_1`, `HDMI_2`, `COMP_1`.
        let id: String
        /// What the TV calls it, which is often what the user renamed the port to
        /// on the TV itself — better than any label this app could invent.
        let label: String
        let appID: String?
        let isConnected: Bool?
    }

    /// The input list, dropping entries with no usable id.
    ///
    /// An entry with no `id` cannot be switched to, so offering it would be a
    /// menu item that does nothing. Everything else is kept, including inputs the
    /// TV says nothing is connected to: `connected` is the TV's guess and it is
    /// wrong often enough that filtering on it would hide real ports.
    static func externalInputs(from reply: Reply) -> [ExternalInput] {
        guard reply.isSuccess, let devices = reply.payload?["devices"]?.arrayValue else { return [] }
        return devices.compactMap { device in
            guard let id = device["id"]?.stringValue, !id.isEmpty else { return nil }
            return ExternalInput(
                id: id,
                label: device["label"]?.stringValue ?? id,
                appID: device["appId"]?.stringValue,
                isConnected: device["connected"]?.looseBoolValue
            )
        }
    }

    // MARK: - Sound output

    /// Sound outputs that route audio away from the TV's own speakers.
    ///
    /// `setVolume` is *silently ignored* while one of these is active — the call
    /// succeeds, `returnValue` is true, and nothing changes, because the volume
    /// belongs to the soundbar. `volumeUp`/`volumeDown` still work, since those
    /// are relayed. Crisp checks and says so rather than leaving a slider that
    /// reports success and does nothing.
    static let externalSoundOutputs: Set<String> = [
        "external_arc", "external_optical", "external_speaker", "external_hdmi",
        "lineout", "headphone", "bt_soundbar", "soundbar", "tv_external_speaker"
    ]

    static func soundOutput(from reply: Reply) -> String? {
        guard reply.isSuccess else { return nil }
        return reply.payload?["soundOutput"]?.stringValue
    }

    /// Whether an absolute volume write will be swallowed by this sound output.
    /// Unknown outputs answer `false`: guessing that an unrecognised name is
    /// external would disable the slider on a TV where it works.
    static func absoluteVolumeIsIgnored(soundOutput: String?) -> Bool {
        guard let soundOutput else { return false }
        return externalSoundOutputs.contains(soundOutput.lowercased())
    }

    /// What to tell the user when it is.
    static func externalAudioNote(soundOutput: String) -> String {
        String(localized: """
            This TV's sound is going to \(soundOutput), so it ignores an exact volume. \
            Crisp steps the volume up and down instead.
            """)
    }
}
