import Foundation

// The DDC feature registry: which VCP codes this app knows about, what shape
// each one's values are, and what getting it wrong costs — as data, in one place.
//
// Why this exists. Brightness, contrast, volume and input source were each
// hand-coded end to end: a VCP constant in one file, a bespoke read path, a
// bespoke write path, bespoke persistence, a bespoke view. BetterDisplay exposes
// roughly 170 VCP codes. Ten more done that way is ten times that code and ten
// more chances to get a clamp wrong, so adding a VCP is meant to be a *data*
// change: one entry in `DDCFeatureRegistry.all`.
//
// Safety is the default here, not a later refinement. ddcutil issue #153
// documents a monitor whose on-screen menu and physical buttons were
// **permanently** disabled by DDC commands — the panel kept working, its own
// controls never did again. That is the reason every entry declares whether
// writing it is destructive, why `access` exists at all, and why
// `DDCFeatureDiscovery` keeps anything unproven read-only until a quirks entry
// or a live probe says otherwise.
//
// Pure Foundation. No `Bundle`, no IOKit, no AppKit: it compiles into the
// headless `CrispTests` target (AGENTS.md §3.6) and into `crispctl`, so the
// table is asserted in tests rather than trusted in three places.

// MARK: - MCCS version

/// A VESA MCCS version, as the standard writes it (`2.2`, `3.0`).
///
/// Two jobs, deliberately the same type for both: it stamps each registry entry
/// with the version that defined the code, and it is what a monitor's own
/// `mccs_ver()` capability field decodes to. Comparable so the parser can reject
/// a version no standard ever published without a second table.
struct MCCSVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: UInt8
    let minor: UInt8

    init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    static func < (lhs: MCCSVersion, rhs: MCCSVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    var description: String { "\(major).\(minor)" }

    static let v20 = MCCSVersion(major: 2, minor: 0)
    static let v21 = MCCSVersion(major: 2, minor: 1)
    static let v22 = MCCSVersion(major: 2, minor: 2)
    static let v30 = MCCSVersion(major: 3, minor: 0)

    /// The newest version VESA has published. A monitor claiming more than this
    /// is not from the future, it is a monitor whose capabilities string is wrong
    /// — several report `mccs_ver(255.255)` or plain garbage — so the parser
    /// drops the field rather than believing it.
    static let newestPublished = MCCSVersion(major: 3, minor: 2)

    /// Lenient parse of an `mccs_ver()` payload.
    ///
    /// Tolerates surrounding whitespace and a trailing letter (`2.2a` is how VESA
    /// itself names the current revision), and a bare major (`2` → `2.0`).
    /// Returns nil for anything else, including a version past
    /// `newestPublished`: the field is a claim, never truth (feature 0xDF
    /// routinely contradicts it), so an unusable one is simply absent.
    static func parse(_ text: String) -> MCCSVersion? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let major = UInt8(parts[0]) else { return nil }
        let minor: UInt8 = parts.count == 2 ? (UInt8(parts[1]) ?? 0) : 0
        let version = MCCSVersion(major: major, minor: minor)
        guard version <= newestPublished else { return nil }
        return version
    }
}

// MARK: - Feature identity

/// A DDC feature by name. The name *is* the VCP code (MCCS fixes them), which is
/// why the quirks schema still has no per-feature `vcp` override: a JSON file
/// that strangers contribute must not be able to aim a write at an arbitrary
/// register on the monitor's I2C bus. The registry below is the only place a
/// name becomes a number.
///
/// The first four raw values are load-bearing on disk — they are the keys in
/// every shipped and contributed `Crisp/Resources/quirks/*.json` — so they keep
/// their original spelling (`input`, not `inputSource`).
enum DDCFeatureID: String, Codable, Sendable, CaseIterable {
    case brightness
    case contrast
    case volume
    case input
    case colorTemperature
    case colorPreset
    case videoGainRed
    case videoGainGreen
    case videoGainBlue
    case blackLevelRed
    case blackLevelGreen
    case blackLevelBlue
    case sharpness
    case audioMute
    case osdControl
    case powerMode
    case vcpVersion
    case restoreFactoryDefaults
    case displayTechnologyType

    /// This feature's registry entry. Never nil — see
    /// `DDCFeatureRegistry.spec(for:)` for what happens if the table ever gains a
    /// hole, and `DDCFeatureRegistryTests` for the test that stops it.
    var spec: DDCFeatureSpec { DDCFeatureRegistry.spec(for: self) }
}

// MARK: - One feature

/// Everything the app needs to know about one VCP code before it touches it.
struct DDCFeatureSpec: Equatable, Sendable {

    /// The shape of the feature's value, which is what decides how a UI renders
    /// it and how a write is clamped.
    enum Kind: Equatable, Sendable {
        /// A dial. `defaultMax` is the raw maximum to assume when neither the
        /// monitor's own reply nor the quirks database says anything better —
        /// MCCS's own 0–100 for every continuous control seeded here.
        ///
        /// It is a bare maximum rather than a `QuirkRange` on purpose: the range
        /// type belongs to the quirks database (whose whole job is that `min` is
        /// not always 0), and the registry must stay free of that dependency so
        /// `crispctl` can link it without the database.
        case continuous(defaultMax: UInt16)
        /// A set of discrete codes. `values` is what MCCS defines; a real monitor
        /// may answer with something else entirely — the BenQ MA320U reports
        /// input source `19`, which is not a meaningful VESA code — so this list
        /// is a starting point for a menu, never a validation rule.
        case nonContinuous(values: [UInt16])
        /// A block of bytes (LUT-shaped features such as 0x73). Nothing is seeded
        /// with it yet; it exists so the capabilities parser can report a
        /// table-type VCP the monitor advertises without the registry lying about
        /// its shape.
        case table

        var isContinuous: Bool {
            if case .continuous = self { return true }
            return false
        }
    }

    /// What MCCS says the host may do with the code.
    enum Access: String, Equatable, Sendable {
        case readOnly
        case readWrite
        /// A code with no meaningful read-back: 0x04 (restore factory defaults)
        /// and the "turn the panel off" value of 0xD6.
        case writeOnly

        var canRead: Bool { self != .writeOnly }
        var canWrite: Bool { self != .readOnly }
    }

    let id: DDCFeatureID
    let vcp: UInt8
    /// Title case, for the diagnostics report and any future UI.
    let title: String
    let kind: Kind
    let access: Access
    /// Writing this can leave the user unable to undo it from the Mac. Every one
    /// of these routes through the same confirmation gate input switching uses
    /// (`InputSourceMenuRow`), never a second one.
    let destructive: Bool
    /// What specifically goes wrong, in the words the confirmation dialog needs.
    /// Non-nil exactly when `destructive` is true (pinned by a test).
    let hazard: String?
    /// The MCCS version that defined the code. Reported, never enforced: a
    /// monitor's `mccs_ver()` and its feature 0xDF contradict each other freely,
    /// so this is documentation of where the code comes from, not a gate.
    let mccs: MCCSVersion

    /// `0x12`, the way MCCS and the monitor's own manual both spell it.
    var vcpText: String { String(format: "0x%02X", vcp) }

    /// 0x00 is reserved by MCCS and is what the registry's fallback entry uses,
    /// so "has a real code" and "is a known feature" are the same question.
    var isKnown: Bool { vcp != 0x00 }
}

// MARK: - The registry

/// Every VCP code Crisp knows about. Adding one is an entry in `all`.
enum DDCFeatureRegistry {

    /// MCCS's own default for a percent-shaped control.
    static let standardContinuousMax: UInt16 = 100

    /// The table. Ordered the way MCCS orders the codes, so a reader can diff it
    /// against the standard by eye.
    static let all: [DDCFeatureSpec] = [
        DDCFeatureSpec(
            id: .restoreFactoryDefaults, vcp: 0x04, title: "Restore factory defaults",
            kind: .nonContinuous(values: [0x01]), access: .writeOnly, destructive: true,
            hazard: "Restores every setting on the monitor to its factory state, including "
                + "settings Crisp never touched. There is no undo and no read-back.",
            mccs: .v20
        ),
        DDCFeatureSpec(
            id: .colorTemperature, vcp: 0x0C, title: "Colour temperature",
            // MCCS 2.2 calls 0x0C "Color Temperature Request" and 0x14 "Select
            // Color Preset"; both are what people mean by "colour preset", and
            // both can leave a picture the user cannot read well enough to find
            // the monitor's own menu. Seeded as two entries rather than picking
            // one, because the two codes really are two different registers.
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: true,
            hazard: "Shifts the whole picture's colour temperature. A monitor that lands on an "
                + "extreme value can be hard to read well enough to reach its own menu.",
            mccs: .v20
        ),
        DDCFeatureSpec(
            id: .brightness, vcp: 0x10, title: "Brightness",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .contrast, vcp: 0x12, title: "Contrast",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .colorPreset, vcp: 0x14, title: "Colour preset",
            // 01 sRGB, 02 native, 03 4000K, 04 5000K, 05 6500K, 06 7500K,
            // 07 8200K, 08 9300K, 09 10000K, 0A 11500K, 0B user 1 …
            kind: .nonContinuous(values: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B]),
            access: .readWrite, destructive: true,
            hazard: "Switches the monitor's colour preset wholesale. Presets a panel advertises "
                + "but does not really implement can leave an unreadable picture.",
            mccs: .v20
        ),
        DDCFeatureSpec(
            id: .videoGainRed, vcp: 0x16, title: "Video gain (red)",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .videoGainGreen, vcp: 0x18, title: "Video gain (green)",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .videoGainBlue, vcp: 0x1A, title: "Video gain (blue)",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .input, vcp: 0x60, title: "Input source",
            // Deliberately empty rather than the MCCS 0x60 table. The codes a
            // user may actually be offered come from `MCCSInputTable` by way of
            // `MonitorQuirkResolver.inputOptions`, which weighs them against the
            // quirks database and against what the monitor is on right now.
            // Copying the list here would be a second source of truth for the one
            // feature where being wrong costs the user their screen.
            kind: .nonContinuous(values: []),
            access: .readWrite, destructive: true,
            hazard: "Switches the panel to another port. If nothing is attached to it the screen "
                + "goes blank and the Mac cannot switch back — only the monitor's own buttons can.",
            mccs: .v20
        ),
        DDCFeatureSpec(
            id: .volume, vcp: 0x62, title: "Volume",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .blackLevelRed, vcp: 0x6C, title: "Black level (red)",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .blackLevelGreen, vcp: 0x6E, title: "Black level (green)",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .blackLevelBlue, vcp: 0x70, title: "Black level (blue)",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .sharpness, vcp: 0x87, title: "Sharpness",
            kind: .continuous(defaultMax: standardContinuousMax), access: .readWrite, destructive: false,
            hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .audioMute, vcp: 0x8D, title: "Audio mute / screen blank",
            // 01 mute, 02 unmute; MCCS 2.2 adds 03 blank the screen, 04 unblank.
            kind: .nonContinuous(values: [0x01, 0x02, 0x03, 0x04]),
            access: .readWrite, destructive: true,
            hazard: "Values 3 and 4 on this register blank and unblank the panel. A monitor that "
                + "accepts the blank and not the unblank leaves a screen that looks dead.",
            mccs: .v20
        ),
        DDCFeatureSpec(
            id: .displayTechnologyType, vcp: 0xB6, title: "Display technology type",
            // 01 CRT, 02 LCD, 03 plasma, 04 LCOS, 05 OLED …; read-only by MCCS.
            kind: .nonContinuous(values: [0x01, 0x02, 0x03, 0x04, 0x05]),
            access: .readOnly, destructive: false, hazard: nil, mccs: .v20
        ),
        DDCFeatureSpec(
            id: .osdControl, vcp: 0xCA, title: "OSD / button lock",
            // 01 OSD disabled, 02 OSD enabled; MCCS 2.2 adds the button-lock bits.
            kind: .nonContinuous(values: [0x01, 0x02]),
            access: .readWrite, destructive: true,
            // This is the one that motivated the read-only default for the whole
            // registry, so it says exactly what happened rather than "be careful".
            hazard: "Can disable the monitor's own menu and physical buttons. ddcutil issue #153 "
                + "documents a monitor whose OSD and buttons were disabled permanently by this "
                + "register — the panel kept working, its controls never did again.",
            mccs: .v20
        ),
        DDCFeatureSpec(
            id: .powerMode, vcp: 0xD6, title: "Power mode",
            // 01 on, 02 standby, 03 suspend, 04 off (low power), 05 off (hard).
            kind: .nonContinuous(values: [0x01, 0x02, 0x03, 0x04, 0x05]),
            access: .readWrite, destructive: true,
            hazard: "Value 5 turns the panel off at the power stage. Many monitors cannot be woken "
                + "from it over DDC at all, because the DDC controller goes down with the panel.",
            mccs: .v20
        ),
        DDCFeatureSpec(
            id: .vcpVersion, vcp: 0xDF, title: "VCP version",
            kind: .nonContinuous(values: []), access: .readOnly, destructive: false,
            hazard: nil, mccs: .v20
        )
    ]

    private static let byID: [DDCFeatureID: DDCFeatureSpec] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    private static let byVCP: [UInt8: DDCFeatureSpec] =
        Dictionary(all.map { ($0.vcp, $0) }, uniquingKeysWith: { first, _ in first })

    /// The entry for a feature, always.
    ///
    /// A missing entry cannot happen — `DDCFeatureRegistryTests` pins that `all`
    /// covers every `DDCFeatureID` — but "cannot happen" is not a reason to
    /// crash or to hand back something writable. The fallback is the registry's
    /// safety default made concrete: VCP 0x00 (reserved by MCCS, so no write can
    /// ever be aimed at it), read-only, and destructive so that every gate in the
    /// app treats it as the unknown quantity it is.
    static func spec(for id: DDCFeatureID) -> DDCFeatureSpec {
        byID[id] ?? DDCFeatureSpec(
            id: id, vcp: 0x00, title: id.rawValue,
            kind: .table, access: .readOnly, destructive: true,
            hazard: "This feature has no registry entry, so nothing is known about what writing it does.",
            mccs: .v20
        )
    }

    /// The feature a VCP code belongs to, or nil for a code nothing here claims —
    /// which is the normal case: a monitor's capabilities string advertises codes
    /// this app has no opinion about, and the honest answer is "unknown", not a
    /// guessed feature.
    static func feature(forVCP vcp: UInt8) -> DDCFeatureSpec? { byVCP[vcp] }

    /// The features Crisp already drives end to end, in the order the UI and the
    /// diagnostics report show them. Everything else in `all` is data the app can
    /// read and report on but does not yet own a control for.
    static let established: [DDCFeatureID] = [.brightness, .contrast, .volume, .input]
}
