import Foundation

/// The stable identity every piece of per-display persistence keys on.
///
/// AGENTS.md rule #3 — persisted state keys on the display's UUID and *never* on
/// `CGDirectDisplayID`, because macOS reassigns display ids across reconnects
/// (issue #32) and a reused id silently hands one display's saved settings to a
/// different physical panel. While both were spelled as loose values (`String`
/// and `UInt32`) that rule was enforced only by review; as a distinct type the
/// compiler enforces it. There is deliberately **no** initializer taking a
/// `CGDirectDisplayID` or any integer, so the wrong identity cannot be passed by
/// accident — that has to be a compile error, not a code-review catch.
///
/// Pure Foundation on purpose: it compiles into the headless `CrispTests` target
/// (no AppKit, IOKit or CoreGraphics), the same route as `GammaPersistenceKey`.
struct DisplayUUID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The raw UUID string, as produced by `DisplayInfo.displayUUID`
    /// (`CGDisplayCreateUUIDFromDisplayID`, or its vendor/model/serial fallback).
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    // Encoded as a bare string rather than the synthesized `{"rawValue": …}`
    // wrapper: the persisted document is meant to be readable in a bug report,
    // and a UUID that reads as an object there would be noise.
    init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Lets `[DisplayUUID: DisplayState]` encode as a JSON object keyed by the UUID
/// string. Without this, `Dictionary`'s `Codable` conformance falls back to a
/// flat `[key, value, key, value…]` array, which is neither greppable in a bug
/// report nor stable to hand-edit.
extension DisplayUUID: CodingKeyRepresentable {
    var codingKey: any CodingKey { Key(stringValue: rawValue) }

    init?<T: CodingKey>(codingKey: T) {
        self.init(codingKey.stringValue)
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
