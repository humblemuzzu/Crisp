import Foundation
import CoreGraphics

/// DDC/CI protocol logic on top of a `DDCTransport`: framing, reply validation, retry
/// and the read quarantine. Owns no IOKit state, so it runs headless against
/// `FakeDDCTransport` in tests.
///
/// Extracted from `DDCService`'s `writeSynchronous` / `readSynchronous` and the retry
/// loops inside `writeAsync` / `readAsync`. Semantics are unchanged: same attempt
/// counts, same 50 ms inter-attempt delay, same quarantine thresholds. `DDCService`
/// keeps the VCP cache, the serial queue and the public async API on top.
///
/// Thread confinement: the quarantine state is unsynchronised, exactly as it was in
/// `DDCService`. Every call must come from `DDCService.ddcQueue` (or, in tests, from a
/// single thread).
final class DDCProtocolEngine: @unchecked Sendable {
    private let transport: DDCTransport
    /// Injected clock and sleep so the quarantine window and the retry backoff can be
    /// exercised without waiting for wall time.
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void

    /// Attempts made by `writeWithRetry` / `readWithRetry`, and the pause between them.
    private let attempts = 3
    private let retryDelay: TimeInterval = 0.05

    /// Consecutive raw read failures per display. Past the threshold the
    /// display's reads are quarantined (fail fast, no I2C traffic) until its
    /// cache is cleared on reconnect. A wedged DDC controller (AOC Q27G3XMN)
    /// streams garbage and degrades further under retry hammering, so backing
    /// off protects both the monitor and the shared DCP I2C engine. Writes
    /// are unaffected; they keep working on wedged controllers.
    private var readFailStreak: [CGDirectDisplayID: Int] = [:]
    private let readQuarantineThreshold = 6
    /// Quarantine expiry per display: after it passes, one fresh probe window
    /// opens (streak resets); persistent failure re-quarantines. Without an
    /// expiry, a transient failure burst on a static setup (no reconnects to
    /// clear the cache) would kill reads for the rest of the session.
    private var readQuarantineUntil: [CGDirectDisplayID: Date] = [:]
    private let readQuarantineInterval: TimeInterval = 600

    init(
        transport: DDCTransport,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Single attempt

    /// One Set VCP transaction. True means the display acked it.
    ///
    /// The frame is the same bytes whatever the chip address: the address is I2C
    /// addressing, outside the DDC/CI frame and therefore outside its checksum.
    func write(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        transport.send(
            DDCPacket.setVCP(command: command, value: value),
            to: displayID,
            chipAddress: transport.chipAddress(for: displayID)
        )
    }

    /// One Get VCP transaction, subject to the read quarantine.
    /// Returns (current, max) or nil on failure.
    func read(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        if let until = readQuarantineUntil[displayID] {
            guard now() >= until else { return nil }
            readQuarantineUntil.removeValue(forKey: displayID)
            readFailStreak[displayID] = 0
        }

        let reply = transport.request(
            DDCPacket.getVCP(command: command),
            replyLength: DDCPacket.replyLength,
            from: displayID,
            chipAddress: transport.chipAddress(for: displayID),
            isValidReply: { DDCPacket.parseGetVCPReply($0, command: command) != nil }
        )
        let result = reply.flatMap { DDCPacket.parseGetVCPReply($0, command: command) }

        if result == nil {
            let streak = readFailStreak[displayID, default: 0] + 1
            readFailStreak[displayID] = streak
            if streak >= readQuarantineThreshold {
                readQuarantineUntil[displayID] = now().addingTimeInterval(readQuarantineInterval)
            }
        } else {
            readFailStreak[displayID] = 0
        }
        return result
    }

    // MARK: - Retrying

    /// Set VCP, retried up to `attempts` times. DDC writes are cheap and a single
    /// dropped transaction is common, so this is the path the UI uses.
    func writeWithRetry(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        for attempt in 0..<attempts {
            if write(displayID: displayID, command: command, value: value) { return true }
            if attempt < attempts - 1 { sleep(retryDelay) }
        }
        return false
    }

    /// Get VCP, retried up to `attempts` times. Batch reads deliberately do not use
    /// this: hammering every VCP code three times is what wedges a marginal controller.
    func readWithRetry(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        for attempt in 0..<attempts {
            if let result = read(displayID: displayID, command: command) { return result }
            if attempt < attempts - 1 { sleep(retryDelay) }
        }
        return nil
    }

    // MARK: - Capabilities

    /// Reads the monitor's capabilities string (DDC/CI 0xF3), fragment by fragment.
    ///
    /// Deliberately outside the VCP read path's bookkeeping. It respects an active read
    /// quarantine — the whole point of the quarantine is that a wedged controller
    /// degrades further under traffic, and a capabilities read is 20-odd transactions —
    /// but it does not feed the failure streak, because a monitor that implements VCP
    /// reads and not 0xF3 is completely normal and must not be quarantined for it.
    ///
    /// Returns nil when the monitor never answered at all; a partial or malformed
    /// string is returned parsed, with the transfer's own notes folded into its
    /// diagnostics, because a string that half-arrived is still evidence.
    func readCapabilities(displayID: CGDirectDisplayID) -> DDCCapabilities? {
        if let until = readQuarantineUntil[displayID], now() < until { return nil }

        var reader = DDCCapabilitiesReader()
        var notes: [String] = []
        var offset: UInt16 = 0
        var answered = false

        loop: while true {
            guard let fragment = requestCapabilityFragment(displayID: displayID, offset: offset) else {
                if answered {
                    notes.append("the monitor stopped answering the capabilities request at offset \(offset)")
                }
                break loop
            }
            answered = true
            switch reader.accept(offset: fragment.offset, data: fragment.data) {
            case .needMore(let next):
                offset = next
            case .complete:
                break loop
            case .failed(let reason):
                notes.append(reason)
                break loop
            }
        }

        guard answered else { return nil }
        return DDCCapabilities.parse(reader.text, transferNotes: reader.diagnostics + notes)
    }

    /// One capabilities fragment, retried like a VCP read.
    ///
    /// The validity closure requires the *requested* offset: a reply carrying a
    /// different one is a stale answer to an earlier request, and appending it would
    /// silently corrupt the string. Handing that rule to the transport also lets the
    /// Intel path keep scanning I2C buses past a channel that answers with the wrong
    /// frame, exactly as it does for Get VCP.
    private func requestCapabilityFragment(
        displayID: CGDirectDisplayID, offset: UInt16
    ) -> (offset: UInt16, data: [UInt8])? {
        for attempt in 0..<attempts {
            let reply = transport.request(
                DDCPacket.getCapabilities(offset: offset),
                replyLength: DDCPacket.capabilitiesReplyLength,
                from: displayID,
                chipAddress: transport.chipAddress(for: displayID),
                isValidReply: { DDCPacket.parseCapabilitiesReply($0)?.offset == offset }
            )
            if let parsed = reply.flatMap({ DDCPacket.parseCapabilitiesReply($0) }) { return parsed }
            if attempt < attempts - 1 { sleep(retryDelay) }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// The read quarantine's state for one display, for the diagnostics report.
    ///
    /// Read-only by construction: it neither starts, extends nor clears a
    /// quarantine, and it puts nothing on the I²C bus. A quarantined display is
    /// otherwise invisible — reads simply return nil — and "the monitor stopped
    /// answering" is exactly the symptom a user cannot diagnose without being told
    /// that the app has deliberately backed off.
    struct ReadHealth: Equatable, Sendable {
        let consecutiveReadFailures: Int
        /// When the quarantine lifts, or `nil` when none is active.
        let quarantinedUntil: Date?
    }

    /// Must be called on the same queue as every other entry point (see the
    /// thread-confinement note on the type): the state it reads is unsynchronised.
    func readHealth(displayID: CGDirectDisplayID) -> ReadHealth {
        ReadHealth(
            consecutiveReadFailures: readFailStreak[displayID, default: 0],
            // An expired window is not a quarantine: the next read lifts it. Report
            // what the next read would do, not what a stale dictionary entry says.
            quarantinedUntil: readQuarantineUntil[displayID].flatMap { $0 > now() ? $0 : nil }
        )
    }

    // MARK: - Reconnect / disconnect

    /// Forgets one display's read-failure history, lifting any quarantine. Called when
    /// that display disappears. Channel invalidation is the transport's business and is
    /// driven separately by `DDCService`, which must do it synchronously rather than
    /// behind this queue-confined state.
    func resetFailureState(for displayID: CGDirectDisplayID) {
        readFailStreak.removeValue(forKey: displayID)
        readQuarantineUntil.removeValue(forKey: displayID)
    }

    /// Forgets every display's read-failure history. Called on any display
    /// reconfiguration, because CGDisplay IDs get reshuffled across reconnect storms
    /// and a per-removed-ID cleanup never sees two surviving IDs swap panels.
    func resetAllFailureState() {
        readFailStreak.removeAll()
        readQuarantineUntil.removeAll()
    }
}
