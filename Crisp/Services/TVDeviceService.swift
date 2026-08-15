import Foundation
import os.log

private let tvServiceLog = Logger(subsystem: "com.crisp.app", category: "TVDeviceService")

/// Smart TVs the user has added: the list, the binding to a display, and the
/// coalescing in front of the network.
///
/// **Opt-in, always.** Nothing in this file runs at launch. There is no LAN scan
/// when the app starts, no background discovery, no periodic poll of a device the
/// user is not looking at. A packet leaves this Mac when the user asks for one —
/// adds a TV, opens the TV section, moves a control, or fires an automation they
/// wrote. An app that controls monitors has no business probing the network of
/// someone who owns no television, and "it is only a few packets" is where every
/// piece of unwanted background traffic starts.
///
/// **What it does not decide.** Whether an action may happen is
/// `TVActionRequest.plan` and `TVWriteGate.approve`; what a platform can reach is
/// `TVFeatureRegistry`; what a certificate means is `TVTrust`; and the socket
/// conversation itself is `TVConversation`, shared with `crispctl` so the two
/// cannot drift. All the deciding parts are pure and tested headlessly. This file
/// is the observable list, the store, and the pump.
@MainActor
final class TVDeviceService: ObservableObject {
    static let shared = TVDeviceService()

    /// Every TV the user has added. Mirrors the store so SwiftUI has something to
    /// observe; the store is the source of truth.
    @Published private(set) var devices: [TVDevice] = []

    /// What Crisp last saw of each TV. Populated only by an action the user asked
    /// for — never by a poll.
    @Published private(set) var states: [TVDeviceID: TVConversation.Readback] = [:]

    private let store: DisplayStateStore
    private let credentials: TVCredentialStore

    /// One pacer per television. Samsung drops the *connection* when keys arrive
    /// faster than about one a second, so this is not politeness — it is what
    /// stops a volume drag from un-pairing the TV.
    private var pacers: [TVDeviceID: TizenKeyPacer] = [:]

    /// Latest backlight percent queued per device, and whether a write is in
    /// flight — the same coalescing shape as the DDC pump, for the same reason: a
    /// drag emits far more values than the link can carry, and only the last one
    /// is wanted.
    private var pendingBacklight: [TVDeviceID: Double] = [:]
    private var backlightInFlight: Set<TVDeviceID> = []

    init(store: DisplayStateStore = .shared, credentials: TVCredentialStore = .shared) {
        self.store = store
        self.credentials = credentials
        self.devices = store.tvDevices
    }

    // MARK: - The device list

    func device(id: TVDeviceID) -> TVDevice? { devices.first { $0.id == id } }

    /// The platforms of every paired device, which is what
    /// `TVActionRequest.plan` needs in order to decide anything.
    var knownPlatforms: [TVDeviceID: TVPlatform] {
        Dictionary(devices.map { ($0.id, $0.platform) }, uniquingKeysWith: { first, _ in first })
    }

    /// Adds or updates a device record. Identity wins over address: re-adding a
    /// TV that moved to a new IP updates the host on the existing record instead
    /// of creating a second one — which is the bug keying on the address would
    /// have produced in the first place.
    func upsert(_ device: TVDevice) {
        var updated = devices
        if let index = updated.firstIndex(where: { $0.id == device.id }) {
            updated[index] = device.normalized()
        } else {
            updated.append(device.normalized())
        }
        persist(updated)
    }

    func rename(_ id: TVDeviceID, to name: String) {
        guard var device = device(id: id) else { return }
        device.name = name
        upsert(device)
    }

    /// Removes a TV and **its credentials**.
    ///
    /// Leaving the client key or token behind would mean a later re-add silently
    /// reuses a credential the user believed they had revoked — and on Tizen, a
    /// token the television may have forgotten since, which fails in a way that
    /// looks like the TV is broken. The pinned certificate goes too, so a
    /// replaced television pins afresh rather than being refused forever.
    func remove(_ id: TVDeviceID) {
        credentials.removeAll(for: id)
        states[id] = nil
        pacers[id] = nil
        persist(devices.filter { $0.id != id })
        // Any display bound to it is unbound, or its brightness ladder would keep
        // claiming a `.tvNetwork` rung with nothing behind it.
        for uuid in store.uuids(where: { $0.tvDevice == id }) {
            store.update(uuid) { $0.tvDevice = nil }
        }
    }

    private func persist(_ list: [TVDevice]) {
        store.setTVDevices(list)
        devices = store.tvDevices
    }

    private func pacer(for id: TVDeviceID) -> TizenKeyPacer {
        if let existing = pacers[id] { return existing }
        let created = TizenKeyPacer()
        pacers[id] = created
        return created
    }

    // MARK: - Display binding

    /// Binds a display to a TV, or clears the binding with `nil`.
    ///
    /// Only the user can make this connection: a `CGDirectDisplay` and a device
    /// on the LAN share no identifier, and inferring one from resolution or EDID
    /// name would be a guess that silently sends commands to a television in
    /// another room.
    func bind(_ id: TVDeviceID?, toDisplay uuid: DisplayUUID) {
        store.update(uuid) { $0.tvDevice = id }
    }

    func boundDevice(forDisplay uuid: DisplayUUID) -> TVDevice? {
        guard let id = store.state(for: uuid).tvDevice else { return nil }
        return device(id: id)
    }

    /// Whether the brightness ladder may claim `.tvNetwork` for this display.
    ///
    /// `nil` for the overwhelmingly common case of a display with no TV bound to
    /// it, which is what keeps `BrightnessRung.resolve` on exactly the branches it
    /// always took — the ladder gains a rung, not a behaviour change.
    func backlightReachable(forDisplay uuid: DisplayUUID) -> Bool? {
        guard let device = boundDevice(forDisplay: uuid) else { return nil }
        guard TVFeatureRegistry.support(.brightness, on: device.platform).canWrite else { return false }
        guard device.isPaired else { return false }
        // Optimistic until something fails: a TV Crisp has not talked to yet is
        // not a TV that failed, and demanding a successful probe first would mean
        // reporting gamma until the user moved a control.
        return states[device.id]?.isReachable ?? true
    }

    // MARK: - Pairing

    /// Pairs with a TV at `host`, adding it to the list on success.
    ///
    /// On webOS this puts an accept prompt on the television and waits for a
    /// human; on Tizen the same, with the token arriving on the connect event.
    /// Both store their credential in the Keychain, never in the document.
    func pair(host: String, platform: TVPlatform, name: String?) async -> TVConversation.PairingResult {
        let result = await TVConversation.pair(
            host: host, platform: platform, name: name, credentials: credentials
        )
        if case .paired(let device) = result {
            upsert(device)
            tvServiceLog.info("paired a \(platform.rawValue, privacy: .public) TV")
        }
        return result
    }

    // MARK: - Performing an approved action

    /// What an action did, in the same three shapes `AutomationService.Outcome`
    /// uses so a TV action and a DDC write report alike.
    enum Outcome: Equatable, Sendable {
        case applied(String)
        case refused(reason: String)

        var didApply: Bool {
            if case .applied = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .applied(let what): return what
            case .refused(let reason): return reason
            }
        }
    }

    /// Performs an action that has already passed `TVWriteGate`.
    ///
    /// The feature and the value come off the token, never off anything the
    /// caller is holding — the same rule as `DDCFeatureDiscovery.ApprovedWrite`,
    /// and the reason `TVWriteGate.ApprovedTVAction`'s initialiser is
    /// `fileprivate`. A caller that skipped the gate has nothing to pass here.
    @discardableResult
    func perform(_ action: TVWriteGate.ApprovedTVAction) async -> Outcome {
        guard let device = device(id: action.device) else {
            return .refused(reason: "no paired TV has the identifier \(action.device.rawValue)")
        }
        let result = await TVConversation.apply(
            feature: action.feature, value: action.value, to: device,
            credentials: credentials, rateLimiter: pacer(for: device.id)
        )
        markReachable(device.id, result.didSucceed)
        switch result {
        case .success(let message): return .applied(message)
        case .failure(let message): return .refused(reason: message)
        }
    }

    // MARK: - Backlight coalescing

    /// Queues a backlight percent for whichever TV is bound to this display.
    ///
    /// Called from `BrightnessService`'s write path at slider and animation
    /// rates. Only the latest value per device is kept and one write is in flight
    /// at a time, so a two-second drag becomes a handful of network round trips
    /// rather than two hundred.
    ///
    /// It does not gate, and that is correct rather than an omission: a backlight
    /// write is non-destructive in `TVFeatureRegistry`, so it goes through
    /// `TVWriteGate.approve` with `.automatic` and is allowed — exactly the
    /// standing the DDC contrast slider has.
    func setBacklight(_ percent: Double, forDisplay uuid: DisplayUUID) {
        guard let device = boundDevice(forDisplay: uuid) else { return }
        pendingBacklight[device.id] = percent
        pumpBacklight(device.id)
    }

    private func pumpBacklight(_ id: TVDeviceID) {
        guard !backlightInFlight.contains(id), let percent = pendingBacklight.removeValue(forKey: id),
              let device = device(id: id) else { return }
        let write = TVWrite(
            device: id, platform: device.platform, feature: .brightness, value: .percent(percent)
        )
        guard case .approved(let approved) = TVWriteGate.approve(write, authorization: .automatic) else { return }
        backlightInFlight.insert(id)
        Task { @MainActor in
            _ = await perform(approved)
            backlightInFlight.remove(id)
            pumpBacklight(id)
        }
    }

    // MARK: - State

    private func markReachable(_ id: TVDeviceID, _ reachable: Bool) {
        var state = states[id] ?? TVConversation.Readback()
        state.isReachable = reachable
        states[id] = state
    }

    /// Reads what a TV will tell us. Called when the user opens the TV section or
    /// presses Refresh — never on a timer.
    @discardableResult
    func refresh(_ id: TVDeviceID) async -> Outcome {
        guard let device = device(id: id) else {
            return .refused(reason: "no paired TV has the identifier \(id.rawValue)")
        }
        let (readback, result) = await TVConversation.refresh(device, credentials: credentials)
        states[id] = readback
        switch result {
        case .success(let message): return .applied(message)
        case .failure(let message): return .refused(reason: message)
        }
    }
}
