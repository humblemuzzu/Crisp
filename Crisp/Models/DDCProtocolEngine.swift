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
    /// The I2C chip address every request goes to. A later phase selects 0xB7 per
    /// display for MCDP2900-converted HDMI ports; the value already travels through
    /// the seam so that change stays below this class.
    private let chipAddress: UInt8
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
        chipAddress: UInt8 = DDCPacket.displayChipAddress,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.transport = transport
        self.chipAddress = chipAddress
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Single attempt

    /// One Set VCP transaction. True means the display acked it.
    func write(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        transport.send(
            DDCPacket.setVCP(command: command, value: value),
            to: displayID,
            chipAddress: chipAddress
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
            chipAddress: chipAddress,
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
