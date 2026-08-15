import Foundation
import CoreGraphics
// CGDisplayCreateUUIDFromDisplayID is declared in ColorSync, not CoreGraphics —
// public API in both, and the app's other call sites only compile without this
// import because AppKit drags ColorSync in behind them. This file has to stay
// headless (AGENTS.md §3.6), so it names the framework it actually uses.
import ColorSync

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

    // MARK: - Derivation
    //
    // The two halves of how a display's identity string is spelled, as functions
    // rather than as code copied per call site. There are now three places that
    // have to agree on it exactly — `DisplayInfo.displayUUID` (what the app
    // persists under), `crispctl list` (what it prints for a user to paste), and
    // the `crisp://display/<uuid>/…` grammar (what a link has to match) — and a
    // one-character disagreement between them is a link that silently targets
    // nothing.

    /// The UUID string macOS assigns this display, or nil when it has none.
    /// CoreGraphics, not a private framework: `CGDisplayCreateUUIDFromDisplayID`
    /// is public API and identity, not UI (AGENTS.md §3.6 allows CoreGraphics in
    /// `Crisp/Models`).
    static func systemString(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
              let string = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) else { return nil }
        return string as String
    }

    /// The fallback identity for a display macOS gives no UUID for: vendor,
    /// model and serial, which is still far more stable than a
    /// `CGDirectDisplayID` that macOS reassigns across reconnects.
    static func fallbackString(vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        "v\(vendor)-m\(model)-s\(serial)"
    }

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
