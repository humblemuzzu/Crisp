import Foundation
import CryptoKit
import Security
import os.log

// The socket half of smart-TV control: `LGWebOSTransport` and
// `SamsungTizenTransport`, both conforming to `TVTransport`.
//
// Everything above this line is pure (`WebOSSSAP`, `TizenRemote`, `TVTrust`) and
// everything below it is `URLSession`. That is the same division `DDCPacket` /
// `DDCProtocolEngine` have over `IOKitDDCTransport`, and it is what makes the
// protocol work testable with no television: the only thing these classes decide
// is which port to try and what to do with a certificate.
//
// **Public API only** (AGENTS.md §3.1): `URLSessionWebSocketTask`, `Security`,
// `CryptoKit`. Nothing here goes near WindowServer, and this file is policed by
// `scripts/check-boundaries.sh` along with every other service.
//
// **Nothing blocks and nothing is unbounded.** A television is off more often
// than it is on, so an unreachable one is the ordinary path: every wait has a
// timeout, `close()` is safe to call twice and on a socket that never opened, and
// a device disappearing mid-conversation surfaces as a thrown
// `TVTransportError`, never as a hang (AGENTS.md rule #4).

private let tvLog = Logger(subsystem: "com.crisp.app", category: "TVTransport")

// MARK: - Timeout helper

/// Runs an operation with a deadline.
///
/// A free function rather than per-call-site `Task.sleep` juggling, because the
/// failure mode this guards against — a socket that connects and then never says
/// anything — is invisible in testing and permanent in the field. One helper
/// means one place that can be got wrong.
func withTVTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TVTransportError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TVTransportError.timedOut }
        return first
    }
}

// MARK: - The socket

/// One WebSocket, with the certificate the far end presented.
///
/// Shared by both platforms because the two protocols differ entirely above the
/// socket and not at all at it: the same handshake, the same text frames, the
/// same self-signed-certificate problem.
///
/// The TLS decision is made **in the delegate**, before the handshake completes,
/// and that is deliberate. Comparing fingerprints after the connection is up
/// would mean a substituted device had already received whatever was sent to it;
/// refusing in the challenge means a mismatched certificate never becomes a
/// session at all. `TVTrust` owns the rule, this owns the plumbing.
final class TVWebSocket: NSObject, @unchecked Sendable {

    /// Guards every mutable field: the delegate callbacks arrive on URLSession's
    /// queue while the caller is awaiting on another.
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var observedFingerprintStorage: String?
    private var expectedFingerprint: String?
    private var failure: TVTransportError?

    /// SHA-256 of the leaf certificate the TV presented, or nil for a plaintext
    /// port. Read after `open` to feed `TVTrust`.
    var observedFingerprint: String? { lock.withLock { observedFingerprintStorage } }

    /// Opens the socket and waits for the handshake.
    ///
    /// - Parameter expected: the pinned fingerprint, when there is one. A
    ///   mismatch fails the *connection*, not a later check.
    func open(url: URL, expected: String?, timeout: TimeInterval) async throws {
        close()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // A TV is on the LAN; going through a proxy or waiting for "connectivity"
        // would turn an unreachable television into a request that hangs until
        // the OS gives up rather than until this app's own deadline.
        configuration.waitsForConnectivity = false

        lock.withLock {
            self.expectedFingerprint = TVTrust.normalized(expected)
            self.observedFingerprintStorage = nil
            self.failure = nil
        }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        lock.withLock {
            self.session = session
            self.task = task
        }

        do {
            try await withTVTimeout(timeout) { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard let self else {
                        continuation.resume(throwing: TVTransportError.closed)
                        return
                    }
                    self.lock.withLock { self.openContinuation = continuation }
                    task.resume()
                }
            }
        } catch {
            close()
            // A refusal recorded by the delegate is more specific than the
            // timeout or the transport error the task surfaced, so it wins:
            // "the certificate changed" is an answer, "it timed out" is not.
            if let recorded = lock.withLock({ failure }) { throw recorded }
            throw error as? TVTransportError ?? TVTransportError.unreachable(url.host ?? url.absoluteString)
        }
    }

    func send(_ text: String) async throws {
        guard let task = lock.withLock({ self.task }) else { throw TVTransportError.closed }
        do {
            try await task.send(.string(text))
        } catch {
            throw TVTransportError.closed
        }
    }

    func receive(timeout: TimeInterval) async throws -> String {
        guard let task = lock.withLock({ self.task }) else { throw TVTransportError.closed }
        return try await withTVTimeout(timeout) {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw TVTransportError.closed
            }
            switch message {
            case .string(let text):
                return text
            case .data(let data):
                // Neither protocol sends binary frames. Decoding one as UTF-8
                // rather than refusing costs nothing and covers a firmware that
                // labels its JSON as binary, which has been seen.
                guard let text = String(data: data, encoding: .utf8) else {
                    throw TVTransportError.malformedResponse("a binary frame that is not text")
                }
                return text
            @unknown default:
                throw TVTransportError.malformedResponse("an unfamiliar frame type")
            }
        }
    }

    func close() {
        let (task, session, continuation) = lock.withLock {
            let values = (self.task, self.session, self.openContinuation)
            self.task = nil
            self.session = nil
            self.openContinuation = nil
            return values
        }
        // Anyone still waiting for the handshake has to be failed here; leaving a
        // continuation unresumed leaks the task forever.
        continuation?.resume(throwing: TVTransportError.closed)
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Resumes the pending handshake exactly once. Both the success and the
    /// failure callbacks route through here, because URLSession can deliver
    /// `didCompleteWithError` after `didOpen` and resuming twice traps.
    private func finishOpen(with error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let pending = openContinuation
            openContinuation = nil
            return pending
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

extension TVWebSocket: URLSessionWebSocketDelegate {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        finishOpen(with: nil)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finishOpen(with: TVTransportError.closed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let recorded = lock.withLock { self.failure }
        finishOpen(with: recorded ?? error ?? TVTransportError.closed)
    }

    /// Trust-on-first-use, applied at the handshake.
    ///
    /// The certificate is self-signed and chains to nothing, so the system's
    /// evaluation always fails and there is no "just do it properly" available —
    /// see `TVTrust`'s header. What is available, and what every other client
    /// skips, is refusing when the certificate is not the one this TV presented
    /// when it was paired.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let presented = Self.leafFingerprint(of: trust) else {
            lock.withLock { failure = .malformedResponse("the TV's certificate could not be read") }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let expected = lock.withLock { () -> String? in
            observedFingerprintStorage = presented
            return expectedFingerprint
        }

        let decision = TVTrust.evaluate(presented: presented, recorded: expected, isEncrypted: true)
        guard decision.permitsConnection else {
            tvLog.error("refusing TV certificate: it is not the one this device was paired with")
            lock.withLock { failure = decision.error ?? .closed }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// SHA-256 of the leaf certificate, lowercase hex.
    ///
    /// The leaf and not the chain: these certificates are self-signed, so the
    /// leaf *is* the chain, and hashing an anchor a TV does not have would pin
    /// nothing.
    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - LG webOS

/// The webOS control channel: plaintext 3000, then TLS 3001.
///
/// The order matters and is not arbitrary. 3000 works on older firmware with no
/// certificate question at all; webOS 5 and later (2020 onwards) frequently
/// refuse it, and those are exactly the sets where the TLS port is answered. A
/// client that only tried 3001 would fail on old TVs, and one that only tried
/// 3000 would fail on every recent one.
///
/// **No `Origin` header.** The TV rejects connections that look like they came
/// from a browser. `URLSessionWebSocketTask` sends none by default, which is why
/// nothing here sets one — and why nothing here should start.
final class LGWebOSTransport: TVTransport {
    let platform: TVPlatform = .webOS

    private let socket = TVWebSocket()
    private let pinnedCertificate: String?

    /// - Parameter pinnedCertificate: the fingerprint recorded when this TV was
    ///   paired, or nil for a device being paired now. Passed in rather than
    ///   looked up so the transport has no opinion about where credentials live.
    init(pinnedCertificate: String? = nil) {
        self.pinnedCertificate = pinnedCertificate
    }

    func open(host: String, credential: String?, timeout: TimeInterval) async throws -> TVChannel {
        var lastError: TVTransportError = .unreachable(host)
        for port in WebOSSSAP.ports {
            guard let url = URL(string: "\(WebOSSSAP.isEncrypted(port: port) ? "wss" : "ws")://\(host):\(port)") else {
                continue
            }
            do {
                try await socket.open(
                    url: url,
                    expected: WebOSSSAP.isEncrypted(port: port) ? pinnedCertificate : nil,
                    timeout: timeout
                )
                return TVChannel(port: port, certificateFingerprint: socket.observedFingerprint)
            } catch let error as TVTransportError {
                // A certificate refusal is a decision, not a port that did not
                // answer: falling through to the next port would be trying to
                // reach the same suspect device another way.
                if case .certificateChanged = error { throw error }
                lastError = error
            } catch {
                lastError = .unreachable(host)
            }
        }
        throw lastError
    }

    func send(_ text: String) async throws { try await socket.send(text) }
    func receive(timeout: TimeInterval) async throws -> String { try await socket.receive(timeout: timeout) }
    func close() { socket.close() }
}

// MARK: - Samsung Tizen

/// The Tizen control channel.
///
/// Unlike webOS there is no port to guess at: `GET /api/v2/` says whether the TV
/// wants a token, and that answer decides 8002 (TLS + token) or 8001 (plain).
/// The detection request is made by `TVDeviceService` — it is an ordinary HTTP
/// GET and has no business inside a WebSocket transport — and its answer arrives
/// here as `tokenAuthSupport`.
final class SamsungTizenTransport: TVTransport {
    let platform: TVPlatform = .tizen

    private let socket = TVWebSocket()
    private let pinnedCertificate: String?
    private let tokenAuthSupport: Bool?

    init(pinnedCertificate: String? = nil, tokenAuthSupport: Bool? = nil) {
        self.pinnedCertificate = pinnedCertificate
        self.tokenAuthSupport = tokenAuthSupport
    }

    func open(host: String, credential: String?, timeout: TimeInterval) async throws -> TVChannel {
        let preferred = TizenRemote.preferredPort(tokenAuthSupport: tokenAuthSupport)
        // The other port as a fallback: `TokenAuthSupport` has been seen absent
        // and been seen wrong, and one extra two-second attempt is a better
        // failure mode than telling the user their TV is unreachable.
        let ports = preferred == TizenRemote.securePort
            ? [TizenRemote.securePort, TizenRemote.plainPort]
            : [TizenRemote.plainPort, TizenRemote.securePort]

        var lastError: TVTransportError = .unreachable(host)
        for port in ports {
            guard let url = TizenRemote.controlURL(host: host, port: port, token: credential) else { continue }
            do {
                try await socket.open(
                    url: url,
                    expected: TizenRemote.isEncrypted(port: port) ? pinnedCertificate : nil,
                    timeout: timeout
                )
                return TVChannel(port: port, certificateFingerprint: socket.observedFingerprint)
            } catch let error as TVTransportError {
                if case .certificateChanged = error { throw error }
                lastError = error
            } catch {
                lastError = .unreachable(host)
            }
        }
        throw lastError
    }

    func send(_ text: String) async throws { try await socket.send(text) }
    func receive(timeout: TimeInterval) async throws -> String { try await socket.receive(timeout: timeout) }
    func close() { socket.close() }
}
