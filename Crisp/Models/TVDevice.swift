import Foundation

// A smart TV as a device Crisp can control, and — the load-bearing half — what
// each platform's LAN protocol can honestly do to one.
//
// **Why a TV is here at all.** A television has no DDC/CI. Plug one into a Mac
// and every control in this app goes away: the I²C channel does not exist, so
// the brightness ladder falls to the GPU's colour table and contrast, volume and
// input have nothing to write to. Both LG (webOS) and Samsung (Tizen) publish a
// LAN control protocol instead, and both are plain networking — a WebSocket and
// some JSON. That is the one capability gap in this app that can be closed
// without going anywhere near the private WindowServer frameworks that AGENTS.md
// §2 exists because of, which is the whole argument for doing it.
//
// **HDMI-CEC is deliberately absent, and is not a "later phase".** macOS
// publishes no CEC API; the only working path is Apple's private, undocumented
// one, which §3.1 forbids. The DPCD tunnelling registers a DisplayPort→HDMI
// adapter would need are not reachable from user space. And decisively: the CEC
// command set contains no brightness command at all, so even a successful
// implementation would not answer the question this file exists for. There is no
// stub for it below on purpose — an empty case labelled `cec` is an invitation.
//
// **What this file is not.** It holds no sockets, no JSON framing and no
// credentials. `TVTransport` is the wire seam, `WebOSSSAP` / `TizenRemote` are
// the pure protocol engines above it, and the client key and token live in the
// Keychain (`TVCredentialStore`). This is the table those all consult: which
// features exist, which platform can reach each one, and what getting one wrong
// costs — the same shape and the same reasoning as `DDCFeatureRegistry`, because
// the hazard is the same hazard. A TV switched to a port with nothing on it is a
// black screen the Mac cannot undo, exactly like VCP 0x60.
//
// Pure Foundation: it compiles into the headless `CrispTests` target and into
// `crispctl` (AGENTS.md §3.6), so "Tizen cannot do brightness" is a test rather
// than a comment.

// MARK: - Platform

/// Which LAN control protocol a TV speaks.
///
/// Two cases, and adding a third is a real piece of work rather than an enum
/// case: each one is a distinct pairing state machine, a distinct message
/// envelope and a distinct set of things it cannot do.
enum TVPlatform: String, Codable, Sendable, CaseIterable {
    /// LG webOS. SSAP over a WebSocket on port 3000 (plaintext, older firmware)
    /// or 3001 (TLS, webOS 5+). Pairs by showing an accept prompt on screen and
    /// handing back a client key.
    case webOS
    /// Samsung Tizen. A WebSocket on 8001 (plain) or 8002 (TLS + token),
    /// carrying remote-control key presses rather than named commands.
    case tizen

    /// The name shown in the UI. Not `rawValue`: that is a persistence key and
    /// must not move when someone improves the wording.
    var title: String {
        switch self {
        case .webOS: return String(localized: "LG (webOS)")
        case .tizen: return String(localized: "Samsung (Tizen)")
        }
    }
}

// MARK: - Identity

/// A TV's stable identity — the same rule as `DisplayUUID`, for the same reason.
///
/// **Never the IP address.** A TV is on DHCP; the address it has today is the
/// address something else has next week, and a device record keyed on it would
/// silently start sending power-off commands to a neighbour's television. webOS
/// TVs publish a UUID in their SSDP response and Tizen returns one from
/// `GET /api/v2/` as `id` (`uuid:…`); both survive a reboot and a re-cable, and
/// both are what this type wraps. The IP lives in `TVDevice.host` as a *cache*
/// that discovery is allowed to correct.
///
/// There is deliberately no initialiser taking a host or an integer, so passing
/// the wrong identity is a compile error rather than a support ticket.
struct TVDeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    // A bare string in JSON, like `DisplayUUID`: `displays.json` is meant to be
    // readable in a bug report.
    init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - The device record

/// One TV the user has added, as it is persisted.
///
/// Everything here is public information the user can read in a bug report. The
/// two secrets — the webOS client key and the Tizen token — are **not** fields
/// on this struct and never touch `displays.json`; they live in the Keychain
/// keyed by `id` (`TVCredentialStore`), and so does the TOFU certificate
/// fingerprint. That separation is structural rather than a convention: there is
/// no property here to put a credential in by accident.
struct TVDevice: Codable, Equatable, Sendable, Identifiable {
    /// The TV's own UUID. See `TVDeviceID` for why this is not the address.
    var id: TVDeviceID
    var platform: TVPlatform
    /// What the user calls it. Seeded from the TV's model name at pairing time
    /// and editable afterwards, because "OLED55CX6LA" is not a room.
    var name: String
    /// Last known address. A cache, not identity: discovery and a failed connect
    /// both update it, and two devices may legitimately hold the same host over
    /// the lifetime of a lease.
    var host: String
    /// The model string the TV reported, kept verbatim for bug reports.
    var model: String?
    /// When pairing last succeeded. `nil` means "added but never paired", which
    /// is a real state: the user can type an address before the TV is on.
    var pairedAt: Date?
    /// Fields a newer build wrote and this one does not model, parked verbatim.
    /// Same mechanism and same argument as `DisplayState`'s bag.
    var unknown: [String: JSONValue]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, platform, name, host, model, pairedAt
    }

    private static let knownFields = Set(CodingKeys.allCases.map(\.rawValue))

    init(
        id: TVDeviceID,
        platform: TVPlatform,
        name: String,
        host: String,
        model: String? = nil,
        pairedAt: Date? = nil,
        unknown: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.host = host
        self.model = model
        self.pairedAt = pairedAt
        self.unknown = unknown
    }

    /// `id`, `platform` and `host` are the three fields a device cannot be
    /// without, so those throw — and `LossyList` turns a throw into "this one
    /// entry is dropped", never "the document is corrupt". A platform a newer
    /// build invented is exactly that case: this build cannot speak it, so
    /// keeping the row would put an unusable device in the list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(TVDeviceID.self, forKey: .id)
        self.platform = try container.decode(TVPlatform.self, forKey: .platform)
        self.host = try container.decode(String.self, forKey: .host)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.pairedAt = try container.decodeIfPresent(Date.self, forKey: .pairedAt)
        self.unknown = ForwardCompatibleFields.decode(from: decoder, known: Self.knownFields)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(pairedAt, forKey: .pairedAt)
        try ForwardCompatibleFields.encode(unknown, to: encoder, known: Self.knownFields)
    }

    /// A device with an empty name is one the user can neither recognise nor
    /// address in a `crisp://` link, so the model — and failing that, the
    /// platform — stands in. Repaired on load rather than guarded at every read.
    func normalized() -> TVDevice {
        var copy = self
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmed.isEmpty ? (model ?? platform.title) : trimmed
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    /// Whether a credential is expected to exist for this device. Pairing state
    /// is *reported* by this flag and *proved* by the Keychain: a device the user
    /// deleted the credential for re-pairs, which is the same path a stale key
    /// takes anyway.
    var isPaired: Bool { pairedAt != nil }
}

// MARK: - Features

/// What a TV can be asked to do. Deliberately smaller than the remote's key map:
/// every case below is something Crisp can *report the state of* or *undo*,
/// which is the bar a control in a menu-bar panel has to clear.
enum TVFeatureID: String, Codable, Sendable, CaseIterable {
    /// The panel's own backlight, 0–100. Reachable on webOS, not on Tizen — see
    /// `TVFeatureRegistry.support(_:on:)`.
    case brightness
    /// Speaker volume, 0–100.
    case volume
    /// Mute on/off.
    case mute
    /// Standby. Destructive: the socket can turn a TV *off* and cannot turn it
    /// back on (that needs Wake-on-LAN, which is a different protocol on a
    /// different layer and is not pretended at here).
    case power
    /// The TV's input. Destructive for the same reason VCP 0x60 is.
    case input
}

/// Everything the app needs to know about one TV feature before it touches it.
///
/// The same fields as `DDCFeatureSpec` minus the VCP-specific ones, and for the
/// same reason: `destructive` and `hazard` are what the gate and the dialog read,
/// so they are data in one table rather than a condition written out at each of
/// the four call sites that would otherwise have to agree.
struct TVFeatureSpec: Equatable, Sendable {

    /// The shape of the value, which decides how a UI renders it and how a write
    /// is clamped. A code is not a percentage: `HDMI_2` scaled to 40% is not a
    /// port, so the two are separate cases and a mismatch is refused rather than
    /// coerced (`TVActionRequest.plan`).
    enum Kind: Equatable, Sendable {
        /// A 0–100 dial.
        case percent
        /// On or off.
        case flag
        /// One of a set of opaque identifiers the TV itself names (`HDMI_1`).
        case code
    }

    let id: TVFeatureID
    let title: String
    let kind: Kind
    /// Writing this can leave the user unable to undo it from the Mac.
    let destructive: Bool
    /// What specifically goes wrong, in the words a confirmation dialog needs.
    /// Non-nil exactly when `destructive` is true (pinned by a test).
    let hazard: String?
}

/// The value a TV feature carries, in the shape `TVFeatureSpec.Kind` says it has.
///
/// Three cases rather than one number, and a mismatch is refused rather than
/// coerced (`TVActionRequest.plan`) — the same argument as `AutomationValue`'s:
/// `HDMI_2` is a port, not 40% of anything, and scaling it would aim the write at
/// whichever port that percentage landed on.
///
/// It lives here rather than with the plan because it is part of the feature
/// table's vocabulary, and because `crispctl` needs it without linking the app's
/// write gate (see `project.yml` for why the CLI deliberately does not).
enum TVActionValue: Equatable, Sendable {
    case percent(Double)
    case flag(Bool)
    /// An opaque identifier the TV itself names: `HDMI_1` on webOS, `KEY_HDMI2`
    /// on Tizen. Never interpreted, only carried.
    case code(String)

    var percentValue: Double? {
        guard case .percent(let value) = self else { return nil }
        return value
    }

    var flagValue: Bool? {
        guard case .flag(let value) = self else { return nil }
        return value
    }

    var codeValue: String? {
        guard case .code(let value) = self else { return nil }
        return value
    }
}

/// Why a platform cannot do something, in prose the user reads.
///
/// Cases rather than free strings, for the same reason `BrightnessRung.Reason`
/// is: the resolution rules stay comparable in tests, and the sentence the user
/// sees is derived rather than repeated.
enum TVUnsupportedReason: String, Equatable, Sendable {
    /// Samsung's Tizen TVs. The Tizen brightness API is for apps running *on*
    /// the TV; the UPnP brightness variables only ever existed on pre-2016
    /// models. There is no remote brightness command, and the OSD-key-navigation
    /// trick some tools use is not one — it presses arrow keys at a menu it
    /// cannot see.
    case tizenHasNoRemoteBrightness
    /// Samsung does not answer "which input am I on?" to anything on the local
    /// network; the only source is Samsung's cloud. Reported as unknown rather
    /// than guessed.
    case tizenInputIsNotReadable

    var text: String {
        switch self {
        // The `\` continuations only wrap the source line: each literal joins
        // back to exactly one sentence, which is the key in the String Catalog.
        case .tizenHasNoRemoteBrightness:
            return String(localized: """
                Samsung's Tizen TVs expose no brightness command on the network — the picture \
                settings only exist on the TV's own menu. Volume, power and input still work.
                """)
        case .tizenInputIsNotReadable:
            return String(localized: """
                Samsung TVs do not report which input they are on to anything on the local \
                network, so Crisp shows the input as unknown rather than guessing.
                """)
        }
    }
}

/// Whether a platform can reach a feature, and why not when it cannot.
enum TVFeatureSupport: Equatable, Sendable {
    /// Crisp can write it and read the current value back.
    case readWrite
    /// Crisp can write it but cannot read the current value. `unreadable` says
    /// why when there is something to say — Samsung's input is the case that
    /// matters, because a control that shows the wrong port is worse than one
    /// that admits it does not know.
    case writeOnly(unreadable: TVUnsupportedReason?)
    /// Not reachable at all. The reason is shown next to the disabled control
    /// rather than left as a control that quietly does nothing.
    case unsupported(reason: TVUnsupportedReason)

    var canWrite: Bool {
        switch self {
        case .readWrite, .writeOnly: return true
        case .unsupported: return false
        }
    }

    var canRead: Bool { self == .readWrite }

    /// The sentence to put next to the control, when there is one — for a
    /// feature that cannot be reached at all *and* for one that can be written
    /// but never read back.
    var caveat: TVUnsupportedReason? {
        switch self {
        case .readWrite: return nil
        case .writeOnly(let unreadable): return unreadable
        case .unsupported(let reason): return reason
        }
    }

    var unsupportedReason: TVUnsupportedReason? {
        guard case .unsupported(let reason) = self else { return nil }
        return reason
    }
}

/// The table. Adding a TV feature is an entry here plus a case in the two
/// protocol engines — never a new gate, a new dialog or a new consent type.
enum TVFeatureRegistry {

    static let all: [TVFeatureSpec] = [
        TVFeatureSpec(
            id: .brightness, title: "Brightness", kind: .percent,
            destructive: false, hazard: nil
        ),
        TVFeatureSpec(
            id: .volume, title: "Volume", kind: .percent,
            destructive: false, hazard: nil
        ),
        TVFeatureSpec(
            id: .mute, title: "Mute", kind: .flag,
            destructive: false, hazard: nil
        ),
        TVFeatureSpec(
            id: .power, title: "Power", kind: .flag,
            destructive: true,
            // The asymmetry is the hazard, and it is stated rather than softened:
            // the socket goes down with the TV, so nothing on this protocol can
            // bring it back. Wake-on-LAN is a different mechanism on a different
            // layer and Crisp does not claim it.
            hazard: "Turns the TV off. The control socket goes down with it, so Crisp cannot "
                + "turn it back on — only the TV's own remote or power button can."
        ),
        TVFeatureSpec(
            id: .input, title: "Input", kind: .code,
            destructive: true,
            hazard: "Switches the TV to another input. If nothing is attached to it the screen "
                + "goes blank, and on Samsung TVs Crisp cannot even read which input it landed on."
        )
    ]

    private static let byID: [TVFeatureID: TVFeatureSpec] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// The entry for a feature, always.
    ///
    /// A missing entry cannot happen (`TVDeviceTests` pins that `all` covers
    /// every case), but "cannot happen" is not a reason to hand back something
    /// writable. The fallback is the safety default made concrete: destructive,
    /// so every gate treats it as the unknown quantity it is.
    static func spec(for id: TVFeatureID) -> TVFeatureSpec {
        byID[id] ?? TVFeatureSpec(
            id: id, title: id.rawValue, kind: .code, destructive: true,
            hazard: "This feature has no registry entry, so nothing is known about what it does."
        )
    }

    /// What a platform can do with a feature.
    ///
    /// This is the whole "Tizen cannot do brightness" fact, in one place, as a
    /// value the UI renders and the gate refuses on. It is stated per platform
    /// rather than per device because it is a property of the protocol, not of
    /// the individual television: no Tizen firmware exposes it, so a per-device
    /// probe would be twenty seconds of network for an answer that is already
    /// known.
    static func support(_ feature: TVFeatureID, on platform: TVPlatform) -> TVFeatureSupport {
        switch (platform, feature) {
        case (.webOS, .brightness):
            // `ssap://settings/getSystemSettings` reads `backlight` back, so this
            // one really is read/write — unlike the *write*, which goes through
            // createAlert and returns nothing. The read is what makes the slider
            // start in the right place.
            return .readWrite
        case (.webOS, .volume), (.webOS, .mute), (.webOS, .power), (.webOS, .input):
            return .readWrite

        case (.tizen, .brightness):
            return .unsupported(reason: .tizenHasNoRemoteBrightness)
        case (.tizen, .volume):
            // Absolute volume is UPnP `RenderingControl`, which does answer a
            // `GetVolume`. The remote-key path (`KEY_VOLUP`) is fire-and-forget,
            // and the service prefers UPnP for exactly this reason.
            return .readWrite
        case (.tizen, .power):
            // Writing is a `KEY_POWER` press the TV acknowledges nothing about,
            // but `GET /api/v2/` reports `PowerState`, so the state is readable
            // even though the write is not acknowledged.
            return .readWrite
        case (.tizen, .mute):
            // A remote key with no read-back anywhere. Nothing to explain beyond
            // that, so no caveat: the control is a button, not a state.
            return .writeOnly(unreadable: nil)
        case (.tizen, .input):
            // Writable (`KEY_HDMI1`…`KEY_HDMI4`, with `KEY_SOURCE` cycling as the
            // portable fallback) and genuinely unreadable: the only source for
            // "which input am I on" is Samsung's cloud.
            return .writeOnly(unreadable: .tizenInputIsNotReadable)
        }
    }

    /// The features worth offering for a platform, in panel order. A feature
    /// nothing can write is still listed — with its reason — because a control
    /// that is absent looks like a bug and a control that is disabled with a
    /// sentence next to it is an answer.
    static let ordered: [TVFeatureID] = [.brightness, .volume, .mute, .input, .power]
}

extension TVFeatureID {
    /// This feature's registry entry. Never nil — see `TVFeatureRegistry.spec(for:)`.
    var spec: TVFeatureSpec { TVFeatureRegistry.spec(for: self) }
}
