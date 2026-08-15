import Foundation

/// The raw frame boundary of the smart-TV stack: text in, text out, nothing
/// interpreted.
///
/// The same seam, in the same place, and for the same reason as `DDCTransport`.
/// Everything that makes either protocol work — the SSAP envelope, the id-based
/// correlation, the pairing state machines, the token extraction, the rate limit
/// — lives *above* this line (`WebOSSSAP`, `TizenRemote`) and is therefore
/// testable with no television in the building. Everything below it is a socket:
/// picking a port, negotiating TLS, moving bytes.
///
/// The production conformers are `LGWebOSTransport` and `SamsungTizenTransport`;
/// `FakeTVTransport` in the test target scripts televisions that pair, refuse to
/// pair, answer out of order, or say something malformed.
///
/// **Why every method has a timeout and none of them blocks.** A television is
/// off more often than it is on, and an unreachable one is the normal case, not
/// the error case (AGENTS.md rule #4: a device that is not there must never wedge
/// anything). So the whole surface is `async`, every wait is bounded, and a
/// transport that has been closed answers `.closed` rather than hanging on a
/// receive that will never complete.
protocol TVTransport: AnyObject {
    /// Which protocol this transport speaks. Reported so a caller holding an
    /// existential can log what it is talking to; nothing branches on it.
    var platform: TVPlatform { get }

    /// Opens the control channel, trying the platform's ports in order.
    ///
    /// - Parameters:
    ///   - host: an address or hostname. The transport does not resolve device
    ///     identity from it — that is `TVDeviceID`'s job, one layer up.
    ///   - credential: the stored client key (webOS) or token (Tizen), when
    ///     there is one. A `nil` credential is the pairing path, not an error.
    /// - Returns: which port answered and what certificate it presented, so the
    ///   trust-on-first-use rule (`TVTrust`) can be applied by the caller rather
    ///   than being buried in a URLSession delegate where nothing can test it.
    func open(host: String, credential: String?, timeout: TimeInterval) async throws -> TVChannel

    /// Sends one frame. Returns when the frame is on the socket, which for both
    /// of these protocols is *not* a promise that the TV did anything.
    func send(_ text: String) async throws

    /// Waits for the next frame from the TV, or throws `.timedOut`.
    ///
    /// Frames are not correlated here: the SSAP `id` field and the Tizen `event`
    /// field are the correlation, and reading them is the engines' job. A
    /// transport that tried to match requests to replies would have to parse the
    /// payload, which is exactly the thing this seam exists to keep out.
    func receive(timeout: TimeInterval) async throws -> String

    /// Drops the channel. Must be safe to call twice and safe to call on a
    /// transport that never opened — a TV vanishing mid-session is the ordinary
    /// case, and cleanup must not be able to throw on top of it.
    func close()
}

/// What answered, and what it presented.
struct TVChannel: Equatable, Sendable {
    /// The port that accepted the connection. Reported because it is the single
    /// most useful fact in a "it does not connect" bug report: webOS 5+ refuses
    /// 3000 and only answers on 3001, and a Tizen TV with
    /// `TokenAuthSupport=false` only answers on 8001.
    let port: Int
    /// SHA-256 of the leaf certificate the TV presented, lowercase hex, or nil
    /// for a plaintext port.
    ///
    /// Both platforms' TLS ports use a self-signed certificate with no published
    /// root, so ordinary validation cannot succeed and every existing client
    /// simply turns validation off. Crisp instead pins on first use: this
    /// fingerprint is what `TVTrust` compares. It authenticates "the same device
    /// as last time", not the device's identity — a distinction stated here and
    /// in `TVTrust` rather than left for a reader to infer.
    let certificateFingerprint: String?
}

/// Why a TV conversation failed, in the cases a caller can do something about.
enum TVTransportError: Error, Equatable, Sendable {
    /// No port answered within the connect timeout. The ordinary case for a TV
    /// that is off, standing by, or on another subnet.
    case unreachable(String)
    /// The TV presented a certificate that does not match the one recorded for
    /// it. Refused rather than reported, and never silently re-pinned.
    case certificateChanged(expected: String, presented: String)
    /// The TV said no to pairing: the user dismissed the on-screen prompt, or
    /// `ms.channel.unauthorized` came back.
    case pairingRefused
    /// Nothing arrived in time.
    case timedOut
    /// The channel is not open, or was closed under us.
    case closed
    /// The TV answered, but not with anything this protocol defines.
    case malformedResponse(String)

    /// A sentence for the panel, the CLI and the automation outcome. Written for
    /// a person who is standing in front of a television, so each one says what
    /// to try next rather than restating the failure.
    var message: String {
        switch self {
        case .unreachable(let host):
            return String(localized: """
                Crisp could not reach the TV at \(host). Check it is switched on, on the same \
                network as this Mac, and not on a separate guest or IoT network.
                """)
        case .certificateChanged:
            return String(localized: """
                This TV presented a different certificate than the one Crisp recorded when it \
                was paired. Crisp refused the connection. Remove the TV and add it again if you \
                replaced or factory-reset it.
                """)
        case .pairingRefused:
            return String(localized: "The TV refused the pairing request. Accept the prompt on the TV screen and try again.")
        case .timedOut:
            return String(localized: "The TV did not answer in time.")
        case .closed:
            return String(localized: "The connection to the TV was closed.")
        case .malformedResponse(let detail):
            return String(localized: "The TV sent something Crisp could not read: \(detail)")
        }
    }
}

// MARK: - Timeouts

/// The two waits, in one place because they are a product decision rather than a
/// constant.
///
/// `connect` is short because an unreachable TV is the *expected* case and the
/// user is looking at a panel: two seconds of spinner then an honest "could not
/// reach it" beats twenty seconds of hope. `request` is long because a webOS
/// pairing prompt is a human walking to the sofa to press a button on a remote,
/// and failing that at ten seconds would make first-run pairing feel broken.
enum TVTimeout {
    static let connect: TimeInterval = 2
    static let request: TimeInterval = 10
    /// The pairing prompt is answered by a person, not a device.
    static let pairing: TimeInterval = 60
}
