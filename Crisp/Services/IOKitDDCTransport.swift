import Foundation
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

/// The real I2C plumbing behind `DDCTransport`: finds a display's DDC channel and
/// moves bytes over it. Two hardware paths:
///   - ARM64 (Apple Silicon): IOAVService via DCPAVServiceProxy
///   - x86_64 (Intel):        IOFramebuffer I2C via IOFBCopyI2CInterfaceForBus
///
/// Nothing here interprets a DDC/CI frame; framing, checksums and validation live above
/// the seam in `DDCPacket` / `DDCProtocolEngine`. The only non-public API used is the
/// `IOAVService*` family — undocumented but exported by IOKit, talking to the display
/// controller's I2C bus and never to WindowServer (see AGENTS.md §3).
///
/// All entry points are called on `DDCService`'s serial queue.
final class IOKitDDCTransport: DDCTransport, @unchecked Sendable {

    /// Reports the AVService-mapping ambiguity warning to whoever owns the UI. Set once
    /// by `DDCService`; nil on Intel, where there is no proximity matching to be unsure
    /// about.
    var onMappingWarning: ((String?) -> Void)?

    // MARK: - IOAVService Cache (ARM64 only)

#if arch(arm64)
    private var avServiceCache: [CGDirectDisplayID: IOAVServiceRef] = [:]
    private let avServiceLock = NSLock()
    /// Ordered list of all working external AVServices found during last enumeration.
    private var allExternalAVServices: [IOAVServiceRef] = []
#endif

    // MARK: - DDCTransport

    func send(_ frame: [UInt8], to displayID: CGDirectDisplayID, chipAddress: UInt8) -> Bool {
#if arch(arm64)
        return arm64Send(frame, to: displayID, chipAddress: chipAddress)
#else
        return intelSend(frame, to: displayID)
#endif
    }

    func request(
        _ frame: [UInt8],
        replyLength: Int,
        from displayID: CGDirectDisplayID,
        chipAddress: UInt8,
        isValidReply: ([UInt8]) -> Bool
    ) -> [UInt8]? {
#if arch(arm64)
        return arm64Request(frame, replyLength: replyLength, from: displayID,
                            chipAddress: chipAddress, isValidReply: isValidReply)
#else
        return intelRequest(frame, replyLength: replyLength, from: displayID,
                            isValidReply: isValidReply)
#endif
    }

    /// Invalidates the cached IOAVService for the given display (e.g. after display
    /// reconnect). No-op on Intel, which resolves its framebuffer per operation.
    func invalidateChannel(for displayID: CGDirectDisplayID) {
#if arch(arm64)
        avServiceLock.lock()
        avServiceCache.removeValue(forKey: displayID)
        avServiceLock.unlock()
#endif
    }

    /// Drops every cached display-to-AVService pairing so the next DDC operation
    /// re-walks the registry and re-matches by identity. No-op on Intel.
    func invalidateAllChannels() {
#if arch(arm64)
        avServiceLock.lock()
        avServiceCache.removeAll()
        allExternalAVServices.removeAll()
        avServiceLock.unlock()
#endif
    }

    // MARK: - ARM64 IOAVService Path

#if arch(arm64)
    // MARK: - ARM64 IORegistry-based AVService matching

    /// Builds a display→AVService map by walking the IOService registry depth-first.
    ///
    /// On Apple Silicon the DDC channel (DCPAVServiceProxy) and the display's identity
    /// (DisplayAttributes → ProductAttributes) live in *sibling* subtrees under the same
    /// dispextN node, the identity is NOT an ancestor of the AVService, so an upward
    /// parent-chain walk never finds it (the old approach always fell through to a
    /// sorted-CGDirectDisplayID index, which mis-pairs channels and drives the wrong
    /// monitor). A depth-first traversal instead visits each display's framebuffer
    /// identity immediately before that same display's DCPAVServiceProxy, so every
    /// AVService can be associated with the most recently seen identity. This is the
    /// same proximity strategy MonitorControl uses.
    ///
    /// Matching order:
    ///   1. Identity: vendor+product+serial, then vendor+product, against CG displays.
    ///   2. Traversal-order fallback for anything identity matching missed (e.g. two
    ///      identical monitors that share vendor/product/serial). This preserves correct
    ///      pairing far better than the old sorted-index because the AVService order
    ///      follows the framebuffer order within the same subtree.
    ///
    /// Returns the map plus the working AVServices in traversal order.
    private func buildAVServiceMapByProximity() -> (map: [CGDirectDisplayID: IOAVServiceRef], ordered: [IOAVServiceRef]) {
        // External CG displays we need to map.
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        let externalIDs = (0..<Int(displayCount))
            .map { displayIDs[$0] }
            .filter { CGDisplayIsBuiltin($0) == 0 }
        guard !externalIDs.isEmpty else { return ([:], []) }

        // Depth-first walk of the entire IOService plane.
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return ([:], []) }
        defer { IOObjectRelease(iterator) }

        var ordered: [IOAVServiceRef] = []
        var identities: [DDCServiceMatcher.Identity?] = []
        var lastIdentity: DDCServiceMatcher.Identity? = nil

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            // Update the running identity whenever a framebuffer node exposes one.
            if let da = IORegistryEntryCreateCFProperty(
                    entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
               )?.takeRetainedValue() as? [String: Any],
               let pa = da["ProductAttributes"] as? [String: Any],
               let id = displayIdentity(from: pa) {
                lastIdentity = id
            }

            // A DCPAVServiceProxy that answers I2C is a live DDC channel.
            if ioClassName(entry) == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String
                // Some drivers omit "Location"; still attempt those. Skip explicit non-External.
                if location == nil || location == "External",
                   let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) {
                    var testBuf = [UInt8](repeating: 0, count: 32)
                    if IOAVServiceReadI2C(avService, 0x37, 0x51, &testBuf, 32) == kIOReturnSuccess {
                        ordered.append(avService)
                        identities.append(lastIdentity)
                    }
                }
            }

            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        // Strategy 1 + Strategy 2 + the ambiguity flag live in the pure, headless-testable
        // `DDCServiceMatcher` (Crisp/Models/DDCServiceMatcher.swift). Its inputs are the
        // IORegistry identities collected above (already `DDCServiceMatcher.Identity`) and
        // the CoreGraphics display list; the matching semantics are byte-for-byte those the
        // inline code used previously.
        let displays: [(id: CGDirectDisplayID, identity: DDCServiceMatcher.Identity)] = externalIDs.map {
            (id: $0, identity: DDCServiceMatcher.Identity(
                vendor: CGDisplayVendorNumber($0),
                product: CGDisplayModelNumber($0),
                serial: CGDisplaySerialNumber($0)))
        }
        let result = DDCServiceMatcher.match(services: identities, displays: displays)

        var map: [CGDirectDisplayID: IOAVServiceRef] = [:]
        // Safe: each CGDirectDisplayID key is assigned exactly once, so the unspecified
        // Dictionary iteration order cannot drop or overwrite an entry.
        for (displayID, serviceIndex) in result.byDisplayID {
            map[displayID] = ordered[serviceIndex]
        }

        // Warn only when the fallback had to guess among >1 indistinguishable displays.
        let warning = result.ambiguous
            ? "Multiple external displays: DDC identity matching failed; using traversal order"
            : nil
        onMappingWarning?(warning)

        return (map, ordered)
    }

    /// Extracts vendor/product/serial from a ProductAttributes dictionary. The numeric
    /// LegacyManufacturerID / ProductID / SerialNumber match CGDisplayVendorNumber /
    /// CGDisplayModelNumber / CGDisplaySerialNumber for the same physical display.
    private func displayIdentity(from productAttributes: [String: Any]) -> DDCServiceMatcher.Identity? {
        func u32(_ value: Any?) -> UInt32? {
            if let v = value as? UInt32 { return v }
            if let v = value as? Int { return UInt32(bitPattern: Int32(truncatingIfNeeded: v)) }
            if let v = value as? NSNumber { return v.uint32Value }
            return nil
        }
        guard let vendor = u32(productAttributes["LegacyManufacturerID"]),
              let product = u32(productAttributes["ProductID"]) else { return nil }
        return DDCServiceMatcher.Identity(vendor: vendor, product: product,
                                          serial: u32(productAttributes["SerialNumber"]) ?? 0)
    }

    /// Returns the IOKit class name of a registry entry.
    private func ioClassName(_ entry: io_service_t) -> String? {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buf.deallocate() }
        guard IOObjectGetClass(entry, buf) == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }

    /// Finds the IOAVService for the given display. Caches the result per display.
    /// Returns nil if no working AVService is found (built-in displays, or displays
    /// that don't support DDC over the Apple Silicon AV path).
    ///
    /// Matching strategy: depth-first IOService traversal that pairs each DDC channel
    /// with the display identity seen closest to it in the registry (see
    /// buildAVServiceMapByProximity), then vendor/product/serial matching against the
    /// CoreGraphics display list, with a traversal-order fallback.
    private func findAVService(for displayID: CGDirectDisplayID) -> IOAVServiceRef? {
        // Fast path: return cached service if present
        avServiceLock.lock()
        if let cached = avServiceCache[displayID] {
            avServiceLock.unlock()
            return cached
        }
        avServiceLock.unlock()

        // Slow path: enumerate the IOService registry depth-first, pairing each working
        // DDC channel with the nearest preceding display identity.
        let (serviceMap, ordered) = buildAVServiceMapByProximity()

        guard !ordered.isEmpty else {
            return nil
        }

        // Re-check cache (double-checked locking) in case another thread enumerated
        // and populated the cache while we were enumerating without the lock held.
        avServiceLock.lock()
        if let cached = avServiceCache[displayID] {
            avServiceLock.unlock()
            return cached
        }
        allExternalAVServices = ordered
        for (extID, avService) in serviceMap {
            avServiceCache[extID] = avService
        }
        let result = avServiceCache[displayID]
        avServiceLock.unlock()

        return result
    }

    /// ARM64 DDC write. `IOAVServiceWriteI2C` takes the frame's leading source byte
    /// (0x51) as its separate `dataAddress` argument, so only the rest of the frame
    /// travels in the buffer.
    private func arm64Send(_ frame: [UInt8], to displayID: CGDirectDisplayID, chipAddress: UInt8) -> Bool {
        guard frame.count >= 2, let avService = findAVService(for: displayID) else { return false }

        var buf = Array(frame.dropFirst())
        let ret = IOAVServiceWriteI2C(avService, UInt32(chipAddress), UInt32(frame[0]),
                                      &buf, UInt32(buf.count))
        return ret == kIOReturnSuccess
    }

    /// ARM64 DDC read: send the request frame, then read the reply from the same
    /// sub-address.
    private func arm64Request(
        _ frame: [UInt8],
        replyLength: Int,
        from displayID: CGDirectDisplayID,
        chipAddress: UInt8,
        isValidReply: ([UInt8]) -> Bool
    ) -> [UInt8]? {
        guard frame.count >= 2, let avService = findAVService(for: displayID) else { return nil }

        var requestBuf = Array(frame.dropFirst())
        let writeRet = IOAVServiceWriteI2C(avService, UInt32(chipAddress), UInt32(frame[0]),
                                          &requestBuf, UInt32(requestBuf.count))
        guard writeRet == kIOReturnSuccess else {
            return nil
        }

        // Wait for the display to prepare its DDC/CI reply (~40ms per spec)
        Thread.sleep(forTimeInterval: 0.04)

        // Read the VCP reply
        var replyBuf = [UInt8](repeating: 0, count: replyLength)
        let readRet = IOAVServiceReadI2C(avService, UInt32(chipAddress), UInt32(frame[0]),
                                         &replyBuf, UInt32(replyBuf.count))
        guard readRet == kIOReturnSuccess else {
            return nil
        }

        // One channel per display here, so there is nothing else to try: an unusable
        // frame is simply a failed read.
        return isValidReply(replyBuf) ? replyBuf : nil
    }
#endif

    // MARK: - Intel (x86_64) IOFramebuffer Path
    //
    // Compiled on both architectures (as it was before the seam existed) so that a
    // change made on Apple Silicon still type-checks the Intel slice of a universal build.

    /// Finds the IOFramebuffer service for a given external display.
    /// Returns a retained io_service_t, caller must IOObjectRelease.
    private func framebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        // Strategy 1: Use CGDisplayIOServicePort (deprecated but functional on macOS 15)
        let servicePort = CGDisplayIOServicePort(displayID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            var parent: io_service_t = 0
            if IORegistryEntryGetParentEntry(servicePort, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 {
                return parent
            }
        }

        // Strategy 2: Fallback to vendor+model matching
        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }

            guard let cfDict = IODisplayCreateInfoDictionary(
                service,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? NSDictionary else { continue }

            // Extract vendor and model IDs (may be stored as UInt32 or Int)
            let sVendor: UInt32
            let sModel: UInt32
            if let v = cfDict["DisplayVendorID"] as? UInt32 { sVendor = v } else if let v = cfDict["DisplayVendorID"] as? Int {
                sVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let m = cfDict["DisplayProductID"] as? UInt32 { sModel = m } else if let m = cfDict["DisplayProductID"] as? Int {
                sModel = UInt32(bitPattern: Int32(truncatingIfNeeded: m))
            } else { continue }

            guard sVendor == vendor && sModel == model else { continue }

            // Walk up to parent IOFramebuffer
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { continue }
            // Caller must release parent
            return parent
        }
        return nil
    }

    /// Intel DDC write. The frame goes out whole (its leading 0x51 is part of the send
    /// buffer here) to the fixed DDC/CI destination address 0x6E; the `chipAddress` the
    /// seam carries is the AV path's 7-bit form and has no counterpart in IOI2CRequest.
    private func intelSend(_ frame: [UInt8], to displayID: CGDirectDisplayID) -> Bool {
        guard let fb = framebufferService(for: displayID) else {
            return false
        }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses (DDC bus is not always bus 0)
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            var buf = frame
            let bufCount = buf.count

            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ptr = raw.baseAddress else { return false }
                var req = IOI2CRequest()
                req.commFlags           = 0
                req.sendAddress         = 0x6E
                req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                req.sendSubAddress      = 0
                req.sendBuffer          = UInt(bitPattern: ptr)
                req.sendBytes           = UInt32(bufCount)
                req.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                req.replyBytes          = 0
                req.minReplyDelay       = 10_000_000 // 10ms
                let kr = IOI2CSendRequest(conn, IOOptionBits(0), &req)
                return kr == KERN_SUCCESS && req.result == KERN_SUCCESS
            }
            if ok {
                return true
            }
        }
        return false
    }

    /// Intel DDC read. Send and reply are one IOI2CRequest, and the bus scan continues
    /// past any bus that completes the transaction without producing a reply the caller
    /// accepts — on Intel the DDC bus index is unknown, and a wrong bus can still ack.
    private func intelRequest(
        _ frame: [UInt8],
        replyLength: Int,
        from displayID: CGDirectDisplayID,
        isValidReply: ([UInt8]) -> Bool
    ) -> [UInt8]? {
        guard let fb = framebufferService(for: displayID) else { return nil }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            var sendBuf = frame
            var replyBuf = [UInt8](repeating: 0, count: replyLength)
            var transactionOK = false

            let sendCount  = sendBuf.count
            let replyCount = replyBuf.count

            sendBuf.withUnsafeMutableBytes { sendRaw in
                replyBuf.withUnsafeMutableBytes { replyRaw in
                    guard let sp = sendRaw.baseAddress,
                          let rp = replyRaw.baseAddress else { return }

                    var req = IOI2CRequest()
                    req.commFlags           = 0
                    req.sendAddress         = 0x6E
                    req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    req.sendSubAddress      = 0
                    req.sendBuffer          = UInt(bitPattern: sp)
                    req.sendBytes           = UInt32(sendCount)
                    req.replyAddress        = 0x6F
                    req.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                    req.replySubAddress     = 0
                    req.replyBuffer         = UInt(bitPattern: rp)
                    req.replyBytes          = UInt32(replyCount)
                    req.minReplyDelay       = 50_000_000 // 50ms

                    guard IOI2CSendRequest(conn, IOOptionBits(0), &req) == KERN_SUCCESS,
                          req.result == KERN_SUCCESS else { return }
                    transactionOK = true
                }
            }
            if transactionOK, isValidReply(replyBuf) { return replyBuf }
        }
        return nil
    }
}
