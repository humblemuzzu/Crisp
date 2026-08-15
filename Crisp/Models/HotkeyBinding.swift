import Foundation

// User-assignable global keyboard shortcuts, as data: which combinations exist,
// which are legal, and what happens when two actions want the same one.
//
// Why this is a separate mechanism from the F1/F2 keys, and why that matters
// here specifically. `BrightnessKeyService` intercepts the hardware brightness
// keys with a `CGEventTap`, which macOS only allows to a process the user has
// granted **Accessibility**. That grant is keyed to the app's code signature, so
// a rebuild, an upgrade or a replaced bundle can leave the System Settings
// toggle switched on over a TCC record that no longer matches — the keys then do
// nothing, with no error anywhere (see `BrightnessKeyService.KeyInterceptionState
// .grantedButRefused`, which exists because that silent failure cost real time).
//
// The shortcuts described here are registered with Carbon's `RegisterEventHotKey`
// instead, which **needs no Accessibility grant at all** — the OS delivers the
// key to the app rather than the app watching the whole event stream. So they
// keep working in exactly the state that kills the media-key path. That is the
// point of having both: not two ways to do the same thing, but a control surface
// whose failure mode is independent of the one this app has already been bitten
// by. (The registration itself lives in `HotkeyService`; Carbon is a UI-layer
// dependency and `Crisp/Models` stays headless — AGENTS.md §3.6.)
//
// Everything a shortcut can get *wrong* is decided in this file: a combination
// with no real modifier would swallow a letter system-wide, and two actions on
// one combination would mean one of them silently never fires. Both are refused,
// and both are refused in a pure type so `HotkeyBindingTests` can prove it
// without registering anything with the OS.

// MARK: - Actions

/// What a shortcut does. Deliberately small: every case here is a change the
/// user can already make from the panel, so a shortcut is a faster way to do
/// something safe, never a way to reach something the UI guards.
///
/// Nothing destructive will ever be added to this list. A hotkey is one keypress
/// with no dialog in front of it, and `AutomationRequest.plan` refuses a
/// destructive feature from every automation origin anyway — a "switch input"
/// shortcut would be a key that cannot work rather than a key that must not.
enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case volumeMute
}

// MARK: - Modifiers

/// The modifier keys a shortcut may carry.
///
/// Its own bit values rather than Carbon's or AppKit's: this type is persisted,
/// and a persisted file must not be pinned to the numeric layout of a framework
/// header. `HotkeyService` translates to Carbon's `cmdKey`/`optionKey`/… at the
/// registration call, which is the one place that has to agree with Carbon.
struct HotkeyModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let command = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let control = HotkeyModifiers(rawValue: 1 << 2)
    static let shift = HotkeyModifiers(rawValue: 1 << 3)

    /// Every bit this type defines. Anything outside it in a decoded value is a
    /// file from a newer version or a hand edit, and is dropped rather than
    /// registered as a modifier nobody can name.
    static let known: HotkeyModifiers = [.command, .option, .control, .shift]

    /// Shift is missing on purpose. ⇧A is still the letter A to every text field
    /// in the system; a global hotkey on it would eat capital letters. Only a
    /// modifier that is not part of ordinary typing counts as one here.
    static let qualifying: HotkeyModifiers = [.command, .option, .control]

    /// Encoded as a bare integer rather than the synthesized `{"rawValue": …}`
    /// wrapper, so the persisted settings file stays readable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(UInt32.self)
        self.rawValue = raw & HotkeyModifiers.known.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The combination as macOS writes it, in Apple's canonical order
    /// (⌃⌥⇧⌘ — Control, Option, Shift, Command).
    var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

// MARK: - One binding

/// One key combination: a virtual key code plus its modifiers.
///
/// The key code, not the character. A `U` on a QWERTY layout and on Dvorak are
/// different characters at the same physical key, and `RegisterEventHotKey`
/// takes the key code — so storing the character would move the shortcut
/// whenever the user switched layout.
struct HotkeyBinding: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: HotkeyModifiers

    init(keyCode: UInt16, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Whether this is a combination the app is willing to register globally.
    ///
    /// A hotkey is taken from *every* app in the session, so an unqualified one
    /// is not a shortcut, it is a broken keyboard: bare `B` would stop the letter
    /// B reaching any text field until the user found this panel again.
    var isRegisterable: Bool { !modifiers.isDisjoint(with: .qualifying) }

    /// How the combination is written in the UI, e.g. `⌃⌥⌘F1`.
    var displayString: String { modifiers.symbols + HotkeyBinding.keyLabel(for: keyCode) }
}

// MARK: - Key labels

extension HotkeyBinding {

    /// The printable name of a virtual key code.
    ///
    /// A fixed table rather than a live layout query (`UCKeyTranslate`) because
    /// this type is headless and because the label is only ever cosmetic — the
    /// binding is the key *code*, so a wrong label misnames a shortcut that still
    /// works, while a layout dependency here would drag Carbon into
    /// `Crisp/Models`. Unknown codes are named, not hidden: "Key 42" is a worse
    /// label than "§" and a much better one than an empty box.
    static func keyLabel(for keyCode: UInt16) -> String {
        keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    /// ANSI virtual key codes, as `Carbon.HIToolbox`'s `kVK_*` constants define
    /// them. Frozen numbers — they have not moved since the Macintosh Toolbox —
    /// which is why repeating them here costs nothing and buys a pure type.
    private static let keyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋",
        // The keypad, which is where a "set brightness to 50" shortcut often ends
        // up on a full-size keyboard.
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Keypad Clear",
        75: "Keypad /", 76: "Keypad ↩", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘",
        120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

// MARK: - The set of bindings

/// Why a requested binding was not accepted. An `Error` so it can be a
/// `Result`'s failure — the assignment API hands back one refusal or the whole
/// new set, never a mutated set plus a complaint.
enum HotkeyRejection: Error, Equatable, Sendable {
    /// No ⌘, ⌥ or ⌃. See `HotkeyBinding.isRegisterable`.
    case needsModifier
    /// Another action already owns this combination. Refused rather than moved:
    /// silently taking it away from the other action is how a user ends up with a
    /// shortcut that stopped working and no way to see why.
    case alreadyAssigned(to: HotkeyAction)
}

/// Every assigned shortcut, and the rules for changing the set.
///
/// Value type with non-mutating operations on purpose: `HotkeyService` has to
/// register with the OS, which can fail, and a set that had already mutated
/// itself before the failure would leave the UI showing a shortcut the system
/// never accepted. Here the service computes the next set, registers it, and
/// only then adopts it.
struct HotkeyBindings: Equatable, Codable, Sendable {
    private var byAction: [HotkeyAction: HotkeyBinding]

    /// No shortcuts. The shipped default, deliberately: registering global keys
    /// nobody asked for is how two apps end up fighting over ⌥⌘↑, and there is no
    /// combination this app could claim that some user has not already given to
    /// something else.
    static let empty = HotkeyBindings(byAction: [:])

    private init(byAction: [HotkeyAction: HotkeyBinding]) {
        self.byAction = byAction
    }

    /// The binding for an action, or nil when it has none.
    subscript(action: HotkeyAction) -> HotkeyBinding? { byAction[action] }

    /// Every assigned pair, in a stable order (`HotkeyAction.allCases`) so the
    /// UI and the registration loop agree on it.
    var assignments: [(action: HotkeyAction, binding: HotkeyBinding)] {
        HotkeyAction.allCases.compactMap { action in
            byAction[action].map { (action, $0) }
        }
    }

    /// Which action owns a combination, if any. The lookup the conflict check and
    /// the OS event dispatch both need.
    func action(for binding: HotkeyBinding) -> HotkeyAction? {
        byAction.first { $0.value == binding }?.key
    }

    /// The set with `binding` assigned to `action`, or the reason it cannot be.
    ///
    /// Re-assigning an action the combination it already has succeeds and changes
    /// nothing: it is what a user does by re-recording the same keys, and
    /// reporting "already assigned" against itself would be nonsense.
    func assigning(_ binding: HotkeyBinding, to action: HotkeyAction) -> Result<HotkeyBindings, HotkeyRejection> {
        guard binding.isRegisterable else { return .failure(.needsModifier) }
        if let owner = self.action(for: binding), owner != action {
            return .failure(.alreadyAssigned(to: owner))
        }
        var next = byAction
        next[action] = binding
        return .success(HotkeyBindings(byAction: next))
    }

    /// The set with `action` unassigned. Clearing an action that has no shortcut
    /// is a no-op, not an error.
    func clearing(_ action: HotkeyAction) -> HotkeyBindings {
        var next = byAction
        next.removeValue(forKey: action)
        return HotkeyBindings(byAction: next)
    }

    // MARK: - Persistence

    /// Decoding is a filter, not a copy.
    ///
    /// The settings file is on disk in the user's home directory and is meant to
    /// be readable, which makes it hand-editable, which makes it another way in.
    /// Anything the assignment rules would have refused — a modifier-less
    /// combination, an unknown action name, the same combination on two actions —
    /// is dropped here rather than registered, so an edited file cannot install a
    /// shortcut the UI would not.
    ///
    /// Decoded through `[String: HotkeyBinding]` rather than
    /// `[HotkeyAction: HotkeyBinding]` for that last reason: keying the
    /// dictionary by the enum makes an unrecognised name a *throw*, which would
    /// cost the user every shortcut because one line came from a newer version.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: HotkeyBinding].self)
        var accepted = HotkeyBindings.empty
        // `allCases` order, not the file's: which of two conflicting entries
        // survives a hand-edited file must not depend on hash order.
        for action in HotkeyAction.allCases {
            guard let binding = raw[action.rawValue] else { continue }
            if case .success(let next) = accepted.assigning(binding, to: action) { accepted = next }
        }
        self = accepted
    }

    /// Encoded as a plain object keyed by the action name — greppable in a bug
    /// report and hand-editable, which the flat `[key, value, key, value…]` array
    /// an enum-keyed `Dictionary` encodes as would not be.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: byAction.map { ($0.key.rawValue, $0.value) }))
    }
}
