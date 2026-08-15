import Foundation

// One JSON value, and the two things `displays.json` needs it for: carrying
// fields this build does not know about, and decoding a list without letting one
// bad element take the rest of it down.
//
// **Why a document needs to carry what it cannot read.** `displays.json` is
// versioned, and a version number only helps the build that is *ahead*. The build
// that is *behind* — someone who rolled back, or who runs a release while a beta
// wrote the file — decodes what it understands and, until now, silently dropped
// the rest on the next save. That is a data-loss bug with no error message: the
// user's schedules disappear because they opened an older Crisp once.
//
// So every field the decoder does not recognise is parked here verbatim and
// written back out unchanged. Rolling back becomes lossless, and "a document
// written by a newer build must still load" becomes "…and must still round-trip".
//
// Pure Foundation: it compiles into the headless `CrispTests` target, which is
// what makes both properties tests rather than intentions (AGENTS.md §3.6).

/// A JSON value, as JSON spells it.
///
/// Deliberately not `Any`: an `Any` bag cannot be `Equatable` (so the document
/// could not be compared in a test) nor `Sendable` (so it could not cross the
/// store's lock), and both of those are load-bearing here.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Ordered narrowest first: `Bool` before `Double`, because JSONDecoder
        // will happily read `true` as `1` and the round trip would then write
        // `1` back into a field that was a boolean.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A coding key that is whatever string the document had. Needed to enumerate a
/// JSON object's real keys, which the synthesised `CodingKeys` of a struct
/// cannot do — it only knows the ones the struct declares.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - Reading a value out

/// Total, non-throwing accessors.
///
/// Added for the smart-TV protocol engines (`WebOSSSAP`, `TizenRemote`), which
/// parse JSON that arrived over the network from a device nobody controls. A
/// `Codable` struct per message shape is the wrong tool there: every field is
/// optional in practice, several are typed differently across firmware versions
/// (Samsung sends `"true"` where LG sends `true`), and a throwing decode of a
/// whole frame turns one unexpected field into a dropped reply.
///
/// So the rule these accessors encode is: **asking for the wrong type is `nil`,
/// never a throw and never a coercion.** A number read as a string is absent, not
/// `"1"`; that is what stops a malformed frame becoming a wrong value rather than
/// no value.
extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// A child by key, or nil for anything that is not an object with that key.
    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// A boolean that may have arrived as a JSON boolean **or** as a string.
    ///
    /// Samsung's `GET /api/v2/` returns every boolean-ish field as a string
    /// (`"TokenAuthSupport":"true"`), and a build that only accepted real
    /// booleans would decide every Tizen TV needs no token and then connect to
    /// the wrong port. Only the two exact spellings are accepted; anything else
    /// is `nil` rather than false, because "the field said something we do not
    /// understand" and "the field said no" are different facts.
    var looseBoolValue: Bool? {
        if let value = boolValue { return value }
        switch stringValue?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Parses one JSON document into a value, or nil. Never throws: every caller
    /// is reading something a device on the network sent.
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Serialises with sorted keys, so a frame this app builds is byte-identical
    /// run to run — which is what lets the wire format itself be asserted in a
    /// test instead of only its parse.
    func serialized() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Reading and writing the "everything this build did not recognise" bag.
///
/// Two free functions rather than a protocol with an associated type: both call
/// sites (`DisplayStateDocument` and `DisplayState`) already write their own
/// `init(from:)`, and a protocol would only add a constraint neither needs.
enum ForwardCompatibleFields {

    /// Every key in the object that is not one of `known`, with its value.
    ///
    /// Never throws. A field this build cannot even parse as JSON is dropped
    /// rather than failing the document — the whole point of the bag is to make
    /// an unfamiliar document *more* survivable, so it must not become a new way
    /// for one to fail (AGENTS.md rule #4).
    static func decode(from decoder: Decoder, known: Set<String>) -> [String: JSONValue] {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self) else { return [:] }
        var fields: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            guard let value = try? container.decode(JSONValue.self, forKey: key) else { continue }
            fields[key.stringValue] = value
        }
        return fields
    }

    /// Writes the bag back out alongside the fields the struct itself encoded.
    ///
    /// A field colliding with a key this build owns is dropped, not written: the
    /// struct's own value is the one this build can reason about, and emitting
    /// the key twice produces a document whose meaning depends on the decoder.
    static func encode(_ fields: [String: JSONValue], to encoder: Encoder, known: Set<String>) throws {
        guard !fields.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (name, value) in fields where !known.contains(name) {
            try container.encode(value, forKey: AnyCodingKey(stringValue: name))
        }
    }
}

/// Element-wise decoding of a list: the elements that decode are kept, the ones
/// that do not are dropped.
///
/// Why not just let the array's own `Codable` throw: `displays.json` grew three
/// list-shaped members (groups, presets, schedules), and one hand-edited or
/// half-written entry among them would otherwise fail the *whole document*,
/// which the store then quarantines — losing the user's per-display brightness
/// because they mistyped a schedule. A malformed group is not a group; it is not
/// a reason to forget the monitor's settings.
///
/// Round-tripping through `Data` per element rather than decoding the array in
/// place is deliberate: `UnkeyedDecodingContainer` gives no promise about whether
/// a failed `decode` advanced the cursor, and "usually advances" is how a decoder
/// loop becomes an infinite one on the one input nobody tested.
enum LossyList {
    static func decode<Element: Decodable>(
        _ type: Element.Type, from values: [JSONValue]
    ) -> [Element] {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return values.compactMap { value in
            guard let data = try? encoder.encode(value) else { return nil }
            return try? decoder.decode(Element.self, from: data)
        }
    }
}
