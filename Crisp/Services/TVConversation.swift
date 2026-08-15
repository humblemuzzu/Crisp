import Foundation

/// One conversation with one television: connect, authenticate, do the thing,
/// hang up.
///
/// Split out of `TVDeviceService` because there are two callers and they must not
/// drift: the app (which owns a device list, a UI and the write gate) and
/// `crispctl` (which owns none of those and links no AppKit). A second copy of
/// "how do you set an LG's backlight" would be wrong in one of them within a
/// release.
///
/// **It holds no policy.** Whether an action is allowed is `TVWriteGate`; this is
/// only reachable from `TVDeviceService.perform(_:)`, which unwraps an approval
/// token to get here. `crispctl` reaches it after its own `confirmDestructiveTV`
/// prompt, on the same terms the CLI has always used for destructive DDC codes —
/// see that function for why the CLI does not reproduce the app's gate.
///
/// **One connection per action.** Each call opens a socket, does its exchange and
/// closes. It costs a round trip and buys the failure mode that matters: a TV
/// that is off, unplugged or on another subnet is one failed connect with a
/// sentence attached, never a cached socket somebody has to notice is wedged
/// (AGENTS.md rule #4).
enum TVConversation {

    /// What one exchange did, in words the panel, the CLI and an automation
    /// outcome can all print.
    enum Result: Equatable, Sendable {
        case success(String)
        case failure(String)

        var didSucceed: Bool {
            if case .success = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .success(let text), .failure(let text): return text
            }
        }
    }

    /// What Crisp read back. Everything is optional because every platform
    /// answers a different subset, and a `nil` here means "not readable", never
    /// "zero" — the distinction the Samsung input case depends on.
    struct Readback: Equatable, Sendable {
        var isReachable = true
        var backlight: Double?
        var volume: Double?
        var isMuted: Bool?
        var inputs: [WebOSSSAP.ExternalInput] = []
        var externalAudioNote: String?
    }

    // MARK: - Applying

    /// Performs one action on one TV.
    ///
    /// The feature and value arrive already checked and clamped: in the app they
    /// come off a `TVWriteGate.ApprovedTVAction`, in the CLI off a parsed
    /// argument plus the destructive prompt. Nothing here re-decides whether the
    /// action was allowed — a second, differently-worded copy of that rule is
    /// exactly how two policies get born.
    static func apply(
        feature: TVFeatureID,
        value: TVActionValue,
        to device: TVDevice,
        credentials: TVCredentialStore,
        rateLimiter: TizenKeyPacer
    ) async -> Result {
        do {
            switch device.platform {
            case .webOS:
                try await applyWebOS(feature: feature, value: value, to: device, credentials: credentials)
            case .tizen:
                try await applyTizen(
                    feature: feature, value: value, to: device,
                    credentials: credentials, rateLimiter: rateLimiter
                )
            }
            return .success(describe(feature: feature, value: value, on: device))
        } catch let error as TVTransportError {
            return .failure("\(device.name): \(error.message)")
        } catch {
            return .failure("\(device.name): \(TVTransportError.unreachable(device.host).message)")
        }
    }

    private static func applyWebOS(
        feature: TVFeatureID, value: TVActionValue, to device: TVDevice, credentials: TVCredentialStore
    ) async throws {
        let transport = LGWebOSTransport(pinnedCertificate: credentials.pinnedCertificate(for: device.id))
        defer { transport.close() }
        _ = try await transport.open(
            host: device.host,
            credential: credentials.credential(for: device.id),
            timeout: TVTimeout.connect
        )
        var ids = WebOSSSAP.IDGenerator()
        try await authenticateWebOS(transport, device: device, credentials: credentials, ids: &ids)

        switch feature {
        case .brightness:
            guard let percent = value.percentValue else { return }
            try await writeWebOSBacklight(transport, ids: &ids, percent: percent)
        case .volume:
            guard let percent = value.percentValue,
                  let frame = WebOSSSAP.setVolumeFrame(id: ids.next("volume"), percent: percent) else { return }
            try await transport.send(frame)
            _ = try? await transport.receive(timeout: TVTimeout.request)
        case .mute:
            guard let muted = value.flagValue,
                  let frame = WebOSSSAP.setMuteFrame(id: ids.next("mute"), muted: muted) else { return }
            try await transport.send(frame)
            _ = try? await transport.receive(timeout: TVTimeout.request)
        case .input:
            guard let code = value.codeValue,
                  let frame = WebOSSSAP.switchInputFrame(id: ids.next("input"), inputID: code) else { return }
            try await transport.send(frame)
            _ = try? await transport.receive(timeout: TVTimeout.request)
        case .power:
            // Off only, and fire and forget: the TV takes the socket down with
            // it, so waiting for a reply is waiting for a device that is
            // switching itself off. Turning one *on* needs Wake-on-LAN, a
            // different mechanism at a different layer, and is not pretended at.
            guard value.flagValue == false,
                  let frame = WebOSSSAP.powerOffFrame(id: ids.next("power")) else { return }
            try await transport.send(frame)
        }
    }

    /// Registers with the stored client key.
    ///
    /// A stale key is not an error: the TV shows its prompt again and issues a
    /// new one, which is adopted and stored. That is why there is no "the key was
    /// rejected" branch — the protocol has no such reply (`WebOSSSAP.Pairing`).
    ///
    /// Bounded by the same deadline as `pairWebOS`, and for a sharper reason than
    /// pairing has: this runs before *every* webOS write. Port 3000 is tried
    /// first and is plaintext, so `TVTrust` can vouch for nothing there — a
    /// device that is not the television, answering at that address and sending
    /// frames that never satisfy the terminal condition, would otherwise wedge
    /// this TV's every future write. `WebOSSSAP.awaitPairing` owns both bounds.
    private static func authenticateWebOS(
        _ transport: TVTransport,
        device: TVDevice,
        credentials: TVCredentialStore,
        ids: inout WebOSSSAP.IDGenerator
    ) async throws {
        let registerID = ids.next("register")
        guard let frame = WebOSSSAP.registerFrame(
            id: registerID, clientKey: credentials.credential(for: device.id)
        ) else {
            throw TVTransportError.malformedResponse("the registration frame could not be built")
        }
        try await transport.send(frame)

        // `.ends` keeps the previous behaviour for the ordinary case: a TV that
        // holds a key and says nothing is a failed write in one request timeout,
        // not a minute of a dead slider. The deadline is only reached by a device
        // that keeps talking, which is the case that used to be unbounded.
        let pairing = await WebOSSSAP.awaitPairing(
            WebOSSSAP.Pairing(requestID: registerID),
            on: transport,
            timeout: TVTimeout.pairing,
            onSilence: .ends
        )
        switch pairing.state {
        case .registered(let key):
            if key != credentials.credential(for: device.id) {
                credentials.set(key, for: device.id, kind: .credential)
            }
        case .refused(let reason):
            throw TVTransportError.malformedResponse(reason)
        case .awaitingResponse, .promptShown:
            throw TVTransportError.timedOut
        }
    }

    /// The createAlert / closeAlert round trip. `WebOSSSAP`'s header explains why
    /// a backlight write has to be laundered through a notification at all.
    private static func writeWebOSBacklight(
        _ transport: TVTransport, ids: inout WebOSSSAP.IDGenerator, percent: Double
    ) async throws {
        let request = ids.next("alert")
        guard let create = WebOSSSAP.backlightAlertFrame(id: request, percent: percent) else { return }
        try await transport.send(create)
        guard let text = try? await transport.receive(timeout: TVTimeout.request),
              let reply = WebOSSSAP.reply(from: text),
              reply.id == request,
              let alertID = WebOSSSAP.alertID(from: reply) else {
            // Firmware may have closed this path off. Reported honestly rather
            // than swallowed: a slider that does nothing and says nothing is the
            // exact failure this fork exists to stop.
            throw TVTransportError.malformedResponse(
                String(localized: "this TV's firmware did not accept the brightness command")
            )
        }
        if let close = WebOSSSAP.closeAlertFrame(id: ids.next("alert"), alertID: alertID) {
            try await transport.send(close)
        }
    }

    private static func applyTizen(
        feature: TVFeatureID,
        value: TVActionValue,
        to device: TVDevice,
        credentials: TVCredentialStore,
        rateLimiter: TizenKeyPacer
    ) async throws {
        // Absolute volume is a different protocol entirely (UPnP SOAP over HTTP)
        // and is the only Samsung path that is not a remote-key press.
        if feature == .volume, let percent = value.percentValue,
           let control = await volumeControlURL(for: device) {
            try await sendSOAP(
                to: control, action: "SetVolume", body: TizenRemote.UPnP.setVolumeBody(percent: percent)
            )
            return
        }

        guard let key = tizenKey(feature: feature, value: value) else {
            throw TVTransportError.malformedResponse(
                String(localized: "this action has no remote key on a Samsung TV")
            )
        }

        let info = await tizenDeviceInfo(host: device.host)
        let transport = SamsungTizenTransport(
            pinnedCertificate: credentials.pinnedCertificate(for: device.id),
            tokenAuthSupport: info?.tokenAuthSupport
        )
        defer { transport.close() }
        _ = try await transport.open(
            host: device.host,
            credential: credentials.credential(for: device.id),
            timeout: TVTimeout.connect
        )
        // The connect event may carry a refreshed token; storing it keeps a TV
        // that rotates tokens from silently needing a re-pair.
        if let text = try? await transport.receive(timeout: TVTimeout.request),
           case .connected(let token)? = TizenRemote.channelEvent(from: text),
           let token, token != credentials.credential(for: device.id) {
            credentials.set(token, for: device.id, kind: .credential)
        }

        guard let frame = TizenRemote.keyFrame(key) else { return }
        // The pacing is per *television*, not per connection: each action opens
        // its own socket, so a per-connection limiter would reset every time and
        // permit exactly the burst that drops the channel.
        let wait = await rateLimiter.reserve()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        try await transport.send(frame)
    }

    private static func tizenKey(feature: TVFeatureID, value: TVActionValue) -> TizenRemote.Key? {
        switch feature {
        case .mute:
            return .mute
        case .power:
            return value.flagValue == false ? .power : nil
        case .input:
            guard let code = value.codeValue else { return nil }
            // `KEY_SOURCE` is the portable fallback and is what an unrecognised
            // code resolves to: it opens the source list rather than guessing a
            // port, which is the difference between "the user picks" and "the
            // screen goes black with nothing able to read what happened".
            return TizenRemote.Key(rawValue: code) ?? .source
        case .volume:
            // Reached only when UPnP could not be discovered. Stepping is the
            // honest fallback: `KEY_VOLUP`/`KEY_VOLDOWN` are relative, so this
            // nudges rather than claiming to have set an exact level.
            return value.percentValue.map { $0 > 50 ? .volumeUp : .volumeDown }
        case .brightness:
            return nil
        }
    }

    // MARK: - Reading back

    /// Reads what a TV will tell us. Called when the user opens the TV section or
    /// asks for a refresh — never on a timer.
    static func refresh(
        _ device: TVDevice, credentials: TVCredentialStore
    ) async -> (readback: Readback, result: Result) {
        do {
            switch device.platform {
            case .webOS:
                let readback = try await refreshWebOS(device, credentials: credentials)
                return (readback, .success(String(localized: "\(device.name): refreshed")))
            case .tizen:
                let readback = try await refreshTizen(device)
                return (readback, .success(String(localized: "\(device.name): refreshed")))
            }
        } catch let error as TVTransportError {
            return (Readback(isReachable: false), .failure("\(device.name): \(error.message)"))
        } catch {
            return (
                Readback(isReachable: false),
                .failure("\(device.name): \(TVTransportError.unreachable(device.host).message)")
            )
        }
    }

    private static func refreshWebOS(
        _ device: TVDevice, credentials: TVCredentialStore
    ) async throws -> Readback {
        let transport = LGWebOSTransport(pinnedCertificate: credentials.pinnedCertificate(for: device.id))
        defer { transport.close() }
        _ = try await transport.open(
            host: device.host,
            credential: credentials.credential(for: device.id),
            timeout: TVTimeout.connect
        )
        var ids = WebOSSSAP.IDGenerator()
        try await authenticateWebOS(transport, device: device, credentials: credentials, ids: &ids)

        var readback = Readback()
        if let reply = try await exchange(transport, ids: &ids, uri: WebOSSSAP.URI.getVolume, tag: "volume") {
            readback.volume = WebOSSSAP.volume(from: reply)
            readback.isMuted = WebOSSSAP.isMuted(from: reply)
        }
        if let reply = try await exchange(
            transport, ids: &ids, uri: WebOSSSAP.URI.getSoundOutput, tag: "soundout"
        ), let output = WebOSSSAP.soundOutput(from: reply) {
            readback.externalAudioNote = WebOSSSAP.absoluteVolumeIsIgnored(soundOutput: output)
                ? WebOSSSAP.externalAudioNote(soundOutput: output)
                : nil
        }
        if let reply = try await exchange(
            transport, ids: &ids, uri: WebOSSSAP.URI.externalInputList, tag: "inputs"
        ) {
            readback.inputs = WebOSSSAP.externalInputs(from: reply)
        }
        if let reply = try await exchangeFrame(
            transport, id: ids.next("picture"),
            build: { WebOSSSAP.pictureSettingsFrame(id: $0) }
        ) {
            readback.backlight = WebOSSSAP.pictureSettings(from: reply)?.backlight
        }
        return readback
    }

    private static func refreshTizen(_ device: TVDevice) async throws -> Readback {
        guard let info = await tizenDeviceInfo(host: device.host) else {
            throw TVTransportError.unreachable(device.host)
        }
        var readback = Readback()
        readback.isReachable = info.isOn ?? true
        // The current input is deliberately never filled in: Samsung reports it
        // to nothing on the local network, so Crisp says "unknown" rather than
        // showing a port it guessed (`TVUnsupportedReason.tizenInputIsNotReadable`).
        if let control = await volumeControlURL(for: device) {
            readback.volume = await tizenVolume(from: control)
        }
        return readback
    }

    /// One request, waiting for the frame carrying its own id.
    ///
    /// Correlation by id and not by arrival order, because the TV answers when
    /// each service behind a URI finishes and a subscription can push a frame in
    /// between. Bounded, so a TV that answers everything except this request
    /// cannot make the caller wait forever.
    private static func exchange(
        _ transport: TVTransport, ids: inout WebOSSSAP.IDGenerator, uri: String, tag: String
    ) async throws -> WebOSSSAP.Reply? {
        try await exchangeFrame(transport, id: ids.next(tag)) {
            WebOSSSAP.requestFrame(id: $0, uri: uri)
        }
    }

    private static func exchangeFrame(
        _ transport: TVTransport, id: String, build: (String) -> String?
    ) async throws -> WebOSSSAP.Reply? {
        guard let frame = build(id) else { return nil }
        try await transport.send(frame)
        for _ in 0..<4 {
            guard let text = try? await transport.receive(timeout: TVTimeout.request) else { return nil }
            guard let reply = WebOSSSAP.reply(from: text) else { continue }
            if reply.id == id { return reply }
        }
        return nil
    }

    // MARK: - Pairing

    /// What a pairing attempt did.
    enum PairingResult: Equatable, Sendable {
        case paired(TVDevice)
        case refused(reason: String)
    }

    /// Pairs with a TV, storing its credential and pinning its certificate.
    ///
    /// The platform is the user's choice rather than something sniffed: the two
    /// protocols answer on different ports, so a wrong guess produces
    /// "unreachable" — a worse message than asking.
    static func pair(
        host: String, platform: TVPlatform, name: String?, credentials: TVCredentialStore
    ) async -> PairingResult {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return .refused(reason: String(localized: "Enter the TV's address first."))
        }
        do {
            switch platform {
            case .webOS: return try await pairWebOS(host: host, name: name, credentials: credentials)
            case .tizen: return try await pairTizen(host: host, name: name, credentials: credentials)
            }
        } catch let error as TVTransportError {
            return .refused(reason: error.message)
        } catch {
            return .refused(reason: TVTransportError.unreachable(host).message)
        }
    }

    private static func pairWebOS(
        host: String, name: String?, credentials: TVCredentialStore
    ) async throws -> PairingResult {
        let transport = LGWebOSTransport(pinnedCertificate: nil)
        defer { transport.close() }
        let channel = try await transport.open(host: host, credential: nil, timeout: TVTimeout.connect)

        var ids = WebOSSSAP.IDGenerator()
        if let hello = WebOSSSAP.helloFrame() { try? await transport.send(hello) }
        // Newer firmware wants system info requested *before* registration.
        var model: String?
        if let reply = try? await exchange(transport, ids: &ids, uri: WebOSSSAP.URI.systemInfo, tag: "sysinfo") {
            model = WebOSSSAP.modelName(from: reply)
        }

        let registerID = ids.next("register")
        guard let register = WebOSSSAP.registerFrame(id: registerID, clientKey: nil) else {
            throw TVTransportError.malformedResponse("the registration frame could not be built")
        }
        try await transport.send(register)

        // `.keepsWaiting`: the answer here is a person picking up a remote, so a
        // receive that brought nothing is not an answer and must not end the wait.
        var pairing = await WebOSSSAP.awaitPairing(
            WebOSSSAP.Pairing(requestID: registerID),
            on: transport,
            timeout: TVTimeout.pairing
        )
        if !pairing.state.isFinished { pairing.timedOut() }

        switch pairing.state {
        case .registered(let clientKey):
            // webOS gives no identifier over SSAP that is both stable and
            // reachable here, so the model name is used where the TV offered one
            // and the address only as a last resort. Recorded once and never
            // re-derived, so a DHCP move updates `host` on the same record rather
            // than creating a second device.
            let id = TVDeviceID("webos:\(model ?? host)")
            let device = TVDevice(
                id: id, platform: .webOS,
                name: name ?? model ?? host, host: host, model: model, pairedAt: Date()
            )
            credentials.set(clientKey, for: id, kind: .credential)
            credentials.record(
                TVTrust.evaluate(
                    presented: channel.certificateFingerprint, recorded: nil,
                    isEncrypted: WebOSSSAP.isEncrypted(port: channel.port)
                ),
                for: id
            )
            return .paired(device)
        case .refused(let reason):
            return .refused(reason: reason)
        case .awaitingResponse, .promptShown:
            return .refused(reason: TVTransportError.pairingRefused.message)
        }
    }

    private static func pairTizen(
        host: String, name: String?, credentials: TVCredentialStore
    ) async throws -> PairingResult {
        // Detection first: `TokenAuthSupport` decides the port, and `id` is the
        // stable identity the device is filed under forever.
        guard let info = await tizenDeviceInfo(host: host) else {
            throw TVTransportError.unreachable(host)
        }
        guard info.isSupported else {
            return .refused(reason: String(localized: "The device at \(host) is not a Tizen TV."))
        }

        let transport = SamsungTizenTransport(
            pinnedCertificate: nil, tokenAuthSupport: info.tokenAuthSupport
        )
        defer { transport.close() }
        let channel = try await transport.open(host: host, credential: nil, timeout: TVTimeout.connect)

        let deadline = Date().addingTimeInterval(TVTimeout.pairing)
        while Date() < deadline {
            guard let text = try? await transport.receive(timeout: TVTimeout.request) else { continue }
            switch TizenRemote.channelEvent(from: text) {
            case .connected(let token):
                let id = TVDeviceID(info.id)
                let device = TVDevice(
                    id: id, platform: .tizen,
                    name: name ?? info.name ?? info.model ?? host,
                    host: host, model: info.model, pairedAt: Date()
                )
                if let token { credentials.set(token, for: id, kind: .credential) }
                credentials.record(
                    TVTrust.evaluate(
                        presented: channel.certificateFingerprint, recorded: nil,
                        isEncrypted: TizenRemote.isEncrypted(port: channel.port)
                    ),
                    for: id
                )
                return .paired(device)
            case .unauthorized:
                return .refused(reason: TVTransportError.pairingRefused.message)
            case .timeout:
                return .refused(reason: TVTransportError.timedOut.message)
            case .other, .none:
                continue
            }
        }
        return .refused(reason: TVTransportError.timedOut.message)
    }

    // MARK: - HTTP bits

    /// The most a television may send in reply to one HTTP request.
    ///
    /// `/api/v2/` is a few hundred bytes of JSON and a UPnP description document
    /// is a couple of kilobytes, so this is two orders of magnitude of headroom
    /// and refuses nothing real. It exists because of what is on the other end:
    /// an unauthenticated device on the LAN, named by an address the user typed
    /// or an SSDP packet claimed. `URLSession.data(for:)` buffers whatever it is
    /// handed, so with no cap a device that answers with an endless body is an
    /// out-of-memory in a menu-bar app — reachable by anything that can answer
    /// first at that address.
    static let maxResponseBytes = 256 * 1024

    /// One HTTP round trip to a television, with the response body capped.
    ///
    /// `bytes(for:)` rather than `data(for:)` because the cap has to hold while
    /// the body is arriving; by the time `data(for:)` returns, all of it is
    /// already in memory. Exceeding the cap fails the request rather than
    /// truncating it: half a description document still parses, into a control
    /// URL that is not the TV's.
    ///
    /// Returns nil for every failure — no route, a refused connection, a body
    /// over the cap — because all four call sites treat "no usable answer" the
    /// same way, and inventing distinctions here would only be un-made there.
    private static func fetch(_ request: URLRequest) async -> (data: Data, response: HTTPURLResponse?)? {
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        // A declared length over the cap is refused before a single byte of it is
        // read; a device that declares nothing (or lies) is caught by the loop.
        guard response.expectedContentLength <= Int64(maxResponseBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count > maxResponseBytes { return nil }
            }
        } catch {
            return nil
        }
        return (data, response as? HTTPURLResponse)
    }

    /// `GET http://<host>:8001/api/v2/`. An ordinary HTTP request, which is why
    /// it lives here rather than inside a WebSocket transport.
    static func tizenDeviceInfo(host: String) async -> TizenRemote.DeviceInfo? {
        guard let url = TizenRemote.deviceInfoURL(host: host) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = TVTimeout.connect
        guard let (data, _) = await fetch(request),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return TizenRemote.deviceInfo(from: text)
    }

    /// Candidate description-document locations, tried in order.
    ///
    /// A short list of paths rather than a hardcoded port, because real Samsung
    /// TVs serve `RenderingControl` on 9197 *and* 7676 at different paths. The
    /// control URL itself always comes out of the document
    /// (`TizenRemote.UPnP.controlURL`), never out of this list — this only finds
    /// the document.
    static let tizenDescriptionCandidates: [(port: Int, path: String)] = [
        (9197, "/dmr"),
        (9197, "/dmr/SamsungMRDesc.xml"),
        (7676, "/smp_2_"),
        (7676, "/rcr/"),
        (8001, "/dmr")
    ]

    static func volumeControlURL(for device: TVDevice) async -> URL? {
        for candidate in tizenDescriptionCandidates {
            guard let base = URL(string: "http://\(device.host):\(candidate.port)\(candidate.path)") else {
                continue
            }
            var request = URLRequest(url: base)
            request.timeoutInterval = TVTimeout.connect
            guard let (data, _) = await fetch(request),
                  let xml = String(data: data, encoding: .utf8),
                  let control = TizenRemote.UPnP.controlURL(fromDescription: xml, baseURL: base) else {
                continue
            }
            return control
        }
        return nil
    }

    static func tizenVolume(from control: URL) async -> Double? {
        var request = URLRequest(url: control)
        request.httpMethod = "POST"
        request.timeoutInterval = TVTimeout.request
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(TizenRemote.UPnP.soapAction("GetVolume"), forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(TizenRemote.UPnP.getVolumeBody().utf8)
        guard let (data, _) = await fetch(request),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        return TizenRemote.UPnP.volume(fromResponse: xml)
    }

    static func sendSOAP(to url: URL, action: String, body: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TVTimeout.request
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(TizenRemote.UPnP.soapAction(action), forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        guard let result = await fetch(request),
              let http = result.response, (200..<300).contains(http.statusCode) else {
            throw TVTransportError.malformedResponse(
                String(localized: "the TV refused the volume command")
            )
        }
    }

    // MARK: - Reporting

    static func describe(feature: TVFeatureID, value: TVActionValue, on device: TVDevice) -> String {
        let title = feature.spec.title.lowercased()
        switch value {
        case .percent(let percent):
            return "\(device.name): \(title) \(WebOSSSAP.clampedPercent(percent))%"
        case .flag(let flag):
            return "\(device.name): \(title) \(flag ? "on" : "off")"
        case .code(let code):
            return "\(device.name): \(title) \(code)"
        }
    }
}

/// The one-key-per-second pacing, as something two callers can share safely.
///
/// An `actor` around `TizenRemote.KeyRateLimiter` — the rule itself is a pure
/// value with an injected clock (so it is a unit test rather than a stopwatch),
/// and this is only the mutual exclusion around it. One per television, because
/// Samsung's limit is per television and every action here opens its own socket:
/// a per-connection limiter would reset each time and permit exactly the burst
/// that drops the channel.
actor TizenKeyPacer {
    private var limiter = TizenRemote.KeyRateLimiter()

    init() {}

    /// Seconds the caller should wait before sending its key, booking the slot.
    func reserve(now: Date = Date()) -> TimeInterval {
        limiter.reserve(at: now)
    }

    func reset() {
        limiter.reset()
    }
}
