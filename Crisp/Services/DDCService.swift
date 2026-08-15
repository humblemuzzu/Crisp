import Foundation
import Combine
import CoreGraphics

/// DDC/CI service for external displays: the VCP read cache, the serial I2C queue and
/// the async API the app and `crispctl` call.
///
/// The layers below it are split at the raw I2C boundary so they can be tested without
/// a monitor attached:
///   - `DDCPacket`          frame layout, checksums, reply validation (pure)
///   - `DDCProtocolEngine`  retry and the read quarantine (pure, transport-driven)
///   - `DDCTransport`       the seam; `IOKitDDCTransport` is the only conformer that
///                          touches hardware (IOAVService on Apple Silicon,
///                          IOFramebuffer I2C on Intel)
///
/// All I2C operations run on a private background queue to avoid blocking UI.
final class DDCService: ObservableObject, @unchecked Sendable {
    static let shared = DDCService()

    // VCP feature codes (DDC/CI standard)
    static let brightnessVCP: UInt8 = 0x10
    static let contrastVCP: UInt8   = 0x12
    static let volumeVCP: UInt8     = 0x62
    static let powerVCP: UInt8      = 0xD6

    private let ddcQueue = DispatchQueue(label: "com.crisp.ddc", qos: .userInitiated)

    /// The hardware side of the seam, and the protocol logic driving it. The engine's
    /// quarantine state is unsynchronised and must only be touched on `ddcQueue`.
    private let transport: IOKitDDCTransport
    private let engine: DDCProtocolEngine

    /// Mapping warning exposed to UI when more than one external display is connected
    /// and we fall back to traversal-order AVService assignment. Apple Silicon only:
    /// the Intel path resolves its channel per operation and never guesses.
    @Published var mappingWarning: String? = nil

    // MARK: - VCP Read Cache (5-second TTL)

    private struct VCPCacheEntry {
        let current: UInt16
        let max: UInt16
        let timestamp: Date
        var isExpired: Bool { Date().timeIntervalSince(timestamp) > 5.0 }
    }

    private var vcpCache: [CGDirectDisplayID: [UInt8: VCPCacheEntry]] = [:]
    private let cacheLock = NSLock()

    private init() {
        let transport = IOKitDDCTransport()
        self.transport = transport
        self.engine = DDCProtocolEngine(transport: transport)
        transport.onMappingWarning = { [weak self] warning in
            DispatchQueue.main.async { self?.mappingWarning = warning }
        }
    }

    // MARK: - Cache Cleanup

    /// Removes all cached VCP entries for a display that is no longer connected.
    func clearCache(for displayID: CGDirectDisplayID) {
        cacheLock.lock()
        vcpCache.removeValue(forKey: displayID)
        cacheLock.unlock()
        ddcQueue.async {
            self.engine.resetFailureState(for: displayID)
        }
        // Synchronously, not on ddcQueue: any DDC operation already queued for this
        // display must re-discover its channel rather than reuse a stale one.
        transport.invalidateChannel(for: displayID)
    }

    /// Drops every cached display-to-channel pairing (and read quarantines) so the next
    /// DDC operation re-walks the registry and re-matches by identity. Called on any
    /// display reconfiguration: CGDisplay IDs get reshuffled across reconnect storms on
    /// Apple Silicon, and two IDs that both survive a storm can end up naming swapped
    /// physical panels. A per-removed-ID cleanup never sees that, and the stale map then
    /// writes one monitor's brightness into the other's channel.
    func invalidateAllChannelMappings() {
        ddcQueue.async {
            self.engine.resetAllFailureState()
        }
        transport.invalidateAllChannels()
    }

    // MARK: - Public Async API (with retry)

    /// Asynchronously write a VCP value, retrying up to 3 times.
    /// Invalidates the cache for the written VCP code on success.
    func writeAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        value: UInt16,
        completion: ((Bool) -> Void)? = nil
    ) {
        ddcQueue.async {
            let ok = self.engine.writeWithRetry(displayID: displayID, command: command, value: value)
            if ok {
                // Invalidate cached value so next read reflects the new setting.
                self.cacheLock.lock()
                self.vcpCache[displayID]?[command] = nil
                self.cacheLock.unlock()
            }
            completion?(ok)
        }
    }

    /// Asynchronously read a VCP value.
    /// Returns a cached result if available and not expired (5-second TTL).
    func readAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        completion: @escaping ((current: UInt16, max: UInt16)?) -> Void
    ) {
        // Fast path: return cached value if still fresh
        cacheLock.lock()
        if let entry = vcpCache[displayID]?[command], !entry.isExpired {
            cacheLock.unlock()
            completion((current: entry.current, max: entry.max))
            return
        }
        cacheLock.unlock()

        ddcQueue.async {
            guard let r = self.engine.readWithRetry(displayID: displayID, command: command) else {
                completion(nil)
                return
            }
            self.cacheLock.lock()
            if self.vcpCache[displayID] == nil { self.vcpCache[displayID] = [:] }
            self.vcpCache[displayID]![command] = VCPCacheEntry(
                current: r.current, max: r.max, timestamp: Date()
            )
            self.cacheLock.unlock()
            completion(r)
        }
    }

    /// Reads a batch of common VCP codes asynchronously.
    /// Every requested code appears in the result dictionary:
    ///   - `.some(value)` means the code was read successfully (or served from cache)
    ///   - `.none` means the I2C read was attempted but failed
    func readBatchVCPCodes(displayID: CGDirectDisplayID) async -> [UInt8: UInt16?] {
        let codes: [UInt8] = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x87, 0xD6, 0xDC]

        // Check if we have a full fresh cache for all codes
        let cachedResult: [UInt8: UInt16?]? = cacheLock.withLock {
            guard let existingCache = vcpCache[displayID] else { return nil }
            let allCached = codes.allSatisfy { existingCache[$0].map { !$0.isExpired } ?? false }
            guard allCached else { return nil }
            return Dictionary(uniqueKeysWithValues: codes.map { code -> (UInt8, UInt16?) in
                guard let entry = existingCache[code] else { return (code, nil) }
                return (code, entry.current)
            })
        }
        if let cachedResult {
            return cachedResult
        }

        return await withCheckedContinuation { continuation in
            ddcQueue.async {
                var result: [UInt8: UInt16?] = [:]
                var cachedCodes = Set<UInt8>()

                // Seed result with any still-valid cached values
                self.cacheLock.lock()
                if let cache = self.vcpCache[displayID] {
                    for code in codes {
                        if let entry = cache[code], !entry.isExpired {
                            result[code] = entry.current
                            cachedCodes.insert(code)
                        }
                    }
                }
                self.cacheLock.unlock()

                // For each code with no fresh cache entry, perform a real I2C read.
                // A single attempt each, deliberately: retrying every code three times
                // is what wedges a marginal DDC controller.
                // Every code ends up in result: success → .some(value), failure → .none.
                for code in codes {
                    if cachedCodes.contains(code) { continue }
                    if let r = self.engine.read(displayID: displayID, command: code) {
                        result[code] = r.current
                        self.cacheLock.lock()
                        if self.vcpCache[displayID] == nil { self.vcpCache[displayID] = [:] }
                        self.vcpCache[displayID]![code] = VCPCacheEntry(
                            current: r.current, max: r.max, timestamp: Date()
                        )
                        self.cacheLock.unlock()
                        // No extra delay here, the transport already waits 40ms per DDC/CI spec
                    } else {
                        result[code] = nil
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }
}
