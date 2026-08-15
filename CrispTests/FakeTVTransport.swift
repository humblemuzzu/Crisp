import Foundation

/// A scriptable television on the other side of the `TVTransport` seam.
///
/// The DDC stack has `FakeDDCTransport` because nobody wants to own every broken
/// monitor in the world; this exists because there is **no television on the
/// machine this was written on at all**. Every property of the two protocols that
/// this suite asserts is asserted against this fake, and the report that ships
/// with it says so plainly rather than implying a TV was ever plugged in.
///
/// It models the failure modes the stack actually defends against, which are the
/// ones worth testing: a TV that is off, one that refuses pairing, one that
/// answers replies in a different order from the requests, one that sends
/// something malformed, and one whose certificate has changed since pairing.
final class FakeTVTransport: TVTransport, @unchecked Sendable {

    /// How the fake answers `open`.
    enum ConnectOutcome {
        /// Connects, reporting this port and certificate fingerprint.
        case connected(port: Int, fingerprint: String?)
        /// The TV is off, standing by, or on another subnet.
        case unreachable
        /// The certificate does not match the pinned one.
        case certificateChanged(expected: String, presented: String)
    }

    /// What the fake does once `scriptedFrames` runs out.
    enum Exhaustion {
        /// Nothing more arrives: `receive` throws `.timedOut`, which is what a
        /// television that has said its piece does. The default.
        case silence
        /// The device keeps talking and never says anything terminal — a stale
        /// DHCP lease answering on webOS's plaintext port 3000, or some other box
        /// on the LAN that chats. Worth modelling because it is the *shape* of a
        /// whole class of hang and the fake could not express it before: a wait
        /// that ends only when `receive` throws never ends here, so a missing
        /// deadline is invisible to a suite whose fake always falls silent.
        case repeats(String)
    }

    let platform: TVPlatform

    /// Frames the fake will hand back, in order. Consumed one per `receive`.
    var scriptedFrames: [String]
    var connectOutcome: ConnectOutcome
    /// What happens after the script runs out.
    var whenExhausted: Exhaustion = .silence

    /// Everything `send` was given, in order — so a test can assert on the exact
    /// bytes that would have gone on the wire, not merely on what came back.
    private(set) var sent: [String] = []
    private(set) var isOpen = false
    private(set) var closeCount = 0
    /// How many times `receive` was called. A test that pins a deadline asserts
    /// on this: the point is not only that the wait ended, but that it ended
    /// after a countable number of frames rather than a long walk to a stopwatch.
    private(set) var receiveCount = 0
    /// The credential the caller offered at `open`. A stale-key test needs to
    /// know a key really was sent before the TV re-prompted.
    private(set) var offeredCredential: String?

    init(
        platform: TVPlatform = .webOS,
        connectOutcome: ConnectOutcome = .connected(port: 3000, fingerprint: nil),
        frames: [String] = []
    ) {
        self.platform = platform
        self.connectOutcome = connectOutcome
        self.scriptedFrames = frames
    }

    func open(host: String, credential: String?, timeout: TimeInterval) async throws -> TVChannel {
        offeredCredential = credential
        switch connectOutcome {
        case .connected(let port, let fingerprint):
            isOpen = true
            return TVChannel(port: port, certificateFingerprint: fingerprint)
        case .unreachable:
            throw TVTransportError.unreachable(host)
        case .certificateChanged(let expected, let presented):
            throw TVTransportError.certificateChanged(expected: expected, presented: presented)
        }
    }

    func send(_ text: String) async throws {
        guard isOpen else { throw TVTransportError.closed }
        sent.append(text)
    }

    func receive(timeout: TimeInterval) async throws -> String {
        guard isOpen else { throw TVTransportError.closed }
        receiveCount += 1
        guard !scriptedFrames.isEmpty else {
            switch whenExhausted {
            case .silence: throw TVTransportError.timedOut
            case .repeats(let frame): return frame
            }
        }
        return scriptedFrames.removeFirst()
    }

    func close() {
        isOpen = false
        closeCount += 1
    }
}
