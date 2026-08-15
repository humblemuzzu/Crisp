import Foundation

// Samsung Tizen remote control, as pure text.
//
// Same split as `WebOSSSAP`: this file builds strings and reads strings, and
// never opens a socket. `SamsungTizenTransport` is the socket.
//
// ---------------------------------------------------------------------------
// THE PROTOCOL, AND WHERE IT DIFFERS FROM LG'S IN WAYS THAT MATTER
// ---------------------------------------------------------------------------
// **It is a remote control, not an API.** Where webOS has `setVolume(30)`,
// Tizen has `KEY_VOLUP`. Almost everything is a key press: fire and forget, no
// reply, no read-back. That single fact is why `TVFeatureRegistry` marks half of
// Samsung's features `.writeOnly` and why the panel shows buttons where LG gets
// sliders.
//
// **Detect before connecting.** `GET http://<ip>:8001/api/v2/` returns a small
// JSON document describing the TV, and its `TokenAuthSupport` field decides
// everything after it: `true` means port 8002 with TLS and a token, `false` means
// plain 8001 and no token at all. Connecting to the wrong one fails in a way that
// looks like the TV is off.
//
// **Every boolean in that document is a string.** `"TokenAuthSupport":"true"`,
// not `true`. A parser that expects real booleans decides every TV needs no token
// and then connects to the wrong port forever. `JSONValue.looseBoolValue` exists
// for this exact field.
//
// **The token arrives in one of two places.** Current firmware puts it at
// `data.token`; older models put it at `data.clients[0].attributes.token` and
// send nothing at `data.token`. Both are read, because a client that reads only
// the first pairs successfully with a modern TV and silently never pairs with an
// older one.
//
// **Keys must be paced.** Faster than roughly one per second and the TV drops the
// connection — not the key, the whole socket. `KeyRateLimiter` below is that
// rule, as a value with an injected clock so it is a test rather than a stopwatch.
//
// **Brightness is not reachable, at all.** Tizen's brightness API is for apps
// running *on* the television; the UPnP brightness variables only ever existed on
// pre-2016 models. There is no key sequence that counts either — walking the OSD
// with arrow keys is not control, it is guessing at a menu this app cannot see.
// So `TVFeatureRegistry.support(.brightness, on: .tizen)` is `.unsupported`, the
// panel shows a disabled control with the reason next to it, and nothing here
// pretends otherwise.
//
// **Absolute volume is possible, through a different protocol entirely:** UPnP
// `RenderingControl` over SOAP. The control URL is *discovered*, never assumed —
// real TVs serve it on 9197 and on 7676 with different paths, so a hardcoded port
// is a feature that works on the author's TV and nobody else's.
//
// Pure Foundation. Compiles into `CrispTests` and `crispctl` (AGENTS.md §3.6).

enum TizenRemote {

    // MARK: - Ports and detection

    /// Plain WebSocket, and the port the REST detection endpoint lives on.
    static let plainPort = 8001
    /// TLS WebSocket, the only port that accepts a token.
    static let securePort = 8002

    static func isEncrypted(port: Int) -> Bool { port == securePort }

    /// `http://<host>:8001/api/v2/` — the detection endpoint.
    static func deviceInfoURL(host: String) -> URL? {
        URL(string: "http://\(host):\(plainPort)/api/v2/")
    }

    /// What `GET /api/v2/` says about a TV.
    ///
    /// Every field is optional because every field has been seen missing on some
    /// firmware, and a missing `name` is not a reason to refuse to talk to a
    /// television.
    struct DeviceInfo: Equatable, Sendable {
        /// The stable identity, `uuid:…`. This is what a device record is keyed
        /// on — never the address (see `TVDeviceID`).
        let id: String
        let name: String?
        let model: String?
        /// `Tizen` on every TV this supports. Reported so a non-Samsung device
        /// answering on 8001 can be refused rather than half-driven.
        let os: String?
        /// Whether the TV wants a token, which decides the port. `nil` means the
        /// field was absent or unreadable — treated as "yes" by
        /// `preferredPort`, because trying the secure path on a TV that does not
        /// want it fails cleanly, while skipping it on a TV that does leaves the
        /// user unable to pair.
        let tokenAuthSupport: Bool?
        /// `on`, `standby`. The one piece of Samsung state that is readable
        /// without a socket at all.
        let powerState: String?
        let wifiMac: String?

        var isSupported: Bool { (os ?? "Tizen").caseInsensitiveCompare("Tizen") == .orderedSame }
        var isOn: Bool? {
            guard let powerState else { return nil }
            return powerState.caseInsensitiveCompare("on") == .orderedSame
        }
    }

    /// Parses the detection document. Total: anything that is not one is nil.
    ///
    /// `id` is required and everything else is not, because `id` is the thing the
    /// device record is keyed on: a TV that will not tell Crisp who it is cannot
    /// be persisted safely, and persisting it under its address is the bug this
    /// refuses to have.
    static func deviceInfo(from text: String) -> DeviceInfo? {
        guard let root = JSONValue.parse(text) else { return nil }
        let device = root["device"]
        guard let id = (root["id"]?.stringValue ?? device?["id"]?.stringValue ?? device?["udn"]?.stringValue),
              !id.isEmpty else { return nil }
        return DeviceInfo(
            id: id,
            name: root["name"]?.stringValue ?? device?["name"]?.stringValue,
            model: device?["modelName"]?.stringValue ?? root["type"]?.stringValue,
            os: device?["OS"]?.stringValue,
            tokenAuthSupport: device?["TokenAuthSupport"]?.looseBoolValue,
            powerState: device?["PowerState"]?.stringValue,
            wifiMac: device?["wifiMac"]?.stringValue
        )
    }

    /// Which WebSocket port to use for a TV.
    ///
    /// Unknown means secure. Getting this backwards is asymmetric: a TV that
    /// wants a token and is offered 8001 refuses in a way that looks like a dead
    /// TV, while a TV that does not want one and is offered 8002 simply fails to
    /// connect and the caller falls back.
    static func preferredPort(tokenAuthSupport: Bool?) -> Int {
        (tokenAuthSupport ?? true) ? securePort : plainPort
    }

    // MARK: - The control socket URL

    /// The app name the TV shows in its "allow this device?" prompt and in its
    /// own list of paired remotes. Base64 on the wire, which is a wire format
    /// detail rather than any kind of encoding of a secret.
    static let appName = "Crisp"

    /// `wss://<host>:8002/api/v2/channels/samsung.remote.control?name=…&token=…`
    ///
    /// The token is only ever attached on the secure port. Sending it to 8001
    /// would put a credential in a URL on a plaintext connection for no benefit
    /// whatsoever — 8001 does not use tokens.
    static func controlURL(host: String, port: Int, token: String?, name: String = appName) -> URL? {
        var components = URLComponents()
        components.scheme = isEncrypted(port: port) ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/api/v2/channels/samsung.remote.control"
        var items = [URLQueryItem(name: "name", value: base64Name(name))]
        if isEncrypted(port: port), let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        return components.url
    }

    static func base64Name(_ name: String) -> String {
        Data(name.utf8).base64EncodedString()
    }

    // MARK: - Channel events

    /// What the TV said on the control channel.
    enum ChannelEvent: Equatable, Sendable {
        /// Connected, and here is the token to store. On the plain port there is
        /// no token, hence the optional — a connection is still a connection.
        case connected(token: String?)
        /// The user dismissed the on-screen prompt, or the TV has this Mac on its
        /// deny list. The socket closes immediately afterwards.
        case unauthorized
        /// A timeout the TV reports rather than one Crisp measures.
        case timeout
        /// Something else on the channel. Kept as a case rather than discarded so
        /// a caller can log what an unfamiliar firmware sends without this file
        /// having to know what it means.
        case other(String)
    }

    /// Reads one channel frame.
    ///
    /// The token hunt is the interesting part: `data.token` on current firmware,
    /// `data.clients[0].attributes.token` on older models. Both are checked, in
    /// that order, and a connect with neither is still a connect — the plain port
    /// issues no token at all.
    static func channelEvent(from text: String) -> ChannelEvent? {
        guard let root = JSONValue.parse(text), let event = root["event"]?.stringValue else { return nil }
        switch event {
        case "ms.channel.connect":
            return .connected(token: token(from: root["data"]))
        case "ms.channel.unauthorized":
            return .unauthorized
        case "ms.channel.timeOut":
            return .timeout
        default:
            return .other(event)
        }
    }

    /// The token out of a `ms.channel.connect` payload, from either location.
    static func token(from data: JSONValue?) -> String? {
        guard let data else { return nil }
        if let direct = data["token"]?.stringValue, !direct.isEmpty { return direct }
        // The older shape. `clients` is an array of every device the TV currently
        // has on the channel; the first one is this connection.
        guard let clients = data["clients"]?.arrayValue else { return nil }
        for client in clients {
            if let token = client["attributes"]?["token"]?.stringValue, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    // MARK: - Keys

    /// The remote keys Crisp sends. Deliberately short: every one of these maps
    /// to a `TVFeatureID`, and a key with no feature behind it is a key nothing
    /// can explain to the user.
    enum Key: String, Equatable, Sendable, CaseIterable {
        case volumeUp = "KEY_VOLUP"
        case volumeDown = "KEY_VOLDOWN"
        case mute = "KEY_MUTE"
        case power = "KEY_POWER"
        /// Opens the source list. The portable way to change input: it works on
        /// every model, at the cost of needing the user to look at the TV.
        case source = "KEY_SOURCE"
        case hdmi = "KEY_HDMI"
        case hdmi1 = "KEY_HDMI1"
        case hdmi2 = "KEY_HDMI2"
        case hdmi3 = "KEY_HDMI3"
        case hdmi4 = "KEY_HDMI4"
    }

    /// The direct-HDMI keys, in port order.
    ///
    /// They work on most 2016-and-later models and are model-quirky enough that
    /// `KEY_SOURCE` stays on offer as the fallback that always works. Crisp
    /// cannot verify which one landed — Samsung does not report the current input
    /// locally — so this is exactly the destructive case `TVFeatureRegistry`
    /// marks: a wrong guess leaves a black screen the Mac cannot read or undo.
    static let hdmiKeys: [Key] = [.hdmi1, .hdmi2, .hdmi3, .hdmi4]

    static func hdmiKey(port: Int) -> Key? {
        guard port >= 1, port <= hdmiKeys.count else { return nil }
        return hdmiKeys[port - 1]
    }

    /// One key press, framed.
    ///
    /// `Option` is the string `"false"` and not the boolean `false`; the TV
    /// ignores frames that get that wrong, silently.
    static func keyFrame(_ key: Key) -> String? {
        JSONValue.object([
            "method": .string("ms.remote.control"),
            "params": .object([
                "Cmd": .string("Click"),
                "DataOfCmd": .string(key.rawValue),
                "Option": .string("false"),
                "TypeOfRemote": .string("SendRemoteKey")
            ])
        ]).serialized()
    }

    // MARK: - Rate limiting

    /// One key per second, as a value.
    ///
    /// Sending faster does not drop the extra keys — it drops the *connection*,
    /// which then has to be re-established and, on a TV that has forgotten the
    /// token, re-approved on screen. So this is not a politeness throttle, it is
    /// what stops a volume drag from un-pairing the television.
    ///
    /// The clock is a parameter rather than `Date()` read inside, which is what
    /// makes "three keys are spaced a second apart" a unit test instead of a
    /// three-second one.
    struct KeyRateLimiter: Equatable, Sendable {
        /// Measured minimum spacing. One second is the figure every working
        /// client settles on; below about that, connections start dropping.
        static let minimumInterval: TimeInterval = 1.0

        private var nextAllowed: Date?

        init() {}

        /// How long to wait before sending a key at `now`, and books the slot.
        ///
        /// Booking inside the same call is deliberate: a caller that asked "how
        /// long?" and then forgot to record the send would compute zero for the
        /// next one too, which is precisely the burst this exists to prevent.
        mutating func reserve(at now: Date, interval: TimeInterval = minimumInterval) -> TimeInterval {
            let earliest = nextAllowed ?? now
            let sendAt = max(earliest, now)
            nextAllowed = sendAt.addingTimeInterval(interval)
            return sendAt.timeIntervalSince(now)
        }

        /// Forgets the pacing, for a socket that has been re-opened. A fresh
        /// connection has no history to be paced against, and carrying the old
        /// one over would delay the first key of every session.
        mutating func reset() {
            nextAllowed = nil
        }
    }

    // MARK: - UPnP RenderingControl (absolute volume)

    /// Everything about the SOAP path, which is a different protocol on a
    /// different port from the remote-control socket and shares nothing with it.
    enum UPnP {
        static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"

        /// The SSDP search target for the device description.
        static let searchTarget = "urn:schemas-upnp-org:device:MediaRenderer:1"

        /// The `RenderingControl` control URL out of a device description
        /// document, resolved against the URL the description came from.
        ///
        /// **Discovered, never assumed.** Real Samsung TVs serve this on 9197
        /// *and* on 7676, at different paths, depending on model and firmware. A
        /// hardcoded port is a feature that works on one television.
        ///
        /// The scan is deliberate string work rather than an XML parser: the
        /// documents are small, malformed on some firmware, and the only thing
        /// needed from them is one element inside one sibling of a known type.
        /// A tolerant scan reads a broken document; a strict parser refuses it.
        static func controlURL(fromDescription xml: String, baseURL: URL) -> URL? {
            for block in serviceBlocks(in: xml) {
                guard block.contains(renderingControl) || block.contains("RenderingControl") else { continue }
                guard let path = element("controlURL", in: block), !path.isEmpty else { continue }
                return URL(string: path, relativeTo: baseURL)?.absoluteURL
            }
            return nil
        }

        /// The text between `<name>` and `</name>`, first occurrence.
        static func element(_ name: String, in xml: String) -> String? {
            // Namespace prefixes (`<u:controlURL>`) appear in the wild; matching
            // on the closing bracket rather than on `<name>` exactly keeps them
            // readable without a full parser.
            guard let openRange = xml.range(of: "<\(name)>") ?? xml.range(of: ":\(name)>") else { return nil }
            guard let closeRange = xml.range(
                of: "</", range: openRange.upperBound..<xml.endIndex
            ) else { return nil }
            return String(xml[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func serviceBlocks(in xml: String) -> [String] {
            var blocks: [String] = []
            var cursor = xml.startIndex
            while let open = xml.range(of: "<service>", range: cursor..<xml.endIndex),
                  let close = xml.range(of: "</service>", range: open.upperBound..<xml.endIndex) {
                blocks.append(String(xml[open.upperBound..<close.lowerBound]))
                cursor = close.upperBound
            }
            return blocks
        }

        /// The SOAP action header value for one method.
        static func soapAction(_ method: String) -> String {
            "\"\(renderingControl)#\(method)\""
        }

        /// `SetVolume`, master channel, instance 0.
        static func setVolumeBody(percent: Double) -> String {
            envelope(
                method: "SetVolume",
                arguments: [
                    ("InstanceID", "0"),
                    ("Channel", "Master"),
                    ("DesiredVolume", String(WebOSSSAP.clampedPercent(percent)))
                ]
            )
        }

        static func getVolumeBody() -> String {
            envelope(method: "GetVolume", arguments: [("InstanceID", "0"), ("Channel", "Master")])
        }

        static func setMuteBody(_ muted: Bool) -> String {
            envelope(
                method: "SetMute",
                arguments: [
                    ("InstanceID", "0"),
                    ("Channel", "Master"),
                    ("DesiredMute", muted ? "1" : "0")
                ]
            )
        }

        /// The volume out of a `GetVolume` response.
        static func volume(fromResponse xml: String) -> Double? {
            guard let text = element("CurrentVolume", in: xml), let value = Double(text) else { return nil }
            return min(max(value, 0), 100)
        }

        private static func envelope(method: String, arguments: [(String, String)]) -> String {
            let body = arguments.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
            return """
                <?xml version="1.0" encoding="utf-8"?>
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
                s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
                <s:Body><u:\(method) xmlns:u="\(renderingControl)">\(body)</u:\(method)></s:Body>\
                </s:Envelope>
                """
        }
    }
}
