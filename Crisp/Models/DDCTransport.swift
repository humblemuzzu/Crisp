import CoreGraphics

/// The raw I2C boundary of the DDC stack: bytes in, bytes out, nothing interpreted.
///
/// Everything that makes DDC/CI work — frame layout, checksums, reply validation,
/// retries, the read quarantine — lives *above* this seam (`DDCPacket`,
/// `DDCProtocolEngine`) and is therefore testable without a monitor. Everything below
/// it is kernel plumbing: finding the display's channel (IOAVService on Apple Silicon,
/// an IOFramebuffer I2C bus on Intel) and moving the bytes.
///
/// The production conformer is `IOKitDDCTransport`; `FakeDDCTransport` in the test
/// target scripts monitors that answer, lie, or say nothing.
protocol DDCTransport: AnyObject, Sendable {
    /// The I2C chip address this display's DDC channel answers on.
    ///
    /// The chip address is a property of the *link*, not of the protocol: a display on a
    /// Mac's built-in HDMI port may sit behind an MCDP2900 converter that only answers at
    /// 0xB7 (`DDCPacket.mcdp29xxChipAddress`), and only the transport — which walks the
    /// IORegistry to find the channel in the first place — can know that. So the transport
    /// reports the address and the protocol layer passes it straight back down through
    /// `send` / `request`, keeping the wire address explicit on every call instead of
    /// hidden inside the I/O.
    ///
    /// Must fall back to `DDCPacket.displayChipAddress` whenever the answer is unknown.
    ///
    /// The address the protocol layer then passes back down is what it *asked for*, and
    /// a transport that caches channels is free to prefer the address from the lookup
    /// that produced the channel it is about to use: a display reconfiguration between
    /// the two calls invalidates caches synchronously, and pairing an address from
    /// before it with a service from after it would be a link that never existed.
    /// `IOKitDDCTransport` does exactly that on Apple Silicon.
    func chipAddress(for displayID: CGDirectDisplayID) -> UInt8

    /// Sends a host→display frame that expects no reply (Set VCP).
    /// - Returns: true if the display acked the transaction. An ack means the bytes
    ///   reached the panel, not that it honoured them.
    func send(_ frame: [UInt8], to displayID: CGDirectDisplayID, chipAddress: UInt8) -> Bool

    /// Sends a request frame and returns the display's raw reply (Get VCP).
    ///
    /// `isValidReply` is the protocol layer's own validation, passed down so the
    /// transport can keep looking when a channel answers with a frame that is not a
    /// real reply: the Intel path probes up to 8 I2C buses per display and only the
    /// true DDC bus returns a well-formed frame, so it must not stop at the first bus
    /// that merely completes a transaction. The transport never interprets reply bytes
    /// itself — it only asks.
    ///
    /// - Returns: the first reply `isValidReply` accepts, or nil if no channel produced one.
    func request(
        _ frame: [UInt8],
        replyLength: Int,
        from displayID: CGDirectDisplayID,
        chipAddress: UInt8,
        isValidReply: ([UInt8]) -> Bool
    ) -> [UInt8]?

    /// Drops any cached channel for a display that went away. Must be a no-op when
    /// nothing is cached: a disconnect has to stay harmless.
    func invalidateChannel(for displayID: CGDirectDisplayID)

    /// Drops every cached display→channel pairing, so the next operation re-discovers
    /// and re-matches. Called on any display reconfiguration.
    func invalidateAllChannels()
}
