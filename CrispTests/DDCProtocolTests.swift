import XCTest
import Foundation
import CoreGraphics

/// Headless tests for the DDC/CI protocol layer: wire format, reply validation, retry
/// and the read quarantine.
///
/// `DDCPacket`, `DDCTransport` and `DDCProtocolEngine` are compiled directly into this
/// test target (see `project.yml` sources, same route as `DDCServiceMatcher`), so no
/// `@testable import Crisp` is needed — that would pull IOKit and the private bridging
/// header and defeat headless purity. The hardware lives behind the `DDCTransport`
/// seam and is replaced here by `FakeDDCTransport`. Each test names the mutation it is
/// designed to kill in a trailing comment.
final class DDCProtocolTests: XCTestCase {

    private let display: CGDirectDisplayID = 7
    private let brightness: UInt8 = 0x10

    // MARK: - Request framing

    /// *Set VCP wire format.* Pins every byte of the frame Crisp puts on the I2C bus,
    /// including the checksum seeded with the 0x6E destination address. Verified against
    /// the frame both hardware paths sent before the seam existed.
    /// Kills mutation: reordering the frame, dropping the 0x51 source byte, using 0x03
    /// as the opcode instead of 0x84, or seeding the checksum with anything but 0x6E.
    func testSetVCPFrameIsExactWireFormat() {
        XCTAssertEqual(
            DDCPacket.setVCP(command: 0x10, value: 40),
            [0x51, 0x84, 0x03, 0x10, 0x00, 0x28, 0x80]
        )
    }

    /// *Get VCP wire format.* Same pinning for the read request.
    /// Kills mutation: 0x81/0x02 instead of 0x82/0x01, or a checksum computed over the
    /// payload without the leading source byte.
    func testGetVCPFrameIsExactWireFormat() {
        XCTAssertEqual(
            DDCPacket.getVCP(command: 0x10),
            [0x51, 0x82, 0x01, 0x10, 0xAC]
        )
    }

    /// *16-bit values split high byte first.* A value above 255 must not be truncated,
    /// and the two bytes must not be swapped (a swap silently writes a wrong value that
    /// still checksums).
    /// Kills mutation: `UInt8(value & 0xFF)` in the high slot, or a byte-swapped pair.
    func testSetVCPFrameSplitsSixteenBitValueHighByteFirst() {
        let frame = DDCPacket.setVCP(command: 0x12, value: 0x1234)
        XCTAssertEqual(frame[4], 0x12)
        XCTAssertEqual(frame[5], 0x34)
    }

    /// *The checksum covers the whole frame.* Flipping any payload byte must change the
    /// checksum, which is what makes the reply validation below meaningful.
    /// Kills mutation: a checksum over a subset of the bytes, or a constant.
    func testChecksumCoversEveryFrameByte() {
        let a = DDCPacket.setVCP(command: 0x10, value: 40)
        let b = DDCPacket.setVCP(command: 0x10, value: 41)
        let c = DDCPacket.setVCP(command: 0x12, value: 40)
        XCTAssertNotEqual(a.last, b.last)
        XCTAssertNotEqual(a.last, c.last)
    }

    // MARK: - Reply parsing

    /// *Happy path.* Current and max come from bytes 8-9 and 6-7 respectively — a swap
    /// here is the exact bug that compressed the usable brightness range.
    /// Kills mutation: reading current from bytes 6-7 and max from 8-9.
    func testParseReplyExtractsCurrentAndMax() {
        let reply = FakeDDCTransport.reply(command: 0x10, current: 25, max: 100)
        let parsed = DDCPacket.parseGetVCPReply(reply, command: 0x10)
        XCTAssertEqual(parsed?.current, 25)
        XCTAssertEqual(parsed?.max, 100)
    }

    /// *Two-byte values survive the round trip.* Pins that the high byte is not dropped.
    /// Kills mutation: parsing only the low byte of either field.
    func testParseReplyHandlesSixteenBitValues() {
        let reply = FakeDDCTransport.reply(command: 0x62, current: 0x0140, max: 0x0200)
        let parsed = DDCPacket.parseGetVCPReply(reply, command: 0x62)
        XCTAssertEqual(parsed?.current, 0x0140)
        XCTAssertEqual(parsed?.max, 0x0200)
    }

    /// *Checksum rejection.* A frame whose header is perfect but whose checksum is wrong
    /// is noise from a wedged controller, not an answer. This is the guard the header
    /// check alone cannot provide.
    /// Kills mutation: dropping the checksum comparison, or comparing it to itself.
    func testParseRejectsBadChecksum() {
        var reply = FakeDDCTransport.reply(command: 0x10, current: 25, max: 100)
        reply[10] ^= 0xFF
        XCTAssertNil(DDCPacket.parseGetVCPReply(reply, command: 0x10))
    }

    /// *NULL/stale frame rejection.* Monitors ack the read and return zeros; byte 6-9 of
    /// zeros would otherwise be parsed as max 0.
    /// Kills mutation: dropping the source-address / opcode / result-code checks.
    func testParseRejectsNullFrame() {
        XCTAssertNil(DDCPacket.parseGetVCPReply([UInt8](repeating: 0, count: 12), command: 0x10))
    }

    /// *VCP echo must match.* A correctly checksummed reply to a *different* feature is
    /// a stale reply left in the controller's buffer; taking it writes one feature's
    /// value into another's slider.
    /// Kills mutation: removing the `reply[4] == command` check.
    func testParseRejectsReplyEchoingADifferentCommand() {
        let reply = FakeDDCTransport.reply(command: 0x12, current: 50, max: 100)
        XCTAssertNil(DDCPacket.parseGetVCPReply(reply, command: 0x10))
    }

    /// *Result code must be 0.* A non-zero result code means the display refused the
    /// feature; its value bytes are meaningless.
    /// Kills mutation: removing the `reply[3] == 0x00` check.
    func testParseRejectsNonZeroResultCode() {
        var reply = FakeDDCTransport.reply(command: 0x10, current: 25, max: 100)
        reply[3] = 0x01
        reply[10] = checksum(of: reply)
        XCTAssertNil(DDCPacket.parseGetVCPReply(reply, command: 0x10))
    }

    /// *Zero max is not a value.* It would make every subsequent percentage write 0.
    /// Kills mutation: dropping `guard maxVal > 0`.
    func testParseRejectsZeroMax() {
        let reply = FakeDDCTransport.reply(command: 0x10, current: 0, max: 0)
        XCTAssertNil(DDCPacket.parseGetVCPReply(reply, command: 0x10))
    }

    /// *Short frames return nil rather than trapping.* The old inline guard read
    /// `count >= 10` and then indexed byte 10; nothing may index past the buffer.
    /// Kills mutation: restoring `>= 10`, or removing the length guard entirely.
    func testParseRejectsFrameShorterThanTheChecksumByte() {
        let short = Array(FakeDDCTransport.reply(command: 0x10, current: 25, max: 100).prefix(10))
        XCTAssertNil(DDCPacket.parseGetVCPReply(short, command: 0x10))
        XCTAssertNil(DDCPacket.parseGetVCPReply([], command: 0x10))
    }

    // MARK: - Engine: what reaches the wire

    /// *Writes put the Set VCP frame on the DDC chip address.* Pins both the bytes and
    /// the 0x37 chip address the seam carries for an ordinary display. The MCDP2900 case
    /// is pinned separately below; this test is what catches the ordinary case regressing
    /// to 0xB7.
    /// Kills mutation: sending the frame to a different chip address, or framing the
    /// write as a Get VCP request.
    func testWriteSendsSetVCPFrameToDisplayChipAddress() {
        let fake = FakeDDCTransport()
        let engine = makeEngine(fake)

        XCTAssertTrue(engine.write(displayID: display, command: brightness, value: 40))

        XCTAssertEqual(fake.sentFrames.count, 1)
        XCTAssertEqual(fake.sentFrames[0].displayID, display)
        XCTAssertEqual(fake.sentFrames[0].chipAddress, 0x37)
        XCTAssertEqual(fake.sentFrames[0].bytes, [0x51, 0x84, 0x03, 0x10, 0x00, 0x28, 0x80])
        XCTAssertEqual(fake.value(displayID: display, code: brightness), 40)
    }

    /// *Reads put the Get VCP request on the wire and parse what comes back.*
    /// Kills mutation: requesting a different VCP code than the caller asked for.
    func testReadSendsGetVCPRequestAndReturnsParsedValue() {
        let fake = FakeDDCTransport()
        fake.setValue(25, max: 100, displayID: display, code: brightness)
        let engine = makeEngine(fake)

        let result = engine.read(displayID: display, command: brightness)

        XCTAssertEqual(result?.current, 25)
        XCTAssertEqual(result?.max, 100)
        XCTAssertEqual(fake.sentFrames.map(\.bytes), [[0x51, 0x82, 0x01, 0x10, 0xAC]])
    }

    /// *A silent display is a failed read, not a crash or a zero.*
    /// Kills mutation: returning a default value when the transport answers nil.
    func testReadReturnsNilWhenTheDisplayDoesNotAnswer() {
        let fake = FakeDDCTransport()
        fake.queueReadFaults([.noResponse], displayID: display, code: brightness)
        let engine = makeEngine(fake)

        XCTAssertNil(engine.read(displayID: display, command: brightness))
    }

    /// *A corrupt reply is thrown away by the protocol layer, not by the transport.*
    /// The fake produced a frame; validation rejected it. That ordering is the whole
    /// point of the seam — checksum logic sits above it.
    /// Kills mutation: moving validation below the seam, or accepting a bad checksum.
    func testCorruptReplyIsRejectedAboveTheSeam() {
        let fake = FakeDDCTransport()
        fake.setValue(25, max: 100, displayID: display, code: brightness)
        fake.queueReadFaults([.badChecksum], displayID: display, code: brightness)
        let engine = makeEngine(fake)

        XCTAssertNil(engine.read(displayID: display, command: brightness))
        XCTAssertEqual(fake.rejectedReplies.count, 1, "the display did answer; validation dropped it")
    }

    /// *Every scripted failure mode ends up as nil, never as a value.* One case per
    /// defence the frame validation provides.
    /// Kills mutation: dropping any single validation branch (each sub-case fails alone).
    func testEveryFaultyReplyModeFailsTheRead() {
        for fault in [FakeDDCTransport.Fault.nullFrame, .wrongCommandEcho, .zeroMax, .badChecksum] {
            let fake = FakeDDCTransport()
            fake.setValue(25, max: 100, displayID: display, code: brightness)
            fake.queueReadFaults([fault], displayID: display, code: brightness)
            let engine = makeEngine(fake)
            XCTAssertNil(engine.read(displayID: display, command: brightness), "\(fault) must fail the read")
        }
    }

    // MARK: - Chip address (MCDP2900-converted HDMI ports)
    //
    // On several Macs the built-in HDMI port emits DisplayPort internally and converts it
    // with a Kinetic/MegaChips MCDP2900, which answers DDC/CI only at 0xB7. Which address
    // a display uses is the transport's discovery (it walks the IORegistry); these tests
    // pin what the protocol layer does with the answer — namely pass it through unaltered
    // and change nothing else about the transaction.

    /// *The requested chip address is the one that reaches the wire.* The protocol layer
    /// must not second-guess the transport's discovery, in either direction.
    /// Kills mutation: hard-coding 0x37 in the engine again, or ignoring the per-display
    /// answer and applying one display's address to another.
    func testEngineSendsOnTheChipAddressTheTransportReports() {
        let mcdp: CGDirectDisplayID = 11
        let fake = FakeDDCTransport()
        fake.setChipAddress(DDCPacket.mcdp29xxChipAddress, displayID: mcdp)
        fake.setValue(25, max: 100, displayID: mcdp, code: brightness)
        fake.setValue(25, max: 100, displayID: display, code: brightness)
        let engine = makeEngine(fake)

        XCTAssertTrue(engine.write(displayID: mcdp, command: brightness, value: 40))
        _ = engine.read(displayID: mcdp, command: brightness)
        XCTAssertTrue(engine.write(displayID: display, command: brightness, value: 40))
        _ = engine.read(displayID: display, command: brightness)

        XCTAssertEqual(fake.sentFrames.map(\.chipAddress), [0xB7, 0xB7, 0x37, 0x37])
    }

    /// *The frame is byte-identical on both chip addresses.* The chip address is I2C
    /// addressing that lives outside the DDC/CI frame, so nothing inside the frame — least
    /// of all the checksum, whose seeds are the 0x6E/0x50 frame addresses — may vary with
    /// it. Getting this wrong would produce frames a monitor silently rejects.
    /// Kills mutation: deriving any frame byte, or a checksum seed, from the chip address.
    func testFramesAreIdenticalAcrossChipAddresses() {
        let mcdp: CGDirectDisplayID = 11
        let fake = FakeDDCTransport()
        fake.setChipAddress(DDCPacket.mcdp29xxChipAddress, displayID: mcdp)
        let engine = makeEngine(fake)

        _ = engine.write(displayID: display, command: brightness, value: 40)
        _ = engine.read(displayID: display, command: brightness)
        _ = engine.write(displayID: mcdp, command: brightness, value: 40)
        _ = engine.read(displayID: mcdp, command: brightness)

        let standard = fake.sentFrames.filter { $0.displayID == display }.map(\.bytes)
        let converted = fake.sentFrames.filter { $0.displayID == mcdp }.map(\.bytes)
        XCTAssertEqual(standard, [[0x51, 0x84, 0x03, 0x10, 0x00, 0x28, 0x80],
                                  [0x51, 0x82, 0x01, 0x10, 0xAC]])
        XCTAssertEqual(converted, standard, "the chip address is not part of the frame")
    }

    /// *A reply is parsed the same way whatever address it arrived on.* Reply validation
    /// is seeded with 0x50, the host address in the frame — never with the chip address.
    /// Kills mutation: seeding `parseGetVCPReply`'s checksum with the chip address.
    func testReplyParsingDoesNotDependOnTheChipAddress() {
        let mcdp: CGDirectDisplayID = 11
        let fake = FakeDDCTransport()
        fake.setChipAddress(DDCPacket.mcdp29xxChipAddress, displayID: mcdp)
        fake.setValue(25, max: 100, displayID: mcdp, code: brightness)
        let engine = makeEngine(fake)

        let result = engine.read(displayID: mcdp, command: brightness)
        XCTAssertEqual(result?.current, 25)
        XCTAssertEqual(result?.max, 100)
    }

    /// *Only `AppleDCPMCDP29XX` selects 0xB7.* This is the whole detection decision, split
    /// out of the IOKit traversal so it can be tested without MCDP hardware. Every
    /// uncertain answer must resolve to the standard address, because that is what makes
    /// the probe safe to run on every Mac.
    /// Kills mutation: matching a prefix/substring of the class name, matching any
    /// non-nil provider class, or defaulting to 0xB7 when the property is missing.
    func testOnlyTheMCDP29XXProviderClassSelectsTheConverterAddress() {
        XCTAssertEqual(DDCPacket.chipAddress(forEPICProviderClass: "AppleDCPMCDP29XX"), 0xB7)

        // Provider classes seen on a non-MCDP Apple Silicon Mac, plus the no-property case.
        for other in ["DCPDP13Service", "AppleDCPDPTXController", "AppleDCPDPTXRemotePort",
                      "DCPDPDevice", "AppleDCPMCDP29XXExtra", "AppleDCPMCDP29", ""] {
            XCTAssertEqual(DDCPacket.chipAddress(forEPICProviderClass: other), 0x37,
                           "\(other) must not be treated as an MCDP2900")
        }
        XCTAssertEqual(DDCPacket.chipAddress(forEPICProviderClass: nil), 0x37)
    }

    // MARK: - Retry

    /// *Reads retry up to three times and stop at the first success.* Two dropped
    /// transactions then an answer: three requests total, one 50 ms pause between each
    /// pair of attempts, and no fourth request.
    /// Kills mutation: retrying forever, retrying without a delay, or continuing to
    /// poll after a successful read.
    func testReadRetriesUntilTheDisplayAnswers() {
        let fake = FakeDDCTransport()
        fake.setValue(25, max: 100, displayID: display, code: brightness)
        fake.queueReadFaults([.noResponse, .noResponse], displayID: display, code: brightness)
        var sleeps: [TimeInterval] = []
        let engine = makeEngine(fake, sleep: { sleeps.append($0) })

        XCTAssertEqual(engine.readWithRetry(displayID: display, command: brightness)?.current, 25)
        XCTAssertEqual(fake.requestCount, 3)
        XCTAssertEqual(sleeps, [0.05, 0.05])
    }

    /// *Retry gives up after exactly three attempts.* An unresponsive display must not
    /// generate unbounded I2C traffic, and the last attempt must not be followed by a
    /// pointless sleep.
    /// Kills mutation: a 4th attempt, a 2nd-attempt-only loop, or sleeping after the
    /// final failure.
    func testReadRetryGivesUpAfterThreeAttempts() {
        let fake = FakeDDCTransport()
        fake.queueReadFaults(
            [.noResponse, .noResponse, .noResponse, .noResponse],
            displayID: display, code: brightness
        )
        var sleeps: [TimeInterval] = []
        let engine = makeEngine(fake, sleep: { sleeps.append($0) })

        XCTAssertNil(engine.readWithRetry(displayID: display, command: brightness))
        XCTAssertEqual(fake.requestCount, 3)
        XCTAssertEqual(sleeps, [0.05, 0.05])
    }

    /// *Writes retry the same way and stop at the first ack.*
    /// Kills mutation: giving up on the first failed write (the common case a single
    /// dropped DDC transaction would otherwise turn into a dead slider).
    func testWriteRetriesUntilTheDisplayAcks() {
        let fake = FakeDDCTransport()
        fake.queueWriteOutcomes([.fail, .fail], displayID: display, code: brightness)
        var sleeps: [TimeInterval] = []
        let engine = makeEngine(fake, sleep: { sleeps.append($0) })

        XCTAssertTrue(engine.writeWithRetry(displayID: display, command: brightness, value: 40))
        XCTAssertEqual(fake.writeCount, 3)
        XCTAssertEqual(sleeps, [0.05, 0.05])
        XCTAssertEqual(fake.value(displayID: display, code: brightness), 40)
    }

    /// *Write retry gives up after three attempts and reports failure.*
    /// Kills mutation: reporting success after exhausting the retries.
    func testWriteRetryGivesUpAfterThreeAttempts() {
        let fake = FakeDDCTransport()
        fake.queueWriteOutcomes([.fail, .fail, .fail, .fail], displayID: display, code: brightness)
        let engine = makeEngine(fake)

        XCTAssertFalse(engine.writeWithRetry(displayID: display, command: brightness, value: 40))
        XCTAssertEqual(fake.writeCount, 3)
    }

    /// *An ack is trusted, even when the value does not take.* Pins deliberate current
    /// behaviour: the write path does not read back, so a monitor that acks and ignores
    /// (BenQ does this for out-of-range input codes) is reported as success. Change this
    /// only with a decision, not by accident.
    /// Kills mutation: adding a silent read-back that turns acks into failures.
    func testWriteThatAcksWithoutEffectIsStillReportedAsSuccess() {
        let fake = FakeDDCTransport()
        fake.queueWriteOutcomes([.ackWithoutEffect], displayID: display, code: brightness)
        let engine = makeEngine(fake)

        XCTAssertTrue(engine.write(displayID: display, command: brightness, value: 40))
        XCTAssertNil(fake.value(displayID: display, code: brightness))
    }

    // MARK: - Read quarantine

    /// *Six consecutive failures quarantine the display's reads.* The 7th read must put
    /// no traffic on the bus at all: a wedged controller degrades further under retry
    /// hammering, and the DCP I2C engine is shared.
    /// Kills mutation: raising/lowering the threshold, or quarantining without actually
    /// short-circuiting the transport call.
    func testSixConsecutiveFailuresQuarantineReads() {
        let fake = FakeDDCTransport()
        let engine = makeEngine(fake)
        // Nothing scripted for this code: every read fails.
        for _ in 0..<6 {
            XCTAssertNil(engine.read(displayID: display, command: brightness))
        }
        XCTAssertEqual(fake.requestCount, 6)

        XCTAssertNil(engine.read(displayID: display, command: brightness))
        XCTAssertEqual(fake.requestCount, 6, "quarantined reads must not touch the bus")
    }

    /// *Five failures are not enough.* Pins the threshold from below.
    /// Kills mutation: quarantining at 5 (or at any count < 6).
    func testFiveFailuresDoNotQuarantine() {
        let fake = FakeDDCTransport()
        let engine = makeEngine(fake)
        for _ in 0..<5 {
            XCTAssertNil(engine.read(displayID: display, command: brightness))
        }
        _ = engine.read(displayID: display, command: brightness)
        XCTAssertEqual(fake.requestCount, 6)
    }

    /// *A success resets the streak.* Five failures, one good read, five more failures:
    /// still no quarantine. Otherwise a marginal-but-working display accumulates its way
    /// into a dead panel over a session.
    /// Kills mutation: removing `readFailStreak[displayID] = 0` on success.
    func testSuccessfulReadResetsTheFailureStreak() {
        let fake = FakeDDCTransport()
        fake.setValue(25, max: 100, displayID: display, code: brightness)
        fake.queueReadFaults(
            [.noResponse, .noResponse, .noResponse, .noResponse, .noResponse, .healthy,
             .noResponse, .noResponse, .noResponse, .noResponse, .noResponse],
            displayID: display, code: brightness
        )
        let engine = makeEngine(fake)

        for _ in 0..<11 { _ = engine.read(displayID: display, command: brightness) }
        XCTAssertEqual(fake.requestCount, 11)

        _ = engine.read(displayID: display, command: brightness)
        XCTAssertEqual(fake.requestCount, 12, "streak reset by the good read; still not quarantined")
    }

    /// *The quarantine expires after 10 minutes and opens one fresh probe window.*
    /// Without expiry a transient burst on a setup that never reconnects would kill
    /// reads for the rest of the session.
    /// Kills mutation: making the quarantine permanent, or letting it lapse early.
    func testQuarantineExpiresAfterTenMinutes() {
        let fake = FakeDDCTransport()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let engine = makeEngine(fake, now: { now })

        for _ in 0..<6 { _ = engine.read(displayID: display, command: brightness) }
        XCTAssertEqual(fake.requestCount, 6)

        now = now.addingTimeInterval(599)
        _ = engine.read(displayID: display, command: brightness)
        XCTAssertEqual(fake.requestCount, 6, "still quarantined one second early")

        fake.setValue(25, max: 100, displayID: display, code: brightness)
        now = now.addingTimeInterval(1)
        XCTAssertEqual(engine.read(displayID: display, command: brightness)?.current, 25)
        XCTAssertEqual(fake.requestCount, 7)
    }

    /// *Quarantine is per display.* One wedged monitor must not silence a healthy one.
    /// Kills mutation: storing the streak or the expiry in a single scalar.
    func testQuarantineIsScopedToOneDisplay() {
        let fake = FakeDDCTransport()
        let healthy: CGDirectDisplayID = 9
        fake.setValue(50, max: 100, displayID: healthy, code: brightness)
        let engine = makeEngine(fake)

        for _ in 0..<6 { _ = engine.read(displayID: display, command: brightness) }

        XCTAssertNil(engine.read(displayID: display, command: brightness))
        XCTAssertEqual(engine.read(displayID: healthy, command: brightness)?.current, 50)
    }

    /// *Writes keep working while reads are quarantined.* The quarantine exists to stop
    /// read hammering; brightness must still be settable on a controller whose reads are
    /// wedged (the documented AOC Q27G3XMN behaviour).
    /// Kills mutation: gating writes on the read quarantine too.
    func testWritesAreNotAffectedByTheReadQuarantine() {
        let fake = FakeDDCTransport()
        let engine = makeEngine(fake)
        for _ in 0..<6 { _ = engine.read(displayID: display, command: brightness) }

        XCTAssertTrue(engine.write(displayID: display, command: brightness, value: 40))
        XCTAssertEqual(fake.value(displayID: display, code: brightness), 40)
    }

    /// *A reconnect lifts the quarantine immediately.* `DDCService.clearCache` /
    /// `invalidateAllChannelMappings` call this when a display goes away or the display
    /// set is reconfigured; a replugged monitor must not inherit the old panel's
    /// failure history.
    /// Kills mutation: clearing only the streak but not the expiry (the display would
    /// stay silent for the rest of the 10-minute window).
    func testResetFailureStateLiftsTheQuarantineOnReconnect() {
        let fake = FakeDDCTransport()
        let engine = makeEngine(fake)
        for _ in 0..<6 { _ = engine.read(displayID: display, command: brightness) }
        XCTAssertEqual(fake.requestCount, 6)

        engine.resetFailureState(for: display)
        fake.setValue(25, max: 100, displayID: display, code: brightness)
        XCTAssertEqual(engine.read(displayID: display, command: brightness)?.current, 25)

        // ...and the whole-set variant does the same for every display.
        for _ in 0..<6 { _ = engine.read(displayID: display, command: 0x99) }
        engine.resetAllFailureState()
        XCTAssertEqual(engine.read(displayID: display, command: brightness)?.current, 25)
    }

    // MARK: - Helpers

    private func makeEngine(
        _ transport: FakeDDCTransport,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { _ in }
    ) -> DDCProtocolEngine {
        DDCProtocolEngine(transport: transport, now: now, sleep: sleep)
    }

    /// DDC/CI reply checksum: 0x50 seeded, XORed over bytes 0-9. Recomputed here rather
    /// than reused from `DDCPacket` so a mutation in the production checksum cannot
    /// quietly move the expected value with it.
    private func checksum(of reply: [UInt8]) -> UInt8 {
        var cs: UInt8 = 0x50
        for b in reply[0...9] { cs ^= b }
        return cs
    }
}
