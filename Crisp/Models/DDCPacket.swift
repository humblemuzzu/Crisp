import Foundation

/// Pure DDC/CI packet framing and reply validation — the wire format, with no I/O.
///
/// Extracted verbatim in semantics from `DDCService`'s `arm64Write` / `arm64Read` /
/// `intelWriteSynchronous` / `intelReadSynchronous`, which each open-coded the same
/// frame layout and checksum. Both hardware paths send byte-identical frames; they
/// only differ in how the frame is handed to the kernel (IOAVService takes the leading
/// source byte as a separate sub-address argument, IOI2C takes the whole frame as the
/// send buffer). Keeping the bytes here means the format is asserted in tests instead
/// of being trusted twice.
enum DDCPacket {
    /// I2C chip address of a DDC/CI display: the 7-bit form of the 0x6E destination
    /// address. A later phase adds 0xB7 for Macs whose built-in HDMI routes through the
    /// MCDP2900 converter, which is why the chip address travels through the transport
    /// seam instead of being hard-coded in the I/O calls.
    static let displayChipAddress: UInt8 = 0x37

    /// DDC/CI destination address, and therefore the checksum seed for host→display frames.
    static let destinationAddress: UInt8 = 0x6E

    /// Host source address (0x50 | 0x01); first byte of every host→display frame.
    static let sourceAddress: UInt8 = 0x51

    /// Checksum seed for display→host frames: the host address the display replies to.
    static let replySeed: UInt8 = 0x50

    /// Bytes requested for a Get VCP reply. The frame itself is 11 bytes; both paths have
    /// always asked for 12 and monitors tolerate the extra byte, so it stays 12.
    static let replyLength = 12

    /// XOR checksum over `bytes`, seeded with the frame's address byte.
    static func checksum(seed: UInt8, over bytes: ArraySlice<UInt8>) -> UInt8 {
        var cs = seed
        for b in bytes { cs ^= b }
        return cs
    }

    /// Set VCP Feature frame: `[0x51, 0x84, 0x03, vcp, valueHigh, valueLow, checksum]`.
    static func setVCP(command: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [
            sourceAddress, 0x84, 0x03, command,
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return body + [checksum(seed: destinationAddress, over: body[...])]
    }

    /// Get VCP Feature request frame: `[0x51, 0x82, 0x01, vcp, checksum]`.
    static func getVCP(command: UInt8) -> [UInt8] {
        let body: [UInt8] = [sourceAddress, 0x82, 0x01, command]
        return body + [checksum(seed: destinationAddress, over: body[...])]
    }

    /// Parses a Get VCP Feature reply, returning nil for anything that is not provably
    /// a well-formed answer to `command`.
    ///
    /// Reply layout:
    ///   [0] source address (0x6E)
    ///   [1] length byte (0x88 = 0x80 | 8)
    ///   [2] Get VCP Feature Reply opcode (0x02)
    ///   [3] result code (0x00 = no error)
    ///   [4] VCP opcode echo
    ///   [5] VCP type code
    ///   [6][7] max value, high/low
    ///   [8][9] current value, high/low
    ///  [10] checksum
    ///
    /// Many monitors ack the I2C read yet return stale EDID bytes or a null frame instead
    /// of a real VCP reply, especially over the Apple Silicon AV path. Reading bytes 6–9
    /// from such garbage yields a bogus "max" (e.g. 8824 instead of 100), which compresses
    /// the usable brightness range so the top of the slider does nothing — hence the
    /// signature check. The signature is only 4 bytes of protection, and a wedged DDC
    /// controller (seen on the AOC Q27G3XMN) streams noise that acks reads, so a lucky
    /// frame can pass it with garbage values; the DDC/CI checksum must match too.
    ///
    /// (The length guard reads `>= 11`, not the `>= 10` the two call sites used before
    /// this was extracted: the old bound admitted a 10-byte buffer and then indexed byte
    /// 10. Unreachable in production — both paths always allocate 12 — but the pure
    /// function must not trade a bad reply for a trap.)
    static func parseGetVCPReply(_ reply: [UInt8], command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 11 else { return nil }

        guard reply[0] == destinationAddress,  // source address
              reply[2] == 0x02,                // Get VCP Feature Reply opcode
              reply[3] == 0x00,                // result code: no error
              reply[4] == command              // echo of the VCP code we asked for
        else { return nil }

        guard checksum(seed: replySeed, over: reply[0...9]) == reply[10] else { return nil }

        let maxVal = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let curVal = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        // A zero max is also invalid (would make every write 0); reject it.
        guard maxVal > 0 else { return nil }
        return (current: curVal, max: maxVal)
    }
}
