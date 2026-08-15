import Foundation

// The `crisp://` URL scheme, parsed. Text in, a request or a refusal out — no
// side effects, no display list, no I/O.
//
// **This is an attack surface, and the parser is written as one.** A registered
// URL scheme is not a private channel: any web page can navigate to `crisp://…`,
// any document can link to it, and macOS will hand it to this app with no
// gesture from the user beyond following a link. Everything below therefore
// starts from "this string is hostile" rather than "this string came from our
// own shortcut".
//
// Three properties, each pinned by `CrispURLTests`:
//
//   1. **A destructive feature can never be applied from a URL alone.** That is
//      not enforced here — it is enforced by `AutomationRequest.plan`, which has
//      no way to say `.ready` for a destructive feature — but this file must not
//      grow a shortcut around it. Hence rule 2.
//   2. **Anything unrecognised is refused, including unknown query items.** A
//      parser that ignores what it does not understand is one pull request away
//      from tolerating `?confirmed=true`. Refusing an unknown parameter means a
//      bypass flag can never be silently accepted: the whole URL is a no-op.
//   3. **A malformed URL is a quiet no-op.** Never a crash, never a partial
//      write, and never a value coerced into something writable.
//
// The grammar, in full:
//
//     crisp://display/<display-uuid>/<feature>?value=<v>
//     crisp://displays/refresh
//     crisp://preset/<preset-id>
//     crisp://tv/<tv-device-id>/<feature>?value=<v>
//
// The `tv` form addresses a paired smart TV rather than a display, and it is held
// to exactly the same three properties. In particular a TV's power and input are
// destructive in `TVFeatureRegistry` for the same reasons VCP 0xD6 and 0x60 are,
// `TVActionRequest.plan` can only answer `needsConfirmation` for them, and this
// parser must not grow a shortcut around that any more than the display form may.
//
// `<display-uuid>` is the stable per-display identity everything else in the app
// keys on (`DisplayUUID`), never a `CGDirectDisplayID` — macOS reassigns those
// across reconnects, so a link built today would aim at a different panel next
// week (AGENTS.md §3.3). `crispctl list` prints the UUID of each attached
// display, which is where a user gets one.
//
// There is deliberately **no** `main`, `all` or `current` alias. It buys a link
// author one line of convenience and buys a hostile page the ability to address
// a display it has never seen; a UUID it has to know first is not a security
// boundary, but it is the difference between a drive-by and a targeted click.
//
// `<feature>` is the registry's own name for the VCP code (`brightness`,
// `contrast`, `volume`, `input`) — the same spelling the quirks database uses,
// so there is one name per code across the whole app.
//
// Pure Foundation: `CrispURLTests` runs the whole grammar headlessly, with no
// URL handler registered and no app running (AGENTS.md §3.6).

/// What a `crisp://` URL turned out to be.
enum CrispURLCommand: Equatable, Sendable {
    /// A change to one display, still subject to `AutomationRequest.plan`.
    case write(AutomationRequest)
    /// A change to one paired smart TV, still subject to
    /// `TVActionRequest.plan` and then to `TVWriteGate.approve`.
    case tvAction(TVActionRequest)
    /// Apply a stored preset by identifier. The preset is not resolved here —
    /// this file has no store and no display list — and every setting it turns
    /// out to contain goes through `AutomationRequest.plan` individually, so a
    /// preset is not a way to reach a feature a URL could not name directly.
    case applyPreset(id: String, origin: AutomationOrigin)
    /// Re-enumerate displays and re-probe their DDC features. Reads only.
    case refreshDisplays
    /// Nothing to do, and why. Every malformed URL lands here.
    case ignored(reason: String)
}

enum CrispURL {

    /// The scheme, matched case-insensitively (`CRISP://` is the same URL to
    /// LaunchServices, so it has to be the same URL here).
    static let scheme = "crisp"

    /// A UUID longer than this many **UTF-8 bytes** is not a display identity,
    /// it is someone probing for a buffer. `CGDisplayCreateUUIDFromDisplayID`
    /// produces 36 ASCII characters and the vendor/model/serial fallback well
    /// under that, so bytes and characters are the same number for every
    /// identifier this app actually issues.
    ///
    /// Bytes rather than `count`, because `count` counts extended grapheme
    /// clusters and a cluster has no size limit: one base character followed by
    /// two hundred thousand combining marks is `count == 1` and ~400KB of input.
    /// No such string can match a real `DisplayUUID`, so the cap is not what
    /// stands between a URL and a DDC write — but a cap that does not bound the
    /// input it caps is not a cap, and this parser's whole premise is that the
    /// string is hostile (see the header). Comparing `utf8.count` also avoids
    /// segmenting the blob to find out how big it is.
    static let maximumIdentifierLength = 128

    /// Parses one URL. Total: every input produces a command, and an
    /// unrecognised one produces `.ignored` rather than a throw or a trap.
    static func command(for url: URL, origin: AutomationOrigin = .url) -> CrispURLCommand {
        guard url.scheme?.lowercased() == scheme else {
            return .ignored(reason: "not a \(scheme):// URL")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .ignored(reason: "the URL could not be parsed")
        }
        // `host` is `display` / `displays`; the rest is the path. Both are
        // matched lowercased because LaunchServices does not promise case.
        let host = (components.host ?? "").lowercased()
        let path = components.path.split(separator: "/").map(String.init)

        switch host {
        case "displays":
            return displaysCommand(path: path, components: components)
        case "display":
            return displayCommand(path: path, components: components, origin: origin)
        case "preset":
            return presetCommand(path: path, components: components, origin: origin)
        case "tv":
            return tvCommand(path: path, components: components, origin: origin)
        case "":
            return .ignored(reason: "the URL names no target (expected \(scheme)://display/<uuid>/<feature>)")
        default:
            return .ignored(reason: "unknown target '\(host)'")
        }
    }

    // MARK: - crisp://displays/…

    private static func displaysCommand(path: [String], components: URLComponents) -> CrispURLCommand {
        guard path.count == 1 else {
            return .ignored(reason: "expected \(scheme)://displays/refresh")
        }
        guard (components.queryItems ?? []).isEmpty else {
            // Rule 2. `refresh` takes no parameters, so a URL that carries one is
            // not a refresh this app wrote the grammar for.
            return .ignored(reason: "refresh takes no parameters")
        }
        switch path[0].lowercased() {
        case "refresh":
            return .refreshDisplays
        default:
            return .ignored(reason: "unknown displays action '\(path[0])'")
        }
    }

    // MARK: - crisp://preset/<id>

    /// Applying a preset takes no parameters, and rule 2 means a URL that
    /// carries one is refused whole rather than having it ignored — otherwise
    /// `crisp://preset/x?confirmed=true` would be a URL this parser accepts
    /// while quietly discarding the interesting half.
    private static func presetCommand(
        path: [String], components: URLComponents, origin: AutomationOrigin
    ) -> CrispURLCommand {
        guard path.count == 1 else {
            return .ignored(reason: "expected \(scheme)://preset/<preset-id>")
        }
        guard (components.queryItems ?? []).isEmpty else {
            return .ignored(reason: "applying a preset takes no parameters")
        }
        // Held to the same shape as a display identifier: non-empty, no
        // whitespace, bounded in bytes. A preset id is a UUID string the app
        // minted, so anything else did not come from Crisp.
        guard let id = identifier(path[0])?.rawValue else {
            return .ignored(reason: "the preset identifier is empty or malformed")
        }
        return .applyPreset(id: id, origin: origin)
    }

    // MARK: - crisp://display/<uuid>/<feature>

    private static func displayCommand(
        path: [String], components: URLComponents, origin: AutomationOrigin
    ) -> CrispURLCommand {
        guard path.count == 2 else {
            return .ignored(reason: "expected \(scheme)://display/<uuid>/<feature>?value=<v>")
        }
        guard let uuid = identifier(path[0]) else {
            return .ignored(reason: "the display identifier is empty or malformed")
        }
        guard let feature = feature(named: path[1]) else {
            return .ignored(reason: "unknown feature '\(path[1])'")
        }
        guard let text = soleValueParameter(components.queryItems) else {
            return .ignored(reason: "expected exactly one 'value' parameter")
        }
        guard let value = value(text, for: feature) else {
            return .ignored(reason: "'\(text)' is not a value \(feature.rawValue) accepts")
        }
        return .write(AutomationRequest(origin: origin, display: uuid, feature: feature, value: value))
    }

    // MARK: - crisp://tv/<device-id>/<feature>

    /// A TV action. Same grammar, same rule 2, and one difference that is worth
    /// naming: a TV feature's value can be a *flag*, so `value=off` is legal here
    /// where it would be meaningless for a VCP code.
    private static func tvCommand(
        path: [String], components: URLComponents, origin: AutomationOrigin
    ) -> CrispURLCommand {
        guard path.count == 2 else {
            return .ignored(reason: "expected \(scheme)://tv/<device-id>/<feature>?value=<v>")
        }
        guard let device = tvIdentifier(path[0]) else {
            return .ignored(reason: "the TV identifier is empty or malformed")
        }
        guard let feature = tvFeature(named: path[1]) else {
            return .ignored(reason: "unknown TV feature '\(path[1])'")
        }
        guard let text = soleValueParameter(components.queryItems) else {
            return .ignored(reason: "expected exactly one 'value' parameter")
        }
        guard let value = tvValue(text, for: feature) else {
            return .ignored(reason: "'\(text)' is not a value \(feature.rawValue) accepts")
        }
        return .tvAction(
            TVActionRequest(origin: origin, device: device, feature: feature, value: value)
        )
    }

    /// Held to the same shape as a display identifier: non-empty, whitespace-free
    /// and bounded in *bytes* (see `maximumIdentifierLength` for why bytes).
    private static func tvIdentifier(_ text: String) -> TVDeviceID? {
        guard !text.isEmpty, text.utf8.count <= maximumIdentifierLength,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return TVDeviceID(text)
    }

    private static func tvFeature(named name: String) -> TVFeatureID? {
        let wanted = name.lowercased()
        return TVFeatureID.allCases.first { $0.rawValue.lowercased() == wanted }
    }

    /// The text as the feature's own value shape, taken from `TVFeatureRegistry`
    /// rather than guessed from the text — the same rule the display form
    /// follows, and for the same reason.
    private static func tvValue(_ text: String, for feature: TVFeatureID) -> TVActionValue? {
        switch feature.spec.kind {
        case .percent:
            // `Double` also parses "nan" and "inf"; `TVActionRequest.plan`
            // refuses both, which is where that check belongs — every origin goes
            // through it, and only some go through this parser.
            guard let percent = Double(text) else { return nil }
            return .percent(percent)
        case .flag:
            return flag(text).map(TVActionValue.flag)
        case .code:
            return .code(text)
        }
    }

    /// `on`/`off`, `true`/`false`, `1`/`0`. Three spellings because a URL is
    /// typed by hand as often as it is generated; nothing else, because a parser
    /// that accepts "yes" today accepts "y" in a year and then has to guess.
    private static func flag(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "on", "true", "1": return true
        case "off", "false", "0": return false
        default: return nil
        }
    }

    // MARK: - Pieces

    /// A display identifier, or nil for anything that cannot be one. Whitespace
    /// is refused rather than trimmed: a UUID with a space in it did not come
    /// from `crispctl`, and quietly repairing hostile input is how a parser ends
    /// up accepting two spellings of the same thing.
    private static func identifier(_ text: String) -> DisplayUUID? {
        guard !text.isEmpty, text.utf8.count <= maximumIdentifierLength,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return DisplayUUID(text)
    }

    /// The registry feature this name refers to. Case-insensitive because a URL
    /// is typed by hand as often as it is generated, and there is exactly one
    /// spelling per code either way — the registry's.
    private static func feature(named name: String) -> DDCFeatureID? {
        let wanted = name.lowercased()
        return DDCFeatureID.allCases.first { $0.rawValue.lowercased() == wanted }
    }

    /// The single `value` query item, or nil when there is none, more than one,
    /// or any other parameter alongside it (rule 2).
    private static func soleValueParameter(_ items: [URLQueryItem]?) -> String? {
        let items = items ?? []
        guard items.count == 1, items[0].name.lowercased() == "value" else { return nil }
        guard let value = items[0].value, !value.isEmpty else { return nil }
        return value
    }

    /// The text as the feature's own value shape, or nil if it is not one.
    ///
    /// The shape comes from the registry, not from the text: `19` is a percentage
    /// for brightness and a port for input source, and which one it is must not
    /// depend on how the sender chose to spell it.
    private static func value(_ text: String, for feature: DDCFeatureID) -> AutomationValue? {
        if feature.spec.kind.isContinuous {
            // `Double` also parses "nan" and "inf"; `AutomationRequest.plan`
            // refuses both. Left there on purpose: it is the layer every origin
            // goes through, and a non-finite value must not depend on this one.
            guard let percent = Double(text) else { return nil }
            return .percent(percent)
        }
        return rawCode(text).map(AutomationValue.raw)
    }

    /// A raw VCP code, decimal or `0x`-prefixed hex — monitors' manuals use both,
    /// and the app's own diagnostics print hex. `UInt16` does the range check:
    /// a negative number or one past 65535 simply fails to parse.
    private static func rawCode(_ text: String) -> UInt16? {
        let lowered = text.lowercased()
        guard lowered.hasPrefix("0x") else { return UInt16(text) }
        return UInt16(lowered.dropFirst(2), radix: 16)
    }
}
