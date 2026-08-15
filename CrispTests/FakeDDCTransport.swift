import Foundation
import CoreGraphics

/// A scriptable monitor on the other side of the `DDCTransport` seam.
///
/// It models the failure modes the DDC stack actually defends against, because those
/// are the ones worth testing: a display that says nothing, one that acks a read and
/// returns a stale/NULL frame, a wedged controller whose frame passes the header check
/// but fails the checksum, and a write that is acked but never takes effect.
///
/// Faults are queued per (display, VCP code) and consumed one per transaction, so a
/// test can script "fail twice, then answer" and pin the retry behaviour exactly.
final class FakeDDCTransport: DDCTransport, @unchecked Sendable {

    /// How the fake display answers one Get VCP transaction.
    enum Fault {
        /// A healthy monitor: answers with its scripted value.
        case healthy
        /// Nothing comes back at all: unplugged, wedged bus, or no channel found.
        case noResponse
        /// A frame with the right shape and the wrong checksum (controller noise).
        case badChecksum
        /// An acked read that returns a NULL/stale buffer instead of a reply.
        case nullFrame
        /// A reply that echoes a different VCP code (a stale reply to an earlier read).
        case wrongCommandEcho
        /// A well-formed reply claiming max == 0, which would make every write 0.
        case zeroMax
    }

    /// How the fake display answers one Set VCP transaction.
    enum WriteOutcome {
        /// Acked, and the value sticks.
        case ack
        /// Acked, but the panel ignores it — the ack is not proof of effect.
        case ackWithoutEffect
        /// No ack.
        case fail
    }

    /// Identifies one feature on one display.
    struct Key: Hashable {
        let displayID: CGDirectDisplayID
        let code: UInt8
        init(_ displayID: CGDirectDisplayID, _ code: UInt8) {
            self.displayID = displayID
            self.code = code
        }
    }

    /// One frame as it was handed to the transport.
    struct Frame: Equatable {
        let displayID: CGDirectDisplayID
        let chipAddress: UInt8
        let bytes: [UInt8]
    }

    // MARK: - Recording

    /// Every frame the protocol layer sent, in order (Set VCP and Get VCP alike).
    private(set) var sentFrames: [Frame] = []
    /// Replies the fake produced that the caller's own validation rejected. Distinguishes
    /// "the display said nothing" from "the display answered and we threw it away".
    private(set) var rejectedReplies: [[UInt8]] = []
    private(set) var invalidatedChannels: [CGDirectDisplayID] = []
    private(set) var invalidateAllChannelsCount = 0

    // MARK: - Script

    /// The values the fake display reports, per display and VCP code.
    private var values: [Key: (current: UInt16, max: UInt16)] = [:]
    private var readFaults: [Key: [Fault]] = [:]
    private var writeOutcomes: [Key: [WriteOutcome]] = [:]

    func setValue(_ current: UInt16, max: UInt16 = 100, displayID: CGDirectDisplayID, code: UInt8) {
        values[Key(displayID, code)] = (current: current, max: max)
    }

    func value(displayID: CGDirectDisplayID, code: UInt8) -> UInt16? {
        values[Key(displayID, code)]?.current
    }

    /// Queues one fault per upcoming read; reads past the end of the queue succeed.
    func queueReadFaults(_ faults: [Fault], displayID: CGDirectDisplayID, code: UInt8) {
        readFaults[Key(displayID, code)] = faults
    }

    /// Queues one outcome per upcoming write; writes past the end of the queue ack.
    func queueWriteOutcomes(_ outcomes: [WriteOutcome], displayID: CGDirectDisplayID, code: UInt8) {
        writeOutcomes[Key(displayID, code)] = outcomes
    }

    // MARK: - Derived helpers for assertions

    var sentFrameBytes: [[UInt8]] { sentFrames.map(\.bytes) }

    func frames(matchingOpcode opcode: UInt8) -> [Frame] {
        sentFrames.filter { $0.bytes.count > 1 && $0.bytes[1] == opcode }
    }

    /// Get VCP requests sent so far (opcode byte 0x82).
    var requestCount: Int { frames(matchingOpcode: 0x82).count }
    /// Set VCP frames sent so far (opcode byte 0x84).
    var writeCount: Int { frames(matchingOpcode: 0x84).count }

    // MARK: - DDCTransport

    func send(_ frame: [UInt8], to displayID: CGDirectDisplayID, chipAddress: UInt8) -> Bool {
        sentFrames.append(Frame(displayID: displayID, chipAddress: chipAddress, bytes: frame))
        guard frame.count >= 7 else { return false }
        let key = Key(displayID, frame[3])

        switch nextWriteOutcome(key) {
        case .fail:
            return false
        case .ackWithoutEffect:
            return true
        case .ack:
            let value = (UInt16(frame[4]) << 8) | UInt16(frame[5])
            let max = values[key]?.max ?? 100
            values[key] = (current: value, max: max)
            return true
        }
    }

    func request(
        _ frame: [UInt8],
        replyLength: Int,
        from displayID: CGDirectDisplayID,
        chipAddress: UInt8,
        isValidReply: ([UInt8]) -> Bool
    ) -> [UInt8]? {
        sentFrames.append(Frame(displayID: displayID, chipAddress: chipAddress, bytes: frame))
        guard frame.count >= 5 else { return nil }
        let command = frame[3]
        let key = Key(displayID, command)

        let fault = nextReadFault(key)
        if fault == .noResponse { return nil }

        guard let reply = buildReply(command: command, key: key, fault: fault, length: replyLength) else {
            return nil
        }
        // A real transport only hands back a reply the protocol layer accepts (the Intel
        // path keeps scanning buses otherwise), so the fake applies the same rule.
        guard isValidReply(reply) else {
            rejectedReplies.append(reply)
            return nil
        }
        return reply
    }

    func invalidateChannel(for displayID: CGDirectDisplayID) {
        invalidatedChannels.append(displayID)
    }

    func invalidateAllChannels() {
        invalidateAllChannelsCount += 1
    }

    // MARK: - Reply construction

    /// A well-formed DDC/CI Get VCP reply, the frame a healthy monitor sends.
    static func reply(command: UInt8, current: UInt16, max: UInt16, length: Int = 12) -> [UInt8] {
        var frame: [UInt8] = [
            0x6E, 0x88, 0x02, 0x00, command, 0x00,
            UInt8((max >> 8) & 0xFF), UInt8(max & 0xFF),
            UInt8((current >> 8) & 0xFF), UInt8(current & 0xFF)
        ]
        var checksum: UInt8 = 0x50
        for b in frame { checksum ^= b }
        frame.append(checksum)
        while frame.count < length { frame.append(0x00) }
        return frame
    }

    private func buildReply(command: UInt8, key: Key, fault: Fault, length: Int) -> [UInt8]? {
        switch fault {
        case .nullFrame:
            return [UInt8](repeating: 0, count: length)
        case .wrongCommandEcho:
            // Correctly checksummed, but answering a different feature.
            return Self.reply(command: command &+ 1, current: 40, max: 100, length: length)
        case .zeroMax:
            return Self.reply(command: command, current: 0, max: 0, length: length)
        case .badChecksum:
            var frame = Self.reply(command: command, current: 40, max: 100, length: length)
            frame[10] ^= 0xFF
            return frame
        case .noResponse:
            return nil
        case .healthy:
            // Unscripted features are simply not supported by this display.
            guard let value = values[key] else { return nil }
            return Self.reply(command: command, current: value.current, max: value.max, length: length)
        }
    }

    private func nextReadFault(_ key: Key) -> Fault {
        guard var queue = readFaults[key], !queue.isEmpty else { return .healthy }
        let fault = queue.removeFirst()
        readFaults[key] = queue
        return fault
    }

    private func nextWriteOutcome(_ key: Key) -> WriteOutcome {
        guard var queue = writeOutcomes[key], !queue.isEmpty else { return .ack }
        let outcome = queue.removeFirst()
        writeOutcomes[key] = queue
        return outcome
    }
}
