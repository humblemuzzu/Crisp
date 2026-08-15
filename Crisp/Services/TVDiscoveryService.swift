import Foundation
import Network
import os.log

private let discoveryLog = Logger(subsystem: "com.crisp.app", category: "TVDiscovery")

/// The SSDP multicast address, outside the main actor.
///
/// File scope rather than a static on the `@MainActor` class below: the socket
/// work is deliberately off the main actor (only the published result belongs
/// there), and a main-actor-isolated constant read from it is a warning today and
/// an error under the Swift 6 language mode.
private enum SSDP {
    static let host = "239.255.255.250"
    static let port: UInt16 = 1900
}

/// SSDP discovery for smart TVs — **only when the user asks for it**.
///
/// There is no timer here, no launch hook and no observer. `search()` is called
/// from one button in the Add TV sheet and from `crispctl tv discover`, it runs
/// for a few seconds, and then nothing on the network happens again until the
/// user presses it. That is a deliberate product decision rather than an
/// oversight: a menu-bar app for monitor brightness has no business multicasting
/// on someone's LAN at login, and most people who install this own no television
/// at all.
///
/// Typing an address by hand stays a first-class path for exactly the networks
/// where this cannot work — a TV on a separate IoT VLAN, or a router with
/// multicast filtered — so discovery is a convenience and never a requirement.
///
/// `Network.framework` is public API (AGENTS.md §3.1). Nothing here touches
/// WindowServer.
@MainActor
final class TVDiscoveryService: ObservableObject {
    static let shared = TVDiscoveryService()

    /// One TV that answered.
    struct Candidate: Equatable, Identifiable, Sendable {
        /// Address, which is all SSDP gives directly. The *identity* comes later,
        /// from the TV's own `getSystemInfo` or `/api/v2/` — see `TVDeviceID`.
        let host: String
        /// Which protocol the search target implies.
        let platform: TVPlatform
        /// The `USN`/`LOCATION` line, kept verbatim for bug reports.
        let detail: String

        var id: String { "\(platform.rawValue)|\(host)" }
    }

    @Published private(set) var isSearching = false
    @Published private(set) var candidates: [Candidate] = []

    /// LG's own second-screen target, and Samsung's remote-control receiver. Two
    /// targeted searches rather than one `ssdp:all`, which returns every printer,
    /// speaker and light bulb on the network and makes the result list useless.
    private static let searchTargets: [(target: String, platform: TVPlatform)] = [
        ("urn:lge-com:service:webos-second-screen:1", .webOS),
        ("urn:samsung.com:device:RemoteControlReceiver:1", .tizen)
    ]

    /// Runs one search. Idempotent: a second call while one is running is
    /// ignored rather than starting a second multicast burst.
    func search(duration: TimeInterval = 3) async {
        guard !isSearching else { return }
        isSearching = true
        candidates = []
        defer { isSearching = false }

        for entry in Self.searchTargets {
            // A cancelled search stops between bursts rather than sending the
            // second one at a window nobody is looking at any more. `isSearching`
            // is cleared by the `defer` on this path too — the reason each
            // receive below is bounded is that a suspended function runs no
            // `defer` at all.
            if Task.isCancelled { break }
            let found = await Self.probe(target: entry.target, duration: duration / Double(Self.searchTargets.count))
            for response in found {
                guard let host = Self.host(fromLocation: response) else { continue }
                let candidate = Candidate(host: host, platform: entry.platform, detail: response)
                if !candidates.contains(where: { $0.id == candidate.id }) {
                    candidates.append(candidate)
                }
            }
        }
    }

    /// One M-SEARCH burst, collecting whatever answers within `duration`.
    ///
    /// `nonisolated static` so the socket work does not sit on the main actor:
    /// the only thing that needs to be there is the published result.
    private nonisolated static func probe(target: String, duration: TimeInterval) async -> [String] {
        let message = """
            M-SEARCH * HTTP/1.1\r
            HOST: \(SSDP.host):\(SSDP.port)\r
            MAN: "ssdp:discover"\r
            MX: 1\r
            ST: \(target)\r
            \r

            """

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(SSDP.host),
            port: NWEndpoint.Port(rawValue: SSDP.port) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .udp)
        let collector = ResponseCollector()

        connection.start(queue: .global(qos: .utility))
        connection.send(content: Data(message.utf8), completion: .contentProcessed { error in
            if let error { discoveryLog.debug("ssdp send failed: \(error.localizedDescription, privacy: .public)") }
        })

        // Datagrams arrive one at a time and there is no "end of results": the
        // search is over when the clock says so, which is why this reads in a
        // loop against a deadline rather than waiting for a terminator. Each
        // receive carries what is left of that deadline as its own bound —
        // re-checking the clock *between* receives bounds nothing, because the
        // wait that has to end is the one inside the receive.
        let deadline = Date().addingTimeInterval(duration)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let data = try? await receiveOne(connection, within: remaining) else { break }
            if let text = String(data: data, encoding: .utf8) { await collector.add(text) }
        }
        connection.cancel()
        return await collector.responses
    }

    /// One datagram, or a thrown `timedOut` if none arrived in time.
    ///
    /// The bound is the whole of this function, and it is the common case rather
    /// than an edge case: most people who install this own no television, so
    /// *nothing answers* is what usually happens. `receiveMessage`'s completion
    /// fires on data, on an error or on cancellation and **never** on elapsed
    /// time, so an unbounded receive here suspends forever — `search()` never
    /// returns, its `defer` never runs, and the Search button spins for the rest
    /// of the session.
    ///
    /// `withTVTimeout` on its own would not be enough, and the reason is worth
    /// stating: it cancels the losing child task, and a `withCheckedContinuation`
    /// does not notice cancellation. The cancellation handler is what turns that
    /// into something the socket acts on — cancelling the connection makes the
    /// pending completion fire, which resumes the continuation and lets the task
    /// group drain instead of waiting on a child that can never finish.
    private nonisolated static func receiveOne(
        _ connection: NWConnection, within seconds: TimeInterval
    ) async throws -> Data? {
        try await withTVTimeout(seconds) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    connection.receiveMessage { data, _, _, _ in
                        continuation.resume(returning: data)
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    /// Accumulates responses off the socket's queue.
    private actor ResponseCollector {
        private(set) var responses: [String] = []
        func add(_ text: String) { responses.append(text) }
    }

    /// The host out of an SSDP response's `LOCATION` header.
    ///
    /// Parsed rather than trusted: the header is a URL from a device on the
    /// network, and only its host is used — never its path, and never as
    /// somewhere to send a request to.
    static func host(fromLocation response: String) -> String? {
        for line in response.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].uppercased() == "LOCATION" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: value), let host = url.host, !host.isEmpty else { continue }
            return host
        }
        return nil
    }
}
